//
//  TerminalView.m
//  iSH
//
//  Created by Theodore Dubois on 11/3/17.
//

#import "ScrollbarView.h"
#import "TerminalView.h"
#import "UserPreferences.h"
#import "UIApplication+OpenURL.h"
#import "NSObject+SaneKVO.h"

#include <math.h>

struct rowcol {
    int row;
    int col;
};

@interface WeakScriptMessageHandler : NSObject <WKScriptMessageHandler>
@property (weak) id <WKScriptMessageHandler> handler;
@end
@implementation WeakScriptMessageHandler
- (instancetype)initWithHandler:(id <WKScriptMessageHandler>)handler {
    if (self = [super init]) {
        self.handler = handler;
    }
    return self;
}
- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    [self.handler userContentController:userContentController didReceiveScriptMessage:message];
}
@end

@interface TerminalView () <UIGestureRecognizerDelegate>

@property (nonatomic) NSMutableArray<UIKeyCommand *> *keyCommands;
@property ScrollbarView *scrollbarView;
@property (nonatomic) BOOL terminalFocused;
@property (nonatomic) BOOL updatingTerminalScroll;

@property (nullable) NSString *markedText;
@property UITextRange *markedRange;
@property UITextRange *selectedRange;

@property (nonatomic, strong, nullable) UIView *selectionStartHandle;
@property (nonatomic, strong, nullable) UIView *selectionEndHandle;
@property (nonatomic, strong, nullable) UIImpactFeedbackGenerator *selectionHaptic;
@property struct rowcol floatingCursor;
@property CGSize floatingCursorSensitivity;
@property CGSize actualFloatingCursorSensitivity;

@property (nonatomic) BOOL scrollUpdateInFlight;
@property (nonatomic) CGFloat pendingScrollTop;
@property (nonatomic, strong, nullable) CADisplayLink *autoscrollLink;
@property (nonatomic) CGPoint autoscrollPoint;
@property (nonatomic) CGFloat autoscrollVelocity;
@property (nonatomic, strong, nullable) NSString *autoscrollEndpoint; // "start"/"end" during handle drags, nil during finger drags
@property (nonatomic, strong, nullable) UILabel *outputPill;
@property (nonatomic, strong, nullable) UILabel *clipboardToast;
@property (nonatomic) CGFloat pinchBaseFontSize;
@property (nonatomic) BOOL selectionDragMode;
@property (nonatomic, strong, nullable) NSTimer *longPressHoldTimer;
@property (nonatomic) CGPoint selectionGestureStart;
@property (nonatomic, strong, nullable) UIEditMenuInteraction *pasteEditMenu API_AVAILABLE(ios(16.0));
@property (nonatomic, strong, nullable) UIViewPropertyAnimator *toastAnimator;

@end


@implementation TerminalView
@synthesize inputDelegate;
@synthesize tokenizer;
@synthesize canBecomeFirstResponder;

- (void)awakeFromNib {
    [super awakeFromNib];
    self.inputAssistantItem.leadingBarButtonGroups = @[];
    self.inputAssistantItem.trailingBarButtonGroups = @[];

    ScrollbarView *scrollbarView = self.scrollbarView = [[ScrollbarView alloc] initWithFrame:self.bounds];
    scrollbarView.delegate = self;
    scrollbarView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrollbarView.bounces = NO;
    scrollbarView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    // The app draws its own draggable scrubber; the system indicator would be
    // a second, non-draggable scrollbar.
    scrollbarView.showsVerticalScrollIndicator = NO;
    scrollbarView.showsHorizontalScrollIndicator = NO;
    self.clipsToBounds = YES;
    [self addSubview:scrollbarView];
#if USE_XTERM_RENDERER
    UILongPressGestureRecognizer *selectionGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(selectTerminalText:)];
    selectionGesture.delegate = self;
    [self addGestureRecognizer:selectionGesture];
    UIPinchGestureRecognizer *fontPinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinchedFontSize:)];
    fontPinch.delegate = self;
    [self addGestureRecognizer:fontPinch];
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTapped:)];
    doubleTap.numberOfTapsRequired = 2;
    doubleTap.delegate = self;
    [self addGestureRecognizer:doubleTap];
    UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(singleTapped:)];
    [singleTap requireGestureRecognizerToFail:doubleTap];
    singleTap.delegate = self;
    [self addGestureRecognizer:singleTap];
#endif

    UserPreferences *prefs = UserPreferences.shared;
    [prefs observe:@[@"capsLockMapping", @"optionMapping", @"backtickMapEscape", @"overrideControlSpace"]
           options:0 owner:self usingBlock:^(typeof(self) self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_keyCommands = nil;
        });
    }];
    [prefs observe:@[@"colorScheme", @"fontFamily", @"fontSize", @"theme", @"cursorStyle", @"blinkCursor"]
           options:0 owner:self usingBlock:^(typeof(self) self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _updateStyle];
        });
    }];

    self.markedRange = [UITextRange new];
    self.selectedRange = [UITextRange new];

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self
               selector:@selector(applicationDidBecomeActive:)
                   name:UIApplicationDidBecomeActiveNotification
                 object:UIApplication.sharedApplication];
    [center addObserver:self
               selector:@selector(applicationWillResignActive:)
                   name:UIApplicationWillResignActiveNotification
                 object:UIApplication.sharedApplication];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    self.terminal = nil;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (object == _terminal) {
        if (_terminal.loaded) {
            [self installTerminalView];
            [self _updateStyle];
        }
    }
}

static NSString *const HANDLERS[] = {@"syncFocus", @"focus", @"newScrollHeight", @"newScrollTop", @"openLink", @"selectionRect", @"newOutput"};

- (void)setTerminal:(Terminal *)terminal {
    if (_terminal) {
        [_terminal removeObserver:self forKeyPath:@"loaded"];
        [self uninstallTerminalView];
    }

    _terminal = terminal;
    if (_terminal == nil)
        return;
    [self _updateStyle];
    [_terminal addObserver:self forKeyPath:@"loaded" options:NSKeyValueObservingOptionInitial context:nil];
    [self installTerminalView];
}

