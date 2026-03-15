//
//  OIDCManager.h
//  OwnTracks
//
//  Singleton that manages OIDC authentication state using AppAuth.
//  Stores OIDAuthState in the Keychain and handles token refresh.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class OIDExternalUserAgentSession;

NS_ASSUME_NONNULL_BEGIN

@interface OIDCManager : NSObject

+ (instancetype)sharedInstance;

/// The in-progress authorization session (set during the auth code flow).
/// AppDelegate must pass the redirect URL to this object to complete the flow.
@property (nonatomic, strong, nullable) id<NSObject> currentAuthorizationFlow;

/// Returns YES if there is a stored auth state with tokens (may still be expired).
- (BOOL)hasStoredSession;

/// Obtains a fresh access token, refreshing if necessary.
/// Calls back on the main queue.
- (void)freshAccessToken:(void(^)(NSString * _Nullable accessToken, NSError * _Nullable error))completion;

/// Starts the full OIDC authorization flow from the given view controller.
/// Shows ASWebAuthenticationSession / SFSafariViewController for the login page.
/// Calls back on the main queue with the access token on success.
- (void)startAuthFromViewController:(UIViewController *)viewController
                         completion:(void(^)(NSString * _Nullable accessToken, NSError * _Nullable error))completion;

/// Clears all stored tokens from Keychain.
- (void)clearSession;

@end

NS_ASSUME_NONNULL_END
