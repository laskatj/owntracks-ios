//
//  TVRecorderTokenStore.m
//  SauronTV
//

#import "TVRecorderTokenStore.h"
#import <Security/Security.h>
#import <CocoaLumberjack/CocoaLumberjack.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

NSString * const TVRecorderOAuthTokensDidChangeNotification = @"TVRecorderOAuthTokensDidChange";

static NSString *TVRecorderKeychainService(void) {
    return @"org.owntracks.sauron.recorder";
}

static NSString *TVRecorderKeychainAccount(void) {
    return @"oauth";
}

@implementation TVRecorderTokenStore

+ (nullable NSDictionary *)readPayload {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: TVRecorderKeychainService(),
        (__bridge id)kSecAttrAccount: TVRecorderKeychainAccount(),
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef out = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)query, &out);
    if (st != errSecSuccess || out == NULL) {
        if (st != errSecItemNotFound) {
            DDLogInfo(@"[TVRecorderTokenStore] Keychain read status=%d (errSecItemNotFound=%d)",
                      (int)st, (int)errSecItemNotFound);
        }
        return nil;
    }
    NSData *data = (__bridge_transfer NSData *)out;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? (NSDictionary *)obj : nil;
}

+ (nullable NSString *)accessToken {
    return [self readPayload][@"access_token"];
}

+ (nullable NSString *)refreshToken {
    return [self readPayload][@"refresh_token"];
}

+ (NSTimeInterval)accessTokenExpiry {
    NSNumber *n = [self readPayload][@"expires_at"];
    return n ? n.doubleValue : 0;
}

+ (BOOL)hasUsableAccessToken {
    NSString *t = [self accessToken];
    if (!t.length) return NO;
    NSTimeInterval exp = [self accessTokenExpiry];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (exp <= 0) {
        DDLogVerbose(@"[TVRecorderTokenStore] hasUsableAccessToken YES (no expires_at stored)");
        return YES;
    }
    BOOL ok = exp > (now + 5.0);
    if (!ok) {
        DDLogInfo(@"[TVRecorderTokenStore] access token present but expiry in past/near: exp=%.0f now=%.0f delta=%.0fs",
                  exp, now, exp - now);
    }
    return ok;
}

+ (void)saveAccessToken:(NSString *)accessToken
           refreshToken:(nullable NSString *)refreshToken
              expiresIn:(NSInteger)expiresIn {
    NSMutableDictionary *payload = [[self readPayload] mutableCopy] ?: [NSMutableDictionary dictionary];
    payload[@"access_token"] = accessToken;
    if (refreshToken.length) {
        payload[@"refresh_token"] = refreshToken;
    } else {
        [payload removeObjectForKey:@"refresh_token"];
    }
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSInteger ei = MAX(0, expiresIn);
    NSTimeInterval skew = MIN(120.0, MAX(10.0, ei * 0.15));
    if (ei == 0) {
        skew = 0;
    }
    NSTimeInterval exp = now + ei - skew;
    if (ei > 0 && exp <= now + 15.0) {
        exp = now + MAX(30.0, (NSTimeInterval)ei - 5.0);
    }
    payload[@"expires_at"] = @(exp);

    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&err];
    if (!data) {
        DDLogError(@"[TVRecorderTokenStore] JSON encode failed: %@", err);
        return;
    }

    [self clear];
    NSDictionary *add = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: TVRecorderKeychainService(),
        (__bridge id)kSecAttrAccount: TVRecorderKeychainAccount(),
        (__bridge id)kSecValueData: data,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    };
    OSStatus addSt = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    if (addSt != errSecSuccess) {
        DDLogError(@"[TVRecorderTokenStore] SecItemAdd failed status=%d (access_len=%lu refresh=%d expires_in=%ld)",
                    (int)addSt, (unsigned long)accessToken.length, refreshToken.length > 0, (long)expiresIn);
        return;
    }
    DDLogInfo(@"[TVRecorderTokenStore] saved tokens keychain OK (access_len=%lu has_refresh=%d expires_in=%ld exp_epoch=%.0f skew=%.0f)",
              (unsigned long)accessToken.length, refreshToken.length > 0, (long)expiresIn, exp, skew);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:TVRecorderOAuthTokensDidChangeNotification object:nil];
    });
}

+ (void)clear {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: TVRecorderKeychainService(),
        (__bridge id)kSecAttrAccount: TVRecorderKeychainAccount(),
    };
    SecItemDelete((__bridge CFDictionaryRef)query);
    DDLogInfo(@"[TVRecorderTokenStore] Keychain cleared");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:TVRecorderOAuthTokensDidChangeNotification object:nil];
    });
}

@end