- (void)installTerminalView {
    UIView *superview = self.terminal.webView.superview;
    if (superview != nil) {
        NSAssert(superview == self.scrollbarView, @"installing terminal that is already installed elsewhere");
        return;
    }

    WKWebView *webView = _terminal.webView;
    if (_terminal.loaded)
        _terminal.enableVoiceOverAnnounce = YES;
    webView.scrollView.scrollEnabled = NO;
    webView.scrollView.delaysContentTouches = NO;
    webView.scrollView.canCancelContentTouches = NO;
    webView.scrollView.panGestureRecognizer.enabled = NO;
    id <WKScriptMessageHandler> handler = [[WeakScriptMessageHandler alloc] initWithHandler:self];
    for (int i = 0; i < sizeof(HANDLERS)/sizeof(HANDLERS[0]); i++) {
        [webView.configuration.userContentController addScriptMessageHandler:handler name:HANDLERS[i]];
    }
    webView.frame = self.bounds;
    self.opaque = webView.opaque = NO;
    webView.backgroundColor = UIColor.clearColor;
    webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    self.scrollbarView.contentView = webView;
    [self.scrollbarView addSubview:webView];
}

- (void)uninstallTerminalView {
    // remove old terminal
    UIView *superview = _terminal.webView.superview;
    if (superview != self.scrollbarView) {
        NSAssert(superview == nil, @"uninstalling terminal that is installed elsewhere");
        return;
    }

    [_terminal.webView removeFromSuperview];
    self.scrollbarView.contentView = nil;
    for (int i = 0; i < sizeof(HANDLERS)/sizeof(HANDLERS[0]); i++) {
        [_terminal.webView.configuration.userContentController removeScriptMessageHandlerForName:HANDLERS[i]];
    }
    _terminal.enableVoiceOverAnnounce = NO;
}

#pragma mark Styling

- (void)_updateStyle {
    NSAssert(NSThread.isMainThread, @"This method needs to be called on the main thread");
    UserPreferences *prefs = [UserPreferences shared];
    Palette *palette = prefs.palette;
    if (self.overrideAppearance != OverrideAppearanceNone) {
        palette = self.overrideAppearance == OverrideAppearanceLight ? prefs.theme.lightPalette : prefs.theme.darkPalette;
    }
    UIColor *backgroundColor = [[UIColor alloc] ish_initWithHexString:palette.backgroundColor];
    self.backgroundColor = backgroundColor;
    self.scrollbarView.backgroundColor = backgroundColor;
    if (_overrideFontSize == prefs.fontSize.doubleValue)
        _overrideFontSize = 0;
    NSMutableDictionary<NSString *, id> *themeInfo = [@{
        @"fontFamily": prefs.fontFamily,
        @"fontSize": @(self.effectiveFontSize),
        @"foregroundColor": palette.foregroundColor,
        @"backgroundColor": palette.backgroundColor,
        @"cursorColor": palette.cursorColor ?: palette.foregroundColor,
        @"blinkCursor": @(prefs.blinkCursor),
        @"cursorShape": prefs.htermCursorShape,
    } mutableCopy];
    if (palette.colorPaletteOverrides) {
        themeInfo[@"colorPaletteOverrides"] = palette.colorPaletteOverrides;
    }
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:themeInfo options:0 error:nil] encoding:NSUTF8StringEncoding];
    self.terminal.bootstrapStyleJSON = json;
    if (!self.terminal.loaded)
        return;
    [self.terminal.webView evaluateJavaScript:[NSString stringWithFormat:@"exports.updateStyle(%@)", json] completionHandler:^(id result, NSError *error){
        [self updateFloatingCursorSensitivity];
    }];
}

- (void)setOverrideFontSize:(CGFloat)overrideFontSize {
    _overrideFontSize = overrideFontSize;
    [self _updateStyle];
}

- (void)setOverrideAppearance:(enum OverrideAppearance)overrideAppearance {
    _overrideAppearance = overrideAppearance;
    [self _updateStyle];
}

- (CGFloat)effectiveFontSize {
    if (self.overrideFontSize != 0)
        return self.overrideFontSize;
    return UserPreferences.shared.fontSize.doubleValue;
}

#pragma mark Focus and scrolling

- (BOOL)terminalShouldRenderFocused {
    if (self.window == nil)
        return NO;
    if (@available(iOS 13.0, *))
        return self.window.windowScene.activationState == UISceneActivationStateForegroundActive;
    return UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}

- (void)syncTerminalRenderFocus {
    self.terminalFocused = self.terminalShouldRenderFocused;
}

- (void)setTerminalFocused:(BOOL)terminalFocused {
    _terminalFocused = terminalFocused;
    NSString *script = terminalFocused ? @"exports.setFocused(true)" : @"exports.setFocused(false)";
    [self.terminal.webView evaluateJavaScript:script completionHandler:nil];
}

- (BOOL)becomeFirstResponder {
    [self syncTerminalRenderFocus];
    [self reloadInputViews];
    return [super becomeFirstResponder];
}
- (BOOL)resignFirstResponder {
    [self syncTerminalRenderFocus];
    return [super resignFirstResponder];
}
- (void)windowDidBecomeKey:(NSNotification *)notif {
    [self syncTerminalRenderFocus];
}
- (void)windowDidResignKey:(NSNotification *)notif {
    [self syncTerminalRenderFocus];
}
- (void)applicationDidBecomeActive:(NSNotification *)notif {
    [self syncTerminalRenderFocus];
}
- (void)applicationWillResignActive:(NSNotification *)notif {
    self.terminalFocused = NO;
}

