//
//  WebAppAuthHelper.h
//  OwnTracks
//
//  OAuth 2.0 / OIDC with PKCE via ASWebAuthenticationSession.
//  Fetches auth config from [webAppOrigin]/.well-known/owntracks-app-auth,
//  then presents system auth sheet and exchanges code for tokens.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Notification when the app receives the auth callback URL (e.g. from application:openURL).
/// userInfo[@"url"] is the NSURL with code and state query parameters.
extern NSNotificationName const WebAppAuthCallbackURLNotification;

/// Completion: accessToken if success, otherwise error. accessToken may be passed to backend native-callback.
typedef void (^WebAppAuthCompletion)(NSString * _Nullable accessToken, NSError * _Nullable error);

@interface WebAppAuthHelper : NSObject

+ (instancetype)sharedInstance;

/// Fetches discovery JSON from [webAppOrigin]/.well-known/owntracks-app-auth. Keys include authorization_endpoint, token_endpoint, client_id, scope, login_path.
- (void)fetchDiscoveryFromOrigin:(NSURL *)webAppOrigin
                     completion:(void (^)(NSDictionary * _Nullable config, NSError * _Nullable error))completion;

/// Fetches openid-configuration from discoveryURL and returns the authorization_endpoint URL for intercept matching (no clientId required).
- (void)fetchOIDCAuthorizationEndpointFromDiscoveryURL:(NSURL *)discoveryURL
                                             completion:(void (^)(NSURL * _Nullable authEndpointURL, NSError * _Nullable error))completion;

/// Fetches discovery from [webAppOrigin]/.well-known/owntracks-app-auth (or from oidcDiscoveryURL openid-configuration if provided), then starts ASWebAuthenticationSession.
/// If oidcDiscoveryURL and clientId are non-nil, fetches [oidcDiscoveryURL]/.well-known/openid-configuration and uses that IdP (same app as web). Otherwise uses owntracks-app-auth from webAppOrigin.
- (void)startAuthWithWebAppOrigin:(NSURL *)webAppOrigin
                 oidcDiscoveryURL:(nullable NSURL *)oidcDiscoveryURL
                         clientId:(nullable NSString *)clientId
          presentingViewController:(UIViewController *)presentingViewController
                       completion:(WebAppAuthCompletion)completion;

@end

NS_ASSUME_NONNULL_END
