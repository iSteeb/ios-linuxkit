//
//  ExtraKeysBarView.m
//  LinuxKit (ios-linuxkit)
//

#import "ExtraKeysBarView.h"
#import "BarButton.h"
#import "UserPreferences.h"

NSString *const ExtraKeysSettingsToken = @":settings";

static const CGFloat BarButtonHeight = 36;
static const CGFloat FixedButtonWidth = 44;
static const CGFloat ArrowClusterWidth = 96;
static const CGFloat StackSpacing = 6;
static const CGFloat BarHeight = 44;

@interface ExtraKeysBarView ()
@property (nonatomic, strong) UIStackView *rootStack;
@property (nonatomic, strong) UIScrollView *scrollCenter;
@property (nonatomic, strong) UIStackView *centerStack;
@property (nonatomic, strong) ArrowBarButton *arrowCluster;
@property (nonatomic, strong) BarButton *controlButtonImpl;
@end

@implementation ExtraKeysBarView

- (instancetype)initWithFrame:(CGRect)frame {
    // UIKit sizes the accessory view: keep autoresizing for self (width follows keyboard).
    self = [super initWithFrame:CGRectMake(0, 0, 320, BarHeight)
                   inputViewStyle:UIInputViewStyleKeyboard];
    if (self) {
        [self buildBar];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self buildBar];
    }
    return self;
}