- (IBAction)loseFocus:(id)sender {
    [self resignFirstResponder];
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (self.window != nil) {
        [center removeObserver:self
                          name:UIWindowDidBecomeKeyNotification
                        object:self.window];
        [center removeObserver:self
                          name:UIWindowDidResignKeyNotification
                        object:self.window];
    }
    if (newWindow != nil) {
        [center addObserver:self
                   selector:@selector(windowDidBecomeKey:)
                       name:UIWindowDidBecomeKeyNotification
                     object:newWindow];
        [center addObserver:self
                   selector:@selector(windowDidResignKey:)
                       name:UIWindowDidResignKeyNotification
                     object:newWindow];
    }
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"syncFocus"]) {
        [self syncTerminalRenderFocus];
    } else if ([message.name isEqualToString:@"focus"]) {
        if (!self.isFirstResponder) {
            [self becomeFirstResponder];
        }
    } else if ([message.name isEqualToString:@"newScrollHeight"]) {
        if (![message.body isKindOfClass:NSNumber.class])
            return;
        CGFloat newHeight = [message.body doubleValue];
        if (!isfinite(newHeight) || newHeight < 0)
            return;
        self.updatingTerminalScroll = YES;
        self.scrollbarView.contentSize = CGSizeMake(0, newHeight);
        self.updatingTerminalScroll = NO;
    } else if ([message.name isEqualToString:@"newScrollTop"]) {
        if (![message.body isKindOfClass:NSNumber.class])
            return;
        CGFloat newOffset = [message.body doubleValue];
        if (!isfinite(newOffset) || newOffset < 0)
            return;
        newOffset = MIN(newOffset, MAX(0, self.scrollbarView.contentSize.height - self.scrollbarView.bounds.size.height));
        if (self.scrollbarView.contentOffset.y == newOffset)
            return;
        self.updatingTerminalScroll = YES;
        [self.scrollbarView setContentOffset:CGPointMake(0, newOffset) animated:NO];
        self.updatingTerminalScroll = NO;
    } else if ([message.name isEqualToString:@"openLink"]) {
        if ([message.body isKindOfClass:NSString.class])
            [UIApplication openURL:message.body];
        } else if ([message.name isEqualToString:@"selectionRect"]) {
        [self updateSelectionHandles:[message.body isKindOfClass:NSDictionary.class] ? message.body : nil];
    } else if ([message.name isEqualToString:@"newOutput"]) {
        [self showOutputPill];
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    // Terminal output updates the indicator, not the user's scroll position.
    if (self.updatingTerminalScroll)
        return;
    self.pendingScrollTop = scrollView.contentOffset.y;
    if (scrollView.contentOffset.y >= scrollView.contentSize.height - scrollView.bounds.size.height - 1)
        [self hideOutputPill];
    if (!self.scrollUpdateInFlight)
        [self flushScrollUpdate];
}

// Keep at most one scroll update in flight: during fast flicks, unthrottled
// evaluateJavaScript calls queue up and the canvas lags badly behind the
// native momentum. The newest offset always wins.
- (void)flushScrollUpdate {
    if (self.terminal == nil || self.terminal.webView == nil)
        return;
    self.scrollUpdateInFlight = YES;
    CGFloat top = self.pendingScrollTop;
    __weak typeof(self) weakSelf = self;
    [self.terminal.webView evaluateJavaScript:[NSString stringWithFormat:@"exports.newScrollTop(%f)", top] completionHandler:^(id result, NSError *error) {
        weakSelf.scrollUpdateInFlight = NO;
        if (weakSelf.pendingScrollTop != top)
            [weakSelf flushScrollUpdate];
    }];
}

- (void)setKeyboardAppearance:(UIKeyboardAppearance)keyboardAppearance {
    BOOL needsFirstResponderDance = self.isFirstResponder && _keyboardAppearance != keyboardAppearance;
    if (needsFirstResponderDance) {
        [self resignFirstResponder];
    }
    _keyboardAppearance = keyboardAppearance;
    if (needsFirstResponderDance) {
        [self becomeFirstResponder];
    }
    if (keyboardAppearance == UIKeyboardAppearanceLight) {
        self.scrollbarView.indicatorStyle = UIScrollViewIndicatorStyleBlack;
    } else {
        self.scrollbarView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    }
}

#pragma mark Keyboard Input

// implementing these makes a keyboard pop up when this view is first responder

- (void)insertText:(NSString *)text {
    self.markedText = nil;

    if (self.controlKey.highlighted)
        self.controlKey.selected = YES;
    if (self.controlKey.selected) {
        if (!self.controlKey.highlighted)
            self.controlKey.selected = NO;
        if (text.length == 1)
            return [self insertControlChar:[text characterAtIndex:0]];
    }

    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@"\r"];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    [self.terminal sendInput:data];
}

- (void)insertControlChar:(char)ch {
    if (strchr(controlKeys, ch) != NULL) {
        if (ch == ' ') ch = '\0';
        if (ch == '2') ch = '@';
        if (ch == '6') ch = '^';
        if (ch != '\0')
            ch = toupper(ch) ^ 0x40;
        [self.terminal sendInput:[NSData dataWithBytes:&ch length:1]];
    }
}

- (void)deleteBackward {
    [self insertText:@"\x7f"];
}

- (BOOL)hasText {
    return YES; // it's always ok to send a "delete"
}

#pragma mark IME Input and Selection

- (void)setMarkedText:(nullable NSString *)markedText selectedRange:(NSRange)selectedRange {
    self.markedText = markedText;
}

- (void)unmarkText {
    [self insertText:self.markedText];
}

- (UITextRange *)markedTextRange {
    if (self.markedText != nil)
        return self.markedRange;
    return nil;
}

// The only reason to have this selected range is to prevent the "speak selection" context action from failing to get the current selection and falling back on calling copy:. It doesn't even have to work, it seems...

- (UITextRange *)selectedTextRange {
    return self.selectedRange;
}

- (NSString *)textInRange:(UITextRange *)range {
    if (range == self.markedRange)
        return self.markedText;
    if (range == self.selectedRange)
        return @"";
    return nil;
}

