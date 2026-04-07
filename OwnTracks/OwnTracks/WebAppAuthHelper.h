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

/// Completion: both accessToken and refreshToken if success, otherwise error.
/// refreshToken is the rotated token from the same exchange — nil if not returned by server.
typedef void (^WebAppAuthTokenPairCompletion)(NSString * _Nullable accessToken, NSString * _Nullable refreshToken, NSError * _Nullable error);

@interface WebAppAuthHelper : NSObject

+ (instancetype)sharedInstance;

/// Attempts a silent token refresh using a previously stored refresh token for the given origin.
/// Calls completion with a new access token on success, or nil if no stored token / refresh failed.
/// On failure the stored tokens for this origin are cleared so the next call goes through full auth.
- (void)attemptSilentRefreshForOrigin:(NSURL *)webAppOrigin
                           completion:(WebAppAuthCompletion)completion;

/// Attempts a silent token refresh using context-aware token storage.
/// webAppURL should be the configured app URL (including optional path prefix), and clientId may be nil.
- (void)attemptSilentRefreshForWebAppURL:(NSURL *)webAppURL
                                clientId:(nullable NSString *)clientId
                              completion:(WebAppAuthCompletion)completion;

/// Same as above but also returns the new refresh token so the web app can store it for independent renewal.
- (void)attemptSilentRefreshForWebAppURL:(NSURL *)webAppURL
                                clientId:(nullable NSString *)clientId
                     tokenPairCompletion:(WebAppAuthTokenPairCompletion)completion;

/// Clears any Keychain-stored refresh token data for the given origin.
- (void)clearStoredTokensForOrigin:(NSURL *)webAppOrigin;

/// Stores refresh token metadata in Keychain for a specific web app URL + client context.
- (void)storeRefreshToken:(NSString *)refreshToken
            tokenEndpoint:(NSString *)tokenEndpoint
                 clientId:(NSString *)clientId
                forWebAppURL:(NSURL *)webAppURL;

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

/// Starts an ASWebAuthenticationSession with the given IdP URL and returns the raw callback URL
/// (owntracks:///auth/callback?code=...&state=...) on success. Use this to proxy the web app's
/// own OIDC redirect through the system browser for SSO, without running a separate PKCE flow.
- (void)startPassthroughSessionWithURL:(NSURL *)idpURL
                             completion:(void (^)(NSURL * _Nullable callbackURL, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
