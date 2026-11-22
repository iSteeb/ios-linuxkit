//
//  ExtraKeysBarView.h
//  LinuxKit (ios-linuxkit)
//
//  Accessory bar above the keyboard: first-class esc/tab/ctrl/paste,
//  scrollable user-editable center section, arrows.
//

#import <UIKit/UIKit.h>
#import "ArrowBarButton.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString *const ExtraKeysSettingsToken;

@interface ExtraKeysBarView : UIInputView

@property (nonatomic) UIKeyboardAppearance keyAppearance;

@property (nonatomic, readonly) UIButton *controlButton;

@property (nonatomic, copy, nullable) void (^onKey)(NSString *key);
@property (nonatomic, copy, nullable) void (^onEscape)(void);
@property (nonatomic, copy, nullable) void (^onTab)(void);
@property (nonatomic, copy, nullable) void (^onArrow)(ArrowDirection direction);
@property (nonatomic, copy, nullable) void (^onSettings)(void);

- (void)reloadKeys;

@end

NS_ASSUME_NONNULL_END