- (id)insertDictationResultPlaceholder {
    return @"";
}
- (void)removeDictationResultPlaceholder:(id)placeholder willInsertResult:(BOOL)willInsertResult {
}

#pragma mark Keyboard Actions

- (void)paste:(id)sender {
    NSString *string = UIPasteboard.generalPasteboard.string;
    if (string) {
        [self insertText:string];
    }
}

#pragma mark - Selection handles and auto-copy

- (UIView *)selectionHandleView {
    // 44pt touch target, small visual: grabber line + knob at the bottom-center.
    UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
    handle.backgroundColor = UIColor.clearColor;
    handle.userInteractionEnabled = YES;
    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(20.5, 4, 3, 24)];
    line.backgroundColor = UIColor.systemBlueColor;
    line.layer.cornerRadius = 1.5;
    UIView *knob = [[UIView alloc] initWithFrame:CGRectMake(15, 26, 14, 14)];
    knob.backgroundColor = UIColor.systemBlueColor;
    knob.layer.cornerRadius = 7;
    [handle addSubview:line];
    [handle addSubview:knob];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragSelectionHandle:)];
    [handle addGestureRecognizer:pan];
    return handle;
}

- (void)updateSelectionHandles:(NSDictionary *)info {
    if (info == nil) {
        [self.selectionStartHandle removeFromSuperview];
        [self.selectionEndHandle removeFromSuperview];
        self.selectionStartHandle = nil;
        self.selectionEndHandle = nil;
        return;
    }
    if (self.selectionStartHandle == nil) {
        self.selectionStartHandle = [self selectionHandleView];
        [self addSubview:self.selectionStartHandle];
        self.selectionEndHandle = [self selectionHandleView];
        [self addSubview:self.selectionEndHandle];
        if (self.selectionHaptic == nil)
            self.selectionHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    }
    CGFloat cellHeight = [info[@"cellHeight"] doubleValue];
    NSNumber *sx = info[@"sx"], *sy = info[@"sy"], *ex = info[@"ex"], *ey = info[@"ey"];
    if (sx == nil || sy == nil || ex == nil || ey == nil || cellHeight <= 0)
        return;
    WKWebView *webView = self.terminal.webView;
    CGPoint start = [webView convertPoint:CGPointMake(sx.doubleValue, sy.doubleValue + cellHeight) toView:self];
    CGPoint end = [webView convertPoint:CGPointMake(ex.doubleValue, ey.doubleValue + cellHeight) toView:self];
    // The handle's visual anchor (knob, at the bottom-center of the 44pt box)
    // sits at the selection edge.
    self.selectionStartHandle.center = CGPointMake(start.x, start.y + 22);
    self.selectionEndHandle.center = CGPointMake(end.x, end.y + 22);
}

- (void)dragSelectionHandle:(UIPanGestureRecognizer *)gesture {
    if (gesture.view == nil)
        return;
    BOOL isStart = gesture.view == self.selectionStartHandle;
    CGPoint point = [gesture locationInView:self.terminal.webView];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.scrollbarView.scrollEnabled = NO;
    }
    if (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged) {
        [self loupeTrackGesturePoint:point];
        [self updateAutoscrollForPoint:[gesture locationInView:self] endpoint:isStart ? @"start" : @"end"];
        NSString *side = isStart ? @"start" : @"end";
        NSString *script = [NSString stringWithFormat:@"exports.moveSelectionEndpoint('%@',%f,%f)", side, point.x, point.y];
        [self.terminal.webView evaluateJavaScript:script completionHandler:nil];
    } else {
        self.scrollbarView.scrollEnabled = YES;
        [self hideSelectionLoupe];
        [self stopAutoscroll];
        if (gesture.state == UIGestureRecognizerStateEnded)
            [self copySelectionToPasteboard];
    }
}

- (void)copySelectionToPasteboard {
    __weak typeof(self) weakSelf = self;
    [self.terminal.webView evaluateJavaScript:@"exports.copy()" completionHandler:^(id result, NSError *error) {
        if (error != nil || ![result isKindOfClass:NSString.class] || [result length] == 0) {
            NSLog(@"[selection] copy failed err=%@ result=%@", error, [result class]);
            return;
        }
        UIPasteboard.generalPasteboard.string = result;
        NSLog(@"[selection] auto-copied %lu chars", (unsigned long)[result length]);
        [weakSelf showCopyToastWithLength:[result length]];
        [weakSelf.selectionHaptic prepare];
        [weakSelf.selectionHaptic impactOccurred];
        [weakSelf hidePasteMenu];
    }];
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (action == @selector(paste:))
        return UIPasteboard.generalPasteboard.hasStrings;
    return [super canPerformAction:action withSender:sender];
}

- (void)loupeTrackGesturePoint:(CGPoint)pointInWebView {
    // The loupe is rendered inside the web page (canvas-to-canvas): WebKit's
    // snapshot APIs deliver too late during gesture tracking to be useful.
    [self.terminal.webView evaluateJavaScript:[NSString stringWithFormat:@"exports.updateLoupe(%f,%f)", pointInWebView.x, pointInWebView.y] completionHandler:nil];
}

- (void)hideSelectionLoupe {
    [self.terminal.webView evaluateJavaScript:@"exports.hideLoupe()" completionHandler:nil];
}

#pragma mark - Tap gestures (manual keyboard control)

- (BOOL)tapIsOnSelectionHandle:(CGPoint)pointInSelf {
    // Array literals throw on nil; check each handle explicitly.
    if (self.selectionStartHandle != nil && CGRectContainsPoint(self.selectionStartHandle.frame, pointInSelf))
        return YES;
    if (self.selectionEndHandle != nil && CGRectContainsPoint(self.selectionEndHandle.frame, pointInSelf))
        return YES;
    return NO;
}

- (void)doubleTapped:(UITapGestureRecognizer *)gesture {
    // The only automatic-free keyboard control: double tap toggles it.
    if (self.isFirstResponder) {
        [self resignFirstResponder];
    } else {
        [self becomeFirstResponder];
    }
}

