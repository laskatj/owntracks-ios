//
//  TVRecorderTokenStore.h
//  SauronTV
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main thread after Keychain token data is saved or cleared.
extern NSString * const TVRecorderOAuthTokensDidChangeNotification;

@interface TVRecorderTokenStore : NSObject

+ (nullable NSString *)accessToken;
+ (nullable NSString *)refreshToken;

/// Seconds since 1970 when access token should be treated as expired (includes skew).
+ (NSTimeInterval)accessTokenExpiry;

/// True if access token exists and is not within 60s of expiry.
+ (BOOL)hasUsableAccessToken;

+ (void)saveAccessToken:(NSString *)accessToken
           refreshToken:(nullable NSString *)refreshToken
              expiresIn:(NSInteger)expiresIn;

+ (void)clear;

@end

NS_ASSUME_NONNULL_END
