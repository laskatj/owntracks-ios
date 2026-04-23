//
//  TVRecorderOAuthClient.h
//  SauronTV
//
//  OIDC discovery, RFC 8628 device flow coordination, refresh_token exchange.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const TVRecorderOAuthErrorDomain;

typedef NS_ENUM(NSInteger, TVRecorderOAuthErrorCode) {
    TVRecorderOAuthErrorCancelled = 1,
    TVRecorderOAuthErrorNetwork     = 2,
};

@interface TVRecorderOAuthClient : NSObject

+ (instancetype)shared;

/// Cached from discovery; nil until first successful discovery fetch.
@property (nonatomic, readonly, nullable) NSURL *deviceAuthorizationEndpoint;
@property (nonatomic, readonly, nullable) NSURL *tokenEndpoint;

/// Clears cached discovery URLs (e.g. after sign-out).
- (void)resetCachedDiscovery;

- (void)fetchDiscoveryWithCompletion:(void (^)(NSError * _Nullable error))completion;

/// POST refresh_token grant; updates Keychain on success.
- (void)refreshAccessTokenWithCompletion:(void (^)(NSString * _Nullable accessToken,
                                                    NSError * _Nullable error))completion;

/// POST device authorization endpoint; returns JSON dictionary (device_code, user_code, etc.) on success.
- (void)requestDeviceAuthorizationWithCompletion:(void (^)(NSDictionary * _Nullable json,
                                                          NSError * _Nullable error))completion;

/// Poll token endpoint once for device_code grant.
- (void)pollTokenWithDeviceCode:(NSString *)deviceCode
                     completion:(void (^)(NSDictionary * _Nullable tokens,
                                          BOOL authorizationPending,
                                          BOOL slowDown,
                                          NSError * _Nullable error))completion;

/// Bearer override, Keychain, refresh, or device sign-in (modal). All completions on main queue.
- (void)ensureValidAccessTokenPresentingSignInFrom:(UIViewController *)pvc
                                         completion:(void (^)(NSString * _Nullable accessToken,
                                                               NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