- (void)singleTapped:(UITapGestureRecognizer *)gesture {
    if ([self tapIsOnSelectionHandle:[gesture locationInView:self]])
        return;
    // A deliberate tap clears a live selection. It never touches the keyboard.
    if (self.terminal.loaded)
        [self.terminal.webView evaluateJavaScript:@"exports.clearSelection()" completionHandler:nil];
}

#pragma mark - Selection edge auto-scroll

static CGFloat const AutoscrollEdgeInset = 56;
static CGFloat const AutoscrollMaxVelocity = 2400;

- (void)updateAutoscrollForPoint:(CGPoint)pointInSelf endpoint:(nullable NSString *)endpoint {
    self.autoscrollPoint = pointInSelf;
    self.autoscrollEndpoint = endpoint;
    CGRect visible = self.scrollbarView.frame;
    CGFloat topProximity = pointInSelf.y - CGRectGetMinY(visible);
    CGFloat bottomProximity = CGRectGetMaxY(visible) - pointInSelf.y;
    CGFloat velocity = 0;
    if (topProximity < AutoscrollEdgeInset && topProximity <= bottomProximity) {
        velocity = -AutoscrollMaxVelocity * (1 - MAX(0, topProximity) / AutoscrollEdgeInset);
    } else if (bottomProximity < AutoscrollEdgeInset) {
        velocity = AutoscrollMaxVelocity * (1 - MAX(0, bottomProximity) / AutoscrollEdgeInset);
    }
    self.autoscrollVelocity = velocity;
    if (velocity != 0 && self.autoscrollLink == nil) {
        self.autoscrollLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(autoscrollTick:)];
        [self.autoscrollLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    } else if (velocity == 0 && self.autoscrollLink != nil) {
        [self stopAutoscroll];
    }
}

- (void)stopAutoscroll {
    [self.autoscrollLink invalidate];
    self.autoscrollLink = nil;
    self.autoscrollVelocity = 0;
}

- (void)autoscrollTick:(CADisplayLink *)link {
    UIScrollView *scrollView = self.scrollbarView;
    CGFloat offset = scrollView.contentOffset.y + self.autoscrollVelocity * link.duration;
    CGFloat maxOffset = scrollView.contentSize.height - scrollView.bounds.size.height;
    if (offset <= 0 || offset >= maxOffset)
        [self stopAutoscroll];
    offset = MAX(0, MIN(maxOffset, offset));
    // Drives scrollViewDidScroll → coalesced JS repaint; no update guard.
    [scrollView setContentOffset:CGPointMake(scrollView.contentOffset.x, offset) animated:NO];
    // The viewport moved under the finger: keep extending the selection at the
    // same on-screen point (cell math is viewport-relative in the bridge).
    CGPoint webPoint = [self convertPoint:self.autoscrollPoint toView:self.terminal.webView];
    NSString *script;
    if (self.autoscrollEndpoint != nil)
        script = [NSString stringWithFormat:@"exports.moveSelectionEndpoint('%@',%f,%f)", self.autoscrollEndpoint, webPoint.x, webPoint.y];
    else
        script = [NSString stringWithFormat:@"exports.extendSelection(%f,%f)", webPoint.x, webPoint.y];
    [self.terminal.webView evaluateJavaScript:script completionHandler:nil];
    [self loupeTrackGesturePoint:webPoint];
}

#pragma mark - Pinch to zoom font

- (void)pinchedFontSize:(UIPinchGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.pinchBaseFontSize = UserPreferences.shared.fontSize.doubleValue;
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        CGFloat size = MAX(6, MIN(28, self.pinchBaseFontSize * gesture.scale));
        double rounded = round(size * 2) / 2;
        if (fabs(rounded - UserPreferences.shared.fontSize.doubleValue) >= 0.5)
            UserPreferences.shared.fontSize = @(rounded);
    }
}

#pragma mark - Output pill and copy toast

- (void)showOutputPill {
    if (self.outputPill == nil) {
        UILabel *pill = [UILabel new];
        pill.text = @"  ↓  new output  ";
        pill.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        pill.textColor = UIColor.whiteColor;
        pill.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.75];
        pill.layer.cornerRadius = 14;
        pill.layer.masksToBounds = YES;
        pill.textAlignment = NSTextAlignmentCenter;
        pill.userInteractionEnabled = YES;
        [pill addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(outputPillTapped:)]];
        self.outputPill = pill;
        [self addSubview:pill];
    }
    CGRect bounds = self.bounds;
    self.outputPill.frame = CGRectMake(0, 0, 132, 28);
    self.outputPill.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMaxY(bounds) - 44);
    self.outputPill.hidden = NO;
    [UIView animateWithDuration:0.15 animations:^{
        self.outputPill.alpha = 1;
    }];
}

- (void)hideOutputPill {
    [UIView animateWithDuration:0.2 animations:^{
        self.outputPill.alpha = 0;
    } completion:^(BOOL finished) {
        self.outputPill.hidden = YES;
    }];
}

- (void)outputPillTapped:(UITapGestureRecognizer *)gesture {
    [self hideOutputPill];
    [self.terminal.webView evaluateJavaScript:@"exports.scrollToBottom()" completionHandler:nil];
}

- (void)showCopyToastWithLength:(NSUInteger)length {
    if (self.clipboardToast == nil) {
        UILabel *toast = [UILabel new];
        toast.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        toast.textColor = UIColor.whiteColor;
        toast.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
        toast.layer.cornerRadius = 10;
        toast.layer.masksToBounds = YES;
        toast.textAlignment = NSTextAlignmentCenter;
        toast.userInteractionEnabled = NO;
        self.clipboardToast = toast;
        [self addSubview:toast];
    }
    self.clipboardToast.text = [NSString stringWithFormat:@"  Copied %lu chars  ", (unsigned long)length];
    [self.clipboardToast sizeToFit];
    self.clipboardToast.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMaxY(self.bounds) - 60);
    // Cancel any in-flight fade so a rapid second copy stays visible.
    [self.toastAnimator stopAnimation:YES];
    self.toastAnimator = nil;
    self.clipboardToast.alpha = 1;
    self.clipboardToast.hidden = NO;
    self.toastAnimator = [[UIViewPropertyAnimator alloc] initWithDuration:0.9 curve:UIViewAnimationCurveEaseIn animations:^{
        self.clipboardToast.alpha = 0;
    }];
    [self.toastAnimator addCompletion:^(UIViewAnimatingPosition finalPosition) {
        self.clipboardToast.hidden = YES;
    }];
    [self.toastAnimator startAnimationAfterDelay:0.8];
}