- (BarButton *)fixedButton {
    BarButton *button = [BarButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [self styleKeyButton:button];
    [button.heightAnchor constraintEqualToConstant:BarButtonHeight].active = YES;
    [button.widthAnchor constraintGreaterThanOrEqualToConstant:36].active = YES;
    [button setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return button;
}

- (void)styleKeyButton:(BarButton *)button {
    // BarButton applies its key styling in awakeFromNib (storyboard path only);
    // replicate it here for code-created buttons, slightly rounder.
    button.layer.cornerRadius = 8;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOffset = CGSizeMake(0, 1);
    button.layer.shadowOpacity = 0.4;
    button.layer.shadowRadius = 0;
}

- (UIImage *)keySymbol:(NSString *)name {
    UIImage *image = [UIImage systemImageNamed:name];
    if (image == nil)
        return nil;
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
    return [image imageByApplyingSymbolConfiguration:configuration];
}

- (void)buildBar {
    // Single horizontal root stack pinned to the bar's edges.
    self.rootStack = [[UIStackView alloc] init];
    self.rootStack.axis = UILayoutConstraintAxisHorizontal;
    self.rootStack.alignment = UIStackViewAlignmentCenter;
    self.rootStack.distribution = UIStackViewDistributionFill;
    self.rootStack.spacing = StackSpacing;
    self.rootStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.rootStack];
    [NSLayoutConstraint activateConstraints:@[
        [self.rootStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],
        [self.rootStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],
        [self.rootStack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];

    // Fixed leading keys: esc, tab, ctrl
    BarButton *escapeButton = [self fixedButton];
    [escapeButton addTarget:self action:@selector(escapeTapped) forControlEvents:UIControlEventTouchUpInside];
    [escapeButton setTitle:nil forState:UIControlStateNormal];
    [escapeButton setImage:[self keySymbol:@"escape"] forState:UIControlStateNormal];

    BarButton *tabButton = [self fixedButton];
    [tabButton addTarget:self action:@selector(tabTapped) forControlEvents:UIControlEventTouchUpInside];
    tabButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [tabButton setTitle:@"tab" forState:UIControlStateNormal];

    self.controlButtonImpl = [self fixedButton];
    [self.controlButtonImpl addTarget:self action:@selector(controlTapped) forControlEvents:UIControlEventTouchUpInside];
    self.controlButtonImpl.toggleable = YES;
    [self.controlButtonImpl setTitle:nil forState:UIControlStateNormal];
    [self.controlButtonImpl setImage:[self keySymbol:@"control"] forState:UIControlStateNormal];

    // Scrollable, user-editable center section
    self.scrollCenter = [[UIScrollView alloc] init];
    self.scrollCenter.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollCenter.showsHorizontalScrollIndicator = NO;
    self.scrollCenter.alwaysBounceVertical = NO;
    [self.scrollCenter.heightAnchor constraintEqualToConstant:BarButtonHeight].active = YES;
    [self.scrollCenter setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [self.scrollCenter setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    self.centerStack = [[UIStackView alloc] init];
    self.centerStack.axis = UILayoutConstraintAxisHorizontal;
    self.centerStack.spacing = StackSpacing;
    self.centerStack.alignment = UIStackViewAlignmentCenter;
    self.centerStack.distribution = UIStackViewDistributionFill;
    self.centerStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollCenter addSubview:self.centerStack];
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollCenter.contentLayoutGuide.leadingAnchor constraintEqualToAnchor:self.centerStack.leadingAnchor],
        [self.scrollCenter.contentLayoutGuide.trailingAnchor constraintEqualToAnchor:self.centerStack.trailingAnchor],
        [self.scrollCenter.contentLayoutGuide.topAnchor constraintEqualToAnchor:self.centerStack.topAnchor],
        [self.scrollCenter.contentLayoutGuide.bottomAnchor constraintEqualToAnchor:self.centerStack.bottomAnchor],
        // Content centers when short, scrolls when longer than the available width.
        [self.centerStack.widthAnchor constraintGreaterThanOrEqualToAnchor:self.scrollCenter.frameLayoutGuide.widthAnchor],
    ]];

    // Arrow cluster (frame-drawn: needs explicit bounds)
    self.arrowCluster = [[ArrowBarButton alloc] initWithFrame:CGRectMake(0, 0, ArrowClusterWidth, BarButtonHeight)];
    self.arrowCluster.translatesAutoresizingMaskIntoConstraints = NO;
    [self.arrowCluster addTarget:self action:@selector(arrowTapped:) forControlEvents:UIControlEventValueChanged];
    [self.arrowCluster.widthAnchor constraintEqualToConstant:ArrowClusterWidth].active = YES;
    [self.arrowCluster.heightAnchor constraintEqualToConstant:BarButtonHeight].active = YES;
    [self.arrowCluster setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.arrowCluster setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    [self.rootStack addArrangedSubview:escapeButton];
    [self.rootStack addArrangedSubview:tabButton];
    [self.rootStack addArrangedSubview:self.controlButtonImpl];
    [self.rootStack addArrangedSubview:self.scrollCenter];
    [self.rootStack addArrangedSubview:self.arrowCluster];

    self.keyAppearance = UIKeyboardAppearanceLight;
    [self reloadKeys];
}

- (void)reloadKeys {
    for (UIView *view in self.centerStack.arrangedSubviews) {
        [self.centerStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    for (NSString *token in UserPreferences.shared.extraKeys) {
        BarButton *button = [BarButton buttonWithType:UIButtonTypeSystem];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        if ([token isEqualToString:ExtraKeysSettingsToken]) {
            [button setTitle:nil forState:UIControlStateNormal];
            [button setImage:[self keySymbol:@"gearshape"] forState:UIControlStateNormal];
            button.tag = 1;
        } else {
            [button setTitle:token forState:UIControlStateNormal];
            button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
            button.tag = 0;
        }
        [button addTarget:self action:@selector(keyTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self styleKeyButton:button];
        [button.heightAnchor constraintEqualToConstant:BarButtonHeight].active = YES;
        [button.widthAnchor constraintGreaterThanOrEqualToConstant:34].active = YES;
        button.contentEdgeInsets = UIEdgeInsetsMake(0, 6, 0, 6);
        button.keyAppearance = self.keyAppearance;
        [self.centerStack addArrangedSubview:button];
    }
}

#pragma mark - Styling

- (void)setKeyAppearance:(UIKeyboardAppearance)keyAppearance {
    _keyAppearance = keyAppearance;
    for (UIView *view in self.rootStack.arrangedSubviews) {
        if ([view isKindOfClass:[BarButton class]]) {
            ((BarButton *)view).keyAppearance = keyAppearance;
        }
    }
    for (UIView *view in self.centerStack.arrangedSubviews) {
        if ([view isKindOfClass:[BarButton class]]) {
            ((BarButton *)view).keyAppearance = keyAppearance;
        }
    }
    self.arrowCluster.keyAppearance = keyAppearance;
}

- (UIButton *)controlButton {
    return self.controlButtonImpl;
}

#pragma mark - Actions

- (void)escapeTapped {
    if (self.onEscape) self.onEscape();
}

- (void)tabTapped {
    if (self.onTab) self.onTab();
}

- (void)controlTapped {
    self.controlButtonImpl.selected = !self.controlButtonImpl.selected;
}

- (void)arrowTapped:(ArrowBarButton *)sender {
    if (self.onArrow) self.onArrow(sender.direction);
}

- (void)keyTapped:(BarButton *)sender {
    if (sender.tag == 1) {
        if (self.onSettings) self.onSettings();
        return;
    }
    NSString *token = [sender titleForState:UIControlStateNormal];
    if (token != nil && self.onKey) self.onKey(token);
}

@end
