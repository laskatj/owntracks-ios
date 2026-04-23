//
//  TVRecorderDeviceSignInViewController.h
//  SauronTV
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVRecorderDeviceSignInViewController : UIViewController

/// success YES when tokens saved to Keychain; err set on failure or cancel.
- (instancetype)initWithCompletion:(void (^)(BOOL success, NSError * _Nullable err))completion;

@end

NS_ASSUME_NONNULL_END