- (void)hidePasteMenu {
    if (@available(iOS 16.0, *)) {
        [self.pasteEditMenu dismissMenu];
    } else {
        [UIMenuController.sharedMenuController setMenuVisible:NO animated:YES];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)selectTerminalText:(UILongPressGestureRecognizer *)gesture {
    if (!self.terminal.loaded)
        return;
    CGPoint pointInSelf = [gesture locationInView:self];
    CGPoint pointInWebView = [gesture locationInView:self.terminal.webView];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        // Hold still → paste popup. Move → selection drag. Decide by movement.
        self.selectionDragMode = NO;
        self.selectionGestureStart = pointInSelf;
        self.longPressHoldTimer = [NSTimer scheduledTimerWithTimeInterval:0.35
                                                                     target:self
                                                                   selector:@selector(showPasteMenuFromTimer:)
                                                                   userInfo:[NSValue valueWithCGPoint:pointInSelf]
                                                                    repeats:NO];
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        if (!self.selectionDragMode) {
            CGFloat moved = hypot(pointInSelf.x - self.selectionGestureStart.x, pointInSelf.y - self.selectionGestureStart.y);
            if (moved < 15)
                return; // still holding still; the paste timer keeps ticking
            [self.longPressHoldTimer invalidate];
            self.longPressHoldTimer = nil;
            self.selectionDragMode = YES;
            self.scrollbarView.scrollEnabled = NO;
            [self.terminal.webView evaluateJavaScript:[NSString stringWithFormat:@"exports.beginSelection(%f,%f)", pointInWebView.x, pointInWebView.y] completionHandler:nil];
        }
        [self loupeTrackGesturePoint:pointInWebView];
        [self updateAutoscrollForPoint:pointInSelf endpoint:nil];
        [self.terminal.webView evaluateJavaScript:[NSString stringWithFormat:@"exports.extendSelection(%f,%f)", pointInWebView.x, pointInWebView.y] completionHandler:nil];
    } else if (gesture.state == UIGestureRecognizerStateEnded) {
        [self.longPressHoldTimer invalidate];
        self.longPressHoldTimer = nil;
        [self hideSelectionLoupe];
        [self stopAutoscroll];
        if (self.selectionDragMode) {
            self.scrollbarView.scrollEnabled = YES;
            // Auto-copy is the copy UX: every settled selection copies.
            [self copySelectionToPasteboard];
        }
        self.selectionDragMode = NO;
    } else {
        [self.longPressHoldTimer invalidate];
        self.longPressHoldTimer = nil;
        [self hideSelectionLoupe];
        [self stopAutoscroll];
        if (self.selectionDragMode)
            self.scrollbarView.scrollEnabled = YES;
        self.selectionDragMode = NO;
    }
}

- (void)showPasteMenuFromTimer:(NSTimer *)timer {
    self.longPressHoldTimer = nil;
    self.selectionDragMode = NO;
    CGPoint point = ((NSValue *)timer.userInfo).CGPointValue;
    if (@available(iOS 16.0, *)) {
        if (self.pasteEditMenu == nil) {
            self.pasteEditMenu = [[UIEditMenuInteraction alloc] initWithDelegate:self];
            [self addInteraction:self.pasteEditMenu];
        }
        [self.pasteEditMenu presentEditMenuWithConfiguration:[UIEditMenuConfiguration configurationWithIdentifier:nil sourcePoint:point]];
    } else {
        UIMenuController *menuController = UIMenuController.sharedMenuController;
        UIMenuItem *pasteItem = [[UIMenuItem alloc] initWithTitle:@"Paste" action:@selector(paste:)];
        [menuController setMenuItems:@[pasteItem]];
        [menuController setTargetRect:CGRectMake(point.x, point.y, 1, 1) inView:self];
        [menuController setMenuVisible:YES animated:YES];
    }
}

- (UIMenu *)editMenuInteraction:(UIEditMenuInteraction *)interaction menuForConfiguration:(UIEditMenuConfiguration *)configuration suggestedActions:(NSArray<UIMenuElement *> *)suggestedActions API_AVAILABLE(ios(16.0)) {
    __weak TerminalView *view = self;
    UIAction *paste = [UIAction actionWithTitle:@"Paste" image:[UIImage systemImageNamed:@"doc.on.clipboard"] identifier:nil handler:^(UIAction *action) {
        [view paste:nil];
    }];
    return [UIMenu menuWithChildren:@[paste]];
}

// The edit menu interaction was removed: auto-copy on selection settle is
// the copy UX, and Select All was never useful on a terminal.


- (void)clearScrollback:(UIKeyCommand *)command {
    [self.terminal.webView evaluateJavaScript:@"exports.clearScrollback()" completionHandler:nil];
}

#pragma mark Floating cursor

- (void)updateFloatingCursorSensitivity {
    [self.terminal.webView evaluateJavaScript:@"exports.getCharacterSize()" completionHandler:^(NSArray *charSizeRaw, NSError *error) {
        if (error != nil) {
            NSLog(@"error getting character size: %@", error);
            return;
        }
        if (![charSizeRaw isKindOfClass:NSArray.class] || charSizeRaw.count < 2 ||
            ![charSizeRaw[0] isKindOfClass:NSNumber.class] || ![charSizeRaw[1] isKindOfClass:NSNumber.class])
            return;
        CGSize charSize = CGSizeMake([charSizeRaw[0] doubleValue], [charSizeRaw[1] doubleValue]);
        if (!isfinite(charSize.width) || !isfinite(charSize.height) || charSize.width <= 0 || charSize.height <= 0)
            return;
        double sensitivity = 0.5;
        self.floatingCursorSensitivity = CGSizeMake(charSize.width / sensitivity, charSize.height / sensitivity);
    }];
}

- (struct rowcol)rowcolFromPoint:(CGPoint)point {
    CGSize sensitivity = self.actualFloatingCursorSensitivity;
    return (struct rowcol) {
        .row = (int) (-point.y / sensitivity.height),
        .col = (int) (point.x / sensitivity.width),
    };
}

- (void)beginFloatingCursorAtPoint:(CGPoint)point {
    self.actualFloatingCursorSensitivity = self.floatingCursorSensitivity;
    self.floatingCursor = [self rowcolFromPoint:point];
}

- (void)updateFloatingCursorAtPoint:(CGPoint)point {
    // UIKit can probe the floating cursor before a terminal is attached; a nil
    // terminal here used to crash appendString: with a nil arrow sequence.
    if (self.terminal == nil || self.terminal.webView == nil)
        return;
    struct rowcol newPos = [self rowcolFromPoint:point];
    int rowDiff = newPos.row - self.floatingCursor.row;
    int colDiff = newPos.col - self.floatingCursor.col;
    NSMutableString *arrows = [NSMutableString string];
    for (int i = 0; i < abs(rowDiff); i++) {
        [arrows appendString:[self.terminal arrow:rowDiff > 0 ? 'A': 'B'] ?: @""];
    }
    for (int i = 0; i < abs(colDiff); i++) {
        [arrows appendString:[self.terminal arrow:colDiff > 0 ? 'C': 'D'] ?: @""];
    }
    [self insertText:arrows];
    self.floatingCursor = newPos;
}

- (void)endFloatingCursor {
    self.floatingCursor = (struct rowcol) {};
}

#pragma mark Keyboard Traits

- (UITextSmartDashesType)smartDashesType API_AVAILABLE(ios(11)) {
    return UITextSmartDashesTypeNo;
}
- (UITextSmartQuotesType)smartQuotesType API_AVAILABLE(ios(11)) {
    return UITextSmartQuotesTypeNo;
}
- (UITextSmartInsertDeleteType)smartInsertDeleteType API_AVAILABLE(ios(11)) {
    return UITextSmartInsertDeleteTypeNo;
}
- (UITextAutocapitalizationType)autocapitalizationType {
    return UITextAutocapitalizationTypeNone;
}
- (UITextAutocorrectionType)autocorrectionType {
    return UITextAutocorrectionTypeNo;
}
// Apparently required on iOS 15+: https://stackoverflow.com/a/72359764
- (UITextSpellCheckingType)spellCheckingType {
    return UITextSpellCheckingTypeNo;
}

#pragma mark Hardware Keyboard

- (void)handleKeyCommand:(UIKeyCommand *)command {
    NSString *key = command.input;
    if (command.modifierFlags == 0) {
        if ([key isEqualToString:@"`"] && UserPreferences.shared.backtickMapEscape)
            key = UIKeyInputEscape;
        if ([key isEqualToString:UIKeyInputEscape])
            key = @"\x1b";
        else if ([key isEqualToString:UIKeyInputUpArrow])
            key = [self.terminal arrow:'A'];
        else if ([key isEqualToString:UIKeyInputDownArrow])
            key = [self.terminal arrow:'B'];
        else if ([key isEqualToString:UIKeyInputLeftArrow])
            key = [self.terminal arrow:'D'];
        else if ([key isEqualToString:UIKeyInputRightArrow])
            key = [self.terminal arrow:'C'];
        [self insertText:key];
    } else if (command.modifierFlags & UIKeyModifierShift) {
        [self insertText:[key uppercaseString]];
    } else if (command.modifierFlags & UIKeyModifierAlternate) {
        [self insertText:[@"\x1b" stringByAppendingString:key]];
    } else if (command.modifierFlags & UIKeyModifierAlphaShift) {
        [self handleCapsLockWithCommand:command];
    } else if (command.modifierFlags & UIKeyModifierControl || command.modifierFlags & UIKeyModifierAlphaShift) {
        if (key.length == 0)
            return;
        if ([key isEqualToString:@"2"])
            key = @"@";
        else if ([key isEqualToString:@"6"])
            key = @"^";
        else if ([key isEqualToString:@"-"])
            key = @"_";
        [self insertControlChar:[key characterAtIndex:0]];
    }
}

static const char *alphabet = "abcdefghijklmnopqrstuvwxyz";
static const char *controlKeys = "abcdefghijklmnopqrstuvwxyz@^26-=[]\\ ";
static const char *metaKeys = "abcdefghijklmnopqrstuvwxyz0123456789-=[]\\;',./";

- (NSArray<UIKeyCommand *> *)keyCommands {
    if (_keyCommands != nil)
        return _keyCommands;
    _keyCommands = [NSMutableArray new];
    [self addKeys:controlKeys withModifiers:UIKeyModifierControl];
    for (NSString *specialKey in @[UIKeyInputEscape, UIKeyInputUpArrow, UIKeyInputDownArrow,
                                   UIKeyInputLeftArrow, UIKeyInputRightArrow, @"\t"]) {
        [self addKey:specialKey withModifiers:0];
    }
    if (UserPreferences.shared.capsLockMapping != CapsLockMapNone) {
        if (@available(iOS 13, *)); else {
            [self addKeys:controlKeys withModifiers:UIKeyModifierAlphaShift];
            [self addKeys:alphabet withModifiers:0];
            [self addKeys:alphabet withModifiers:UIKeyModifierShift];
            [self addKey:@"" withModifiers:UIKeyModifierAlphaShift]; // otherwise tap of caps lock can switch layouts
        }
    }
    if (UserPreferences.shared.optionMapping == OptionMapEsc) {
        [self addKeys:metaKeys withModifiers:UIKeyModifierAlternate];
    }
    if (UserPreferences.shared.backtickMapEscape) {
        [self addKey:@"`" withModifiers:0];
    }
    [_keyCommands addObject:[UIKeyCommand keyCommandWithInput:@"k"
                                                modifierFlags:UIKeyModifierCommand|UIKeyModifierShift
                                                       action:@selector(clearScrollback:)
                                         discoverabilityTitle:@"Clear Scrollback"]];
    return _keyCommands;
}

- (void)addKeys:(const char *)keys withModifiers:(UIKeyModifierFlags)modifiers {
    for (size_t i = 0; keys[i] != '\0'; i++) {
        [self addKey:[NSString stringWithFormat:@"%c", keys[i]] withModifiers:modifiers];
    }
}

- (void)addKey:(NSString *)key withModifiers:(UIKeyModifierFlags)modifiers {
    UIKeyCommand *command = [UIKeyCommand keyCommandWithInput:key
                                                modifierFlags:modifiers
                                                       action:@selector(handleKeyCommand:)];
    if (@available(iOS 15, *)) {
        command.wantsPriorityOverSystemBehavior = YES;
    }
    [_keyCommands addObject:command];
}

- (void)keyCommandTriggered:(UIKeyCommand *)sender {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self handleKeyCommand:sender];
    });
}

- (void)handleCapsLockWithCommand:(UIKeyCommand *)command {
    CapsLockMapping target = UserPreferences.shared.capsLockMapping;
    NSString *newInput = command.input ? command.input : @"";
    UIKeyModifierFlags flags = command.modifierFlags;
    flags ^= UIKeyModifierAlphaShift;
    if(target == CapsLockMapEscape) {
        newInput = UIKeyInputEscape;
    } else if(target == CapsLockMapControl) {
        if([newInput length] == 0) {
            return;
        }
        flags |= UIKeyModifierControl;
    } else {
        return;
    }

    UIKeyCommand *newCommand = [UIKeyCommand keyCommandWithInput:newInput
                                                   modifierFlags:flags
                                                          action:@selector(keyCommandTriggered:)];
    [self handleKeyCommand:newCommand];
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (@available(iOS 13.4, *)) {
        UIKey *key = presses.anyObject.key;
        if (UserPreferences.shared.overrideControlSpace &&
            key.keyCode == UIKeyboardHIDUsageKeyboardSpacebar &&
            key.modifierFlags & UIKeyModifierControl) {
            return [self insertControlChar:' '];
        }
    }
    return [super pressesBegan:presses withEvent:event];
}

#pragma mark UITextInput stubs

#if 0
#define LogStub() NSLog(@"%s", __func__)
#else
#define LogStub()
#endif

- (NSWritingDirection)baseWritingDirectionForPosition:(nonnull UITextPosition *)position inDirection:(UITextStorageDirection)direction { LogStub(); return NSWritingDirectionLeftToRight; }
- (void)setBaseWritingDirection:(NSWritingDirection)writingDirection forRange:(nonnull UITextRange *)range { LogStub(); }
- (UITextPosition *)beginningOfDocument { LogStub(); return nil; }
- (CGRect)caretRectForPosition:(nonnull UITextPosition *)position { LogStub(); return CGRectZero; }
- (nullable UITextRange *)characterRangeAtPoint:(CGPoint)point { LogStub(); return nil; }
- (nullable UITextRange *)characterRangeByExtendingPosition:(nonnull UITextPosition *)position inDirection:(UITextLayoutDirection)direction { LogStub(); return nil; }
- (nullable UITextPosition *)closestPositionToPoint:(CGPoint)point { LogStub(); return nil; }
- (nullable UITextPosition *)closestPositionToPoint:(CGPoint)point withinRange:(nonnull UITextRange *)range { LogStub(); return nil; }
- (NSComparisonResult)comparePosition:(nonnull UITextPosition *)position toPosition:(nonnull UITextPosition *)other { LogStub(); return NSOrderedSame; }
- (UITextPosition *)endOfDocument { LogStub(); return nil; }
- (CGRect)firstRectForRange:(nonnull UITextRange *)range { LogStub(); return CGRectZero; }
- (NSDictionary<NSAttributedStringKey,id> *)markedTextStyle { LogStub(); return nil; }
- (void)setMarkedTextStyle:(NSDictionary<NSAttributedStringKey,id> *)markedTextStyle { LogStub(); }
- (NSInteger)offsetFromPosition:(nonnull UITextPosition *)from toPosition:(nonnull UITextPosition *)toPosition { LogStub(); return 0; }
- (nullable UITextPosition *)positionFromPosition:(nonnull UITextPosition *)position inDirection:(UITextLayoutDirection)direction offset:(NSInteger)offset { LogStub(); return nil; }
- (nullable UITextPosition *)positionFromPosition:(nonnull UITextPosition *)position offset:(NSInteger)offset { LogStub(); return nil; }
- (nullable UITextPosition *)positionWithinRange:(nonnull UITextRange *)range farthestInDirection:(UITextLayoutDirection)direction { LogStub(); return nil; }
- (void)replaceRange:(nonnull UITextRange *)range withText:(nonnull NSString *)text { LogStub(); }
- (void)setSelectedTextRange:(UITextRange *)selectedTextRange { LogStub(); }
- (nonnull NSArray<UITextSelectionRect *> *)selectionRectsForRange:(nonnull UITextRange *)range { LogStub(); return @[]; }
- (nullable UITextRange *)textRangeFromPosition:(nonnull UITextPosition *)fromPosition toPosition:(nonnull UITextPosition *)toPosition { LogStub(); return nil; }

// conforming to UITextInput makes this view default to being an accessibility element, which blocks selecting anything in it
- (BOOL)isAccessibilityElement { return NO; }

@end
