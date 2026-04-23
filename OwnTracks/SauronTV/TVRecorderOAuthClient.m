//
//  TVRecorderOAuthClient.m
//  SauronTV
//

#import "TVRecorderOAuthClient.h"
#import "TVRecorderTokenStore.h"
#import "TVRecorderDeviceSignInViewController.h"
#import "TVHardcodedConfig.h"
#import <CocoaLumberjack/CocoaLumberjack.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

NSString * const TVRecorderOAuthErrorDomain = @"TVRecorderOAuthErrorDomain";

@interface TVRecorderOAuthClient ()
@property (nonatomic, readwrite, nullable) NSURL *deviceAuthorizationEndpoint;
@property (nonatomic, readwrite, nullable) NSURL *tokenEndpoint;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableArray<void (^)(NSString * _Nullable, NSError * _Nullable)> *ensureWaiters;
@property (nonatomic) BOOL ensurePipelineActive;
@end

@implementation TVRecorderOAuthClient

+ (instancetype)shared {
    static TVRecorderOAuthClient *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[self alloc] init];
    });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _session = [NSURLSession sharedSession];
        _ensureWaiters = [NSMutableArray array];
    }
    return self;
}

#pragma mark - Form POST helper

- (nullable NSData *)formBodyForQueryItems:(NSArray<NSURLQueryItem *> *)items {
    NSURLComponents *c = [NSURLComponents new];
    c.queryItems = items;
    NSString *q = c.percentEncodedQuery;
    return q ? [q dataUsingEncoding:NSUTF8StringEncoding] : nil;
}

- (void)postFormToURL:(NSURL *)url
                items:(NSArray<NSURLQueryItem *> *)items
           completion:(void (^)(NSData * _Nullable data, NSHTTPURLResponse * _Nullable http,
                                  NSError * _Nullable error))completion {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/x-www-form-urlencoded; charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
    NSData *body = [self formBodyForQueryItems:items];
    if (!body) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, nil, [NSError errorWithDomain:TVRecorderOAuthErrorDomain
                                                       code:TVRecorderOAuthErrorNetwork
                                                   userInfo:@{NSLocalizedDescriptionKey: @"Bad form body"}]);
        });
        return;
    }
    [req setHTTPBody:body];
    [[self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSHTTPURLResponse *http = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(data, http, err);
        });
    }] resume];
}

- (void)resetCachedDiscovery {
    self.deviceAuthorizationEndpoint = nil;
    self.tokenEndpoint = nil;
}

#pragma mark - Discovery

- (void)fetchDiscoveryWithCompletion:(void (^)(NSError * _Nullable error))completion {
    if (!kTVOAuthDiscoveryURL.length) {
        completion([NSError errorWithDomain:TVRecorderOAuthErrorDomain
                                        code:TVRecorderOAuthErrorNetwork
                                    userInfo:@{NSLocalizedDescriptionKey: @"Discovery URL not configured"}]);
        return;
    }
    NSURL *url = [NSURL URLWithString:kTVOAuthDiscoveryURL];
    if (!url) {
        completion([NSError errorWithDomain:TVRecorderOAuthErrorDomain
                                        code:TVRecorderOAuthErrorNetwork
                                    userInfo:@{NSLocalizedDescriptionKey: @"Invalid discovery URL"}]);
        return;
    }
    if (self.deviceAuthorizationEndpoint && self.tokenEndpoint) {
        completion(nil);
        return;
    }
    [[self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err || !data.length) {
                completion(err ?: [NSError errorWithDomain:TVRecorderOAuthErrorDomain
                                                      code:TVRecorderOAuthErrorNetwork
                                                  userInfo:@{NSLocalizedDescriptionKey: @"Empty discovery"}]);
                return;
            }
            NSError *je = nil;
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&je];
            if (![obj isKindOfClass:[NSDictionary class]]) {
                completion(je);
                return;
            }
            NSDictionary *d = (NSDictionary *)obj;
            NSString *du = d[@"device_authorization_endpoint"];
            NSString *tu = d[@"token_endpoint"];
            self.deviceAuthorizationEndpoint = du.length ? [NSURL URLWithString:du] : nil;
            self.tokenEndpoint = tu.length ? [NSURL URLWithString:tu] : nil;
            if (!self.deviceAuthorizationEndpoint || !self.tokenEndpoint) {
                completion([NSError errorWithDomain:TVRecorderOAuthErrorDomain
                                                code:TVRecorderOAuthErrorNetwork
                                            userInfo:@{NSLocalizedDescriptionKey: @"Discovery missing endpoints"}]);
                return;
            }
            DDLogInfo(@"[TVRecorderOAuth] discovery OK device=%@ token=%@", self.deviceAuthorizationEndpoint,
                      self.tokenEndpoint);
            completion(nil);
        });
    }] resume];
}

#pragma mark - Device + refresh

/// Appends `client_secret` when configured (Authentik confidential clients).
static NSArray<NSURLQueryItem *> *TVRecorderOAuthItemsWithOptionalSecret(NSArray<NSURLQueryItem *> *items) {
    if (!kTVOAuthClientSecret.length) return items;
    NSMutableArray *m = [items mutableCopy];
    [m addObject:[NSURLQueryItem queryItemWithName:@"client_secret" value:kTVOAuthClientSecret]];
    return [m copy];
}

- (void)requestDeviceAuthorizationWithCompletion:(void (^)(NSDictionary * _Nullable json,
                                                          NSError * _Nullable error))completion {
    [self fetchDiscoveryWithCompletion:^(NSError *err) {
        if (err) {
            completion(nil, err);
            return;
        }
        NSArray *items = TVRecorderOAuthItemsWithOptionalSecret(@[
            [NSURLQueryItem queryItemWithName:@"client_id" value:kTVOAuthClientId],
            [NSURLQueryItem queryItemWithName:@"scope" value:kTVOAuthScope],
        ]);
        [self postFormToURL:self.deviceAuthorizationEndpoint
                      items:items
                 completion:^(NSData *data, NSHTTPURLResponse *http, NSError *netErr) {
            if (netErr) {
                completion(nil, netErr);
                return;
            }
            if (http.statusCode < 200 || http.statusCode >= 300) {
                NSString *body = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
                completion(nil, [NSError errorWithDomain:TVRecorderOAuthErrorDomain
                                                    code:TVRecorderOAuthErrorNetwork
                                                userInfo:@{NSLocalizedDescriptionKey:
                                                               [NSString stringWithFormat:@"Device HTTP %ld %@", (long)http.statusCode, body]}]);
                return;
            }
            NSError *je = nil;
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&je];
            if (![obj isKindOfClass:[NSDictionary class]]) {
                completion(nil, je ?: [NSError errorWithDomain:TVRecorderOAuthErrorDomain
                                                          code:TVRecorderOAuthErrorNetwork
                                                      userInfo:@{NSLocalizedDescriptionKey: @"Bad device JSON"}]);
                return;
            }
            completion((NSDictionary *)obj, nil);
        }];
    }];
}

/// Normalizes OAuth `error` field from JSON (Authentik sends HTTP 400 with JSON for pending).
static NSString *TVRecorderOAuthErrorStringFromDict(NSDictionary *dict) {
    id v = dict[@"error"];
    if ([v isKindOfClass:[NSString class]]) {
        return [(NSString *)v lowercaseString];
    }
    return nil;
}

- (void)pollTokenWithDeviceCode:(NSString *)deviceCode
                     completion:(void (^)(NSDictionary * _Nullable tokens,
                                          BOOL authorizationPending,
                                          BOOL slowDown,
                                          NSError * _Nullable error))completion {
    if (!self.tokenEndpoint) {
        completion(nil, NO, NO, [NSError errorWithDomain:TVRecorderOAuthErrorDomain
                                                    code:TVRecorderOAuthErrorNetwork
                                                userInfo:@{NSLocalizedDescriptionKey: @"No token endpoint"}]);
        return;
    }
    NSArray *items = TVRecorderOAuthItemsWithOptionalSecret(@[
        [NSURLQueryItem queryItemWithName:@"grant_type"
                                    value:@"urn:ietf:params:oauth:grant-type:device_code"],
        [NSURLQueryItem queryItemWithName:@"client_id" value:kTVOAuthClientId],
        [NSURLQueryItem queryItemWithName:@"device_code" value:deviceCode],
    ]);
    [self postFormToURL:self.tokenEndpoint
                  items:items
             completion:^(NSData *data, NSHTTPURLResponse *http, NSError *netErr) {
        if (netErr) {
            completion(nil, NO, NO, netErr);
            return;
        }
        NSInteger status = http ? http.statusCode : 0;
        NSError *jsonErr = nil;
        id obj = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr] : nil;
        if (jsonErr && data.length) {
            DDLogVerbose(@"[TVRecorderOAuth] token poll JSON parse: %@", jsonErr.localizedDescription);
        }
        NSDictionary *dict = [obj isKindOfClass:[NSDictionary class]] ? (NSDictionary *)obj : nil;
        NSString *oauthErr = TVRecorderOAuthErrorStringFromDict(dict ?: @{});

        if ([oauthErr isEqualToString:@"authorization_pending"] || [oauthErr isEqualToString:@"slow_down"]) {
            BOOL slow = [oauthErr isEqualToString:@"slow_down"];
            completion(nil, YES, slow, nil);
            return;
        }

        id atObj = dict[@"access_token"];
        NSString *access = [atObj isKindOfClass:[NSString class]] ? (NSString *)atObj : nil;
        if (access.length) {
            completion(dict, NO, NO, nil);
            return;
        }

        if (oauthErr.length) {
            id ed = dict[@"error_description"];
            NSString *desc = ([ed isKindOfClass:[NSString class]] && [(NSString *)ed length])
                ? (NSString *)ed : oauthErr;
            if ([oauthErr isEqualToString:@"invalid_grant"]) {
                DDLogWarn(@"[TVRecorderOAuth] device token invalid_grant — if the Authentik app is "
                          @"confidential, set kTVOAuthClientSecret; if public, ensure client_id matches "
                          @"the app used at the device URL.");
            }
            completion(nil, NO, NO, [NSError errorWithDomain:TVRecorderOAuthErrorDomain
                                                          code:TVRecorderOAuthErrorNetwork
                                                      userInfo:@{NSLocalizedDescriptionKey: desc}]);
            return;
        }

        NSString *bodySnippet = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
        if (bodySnippet.length > 200) {
            bodySnippet = [bodySnippet substringToIndex:200];
        }
        if (status < 200 || status >= 300) {
            NSString *lower = bodySnippet.lowercaseString;
            if ([lower containsString:@"authorization_pending"] || [lower containsString:@"slow_down"]) {
                BOOL slow = [lower containsString:@"slow_down"];
                completion(nil, YES, slow, nil);
                return;
            }
            DDLogWarn(@"[TVRecorderOAuth] token poll HTTP %ld body=%@", (long)status, bodySnippet);
            completion(nil, NO, NO, [NSError errorWithDomain:TVRecorderOAuthErrorDomain
                                                            code:TVRecorderOAuthErrorNetwork
                                                        userInfo:@{NSLocalizedDescriptionKey:
                                                                       [NSString stringWithFormat:@"Token HTTP %ld %@", (long)status, bodySnippet]}]);
            return;
        }

        DDLogVerbose(@"[TVRecorderOAuth] token poll 2xx without access_token; treating as pending");
        completion(nil, YES, NO, nil);
    }];
}

- (void)refreshAccessTokenWithCompletion:(void (^)(NSString * _Nullable accessToken,
                                                    NSError * _Nullable error))completion {
    NSString *refresh = [TVRecorderTokenStore refreshToken];
    if (!refresh.length) {
        completion(nil, [NSError errorWithDomain:TVRecorderOAuthErrorDomain
                                            code:TVRecorderOAuthErrorNetwork
                                        userInfo:@{NSLocalizedDescriptionKey: @"No refresh token"}]);
        return;
    }
    [self fetchDiscoveryWithCompletion:^(NSError *err) {
        if (err) {
            completion(nil, err);
            return;
        }
        NSArray *items = TVRecorderOAuthItemsWithOptionalSecret(@[
            [NSURLQueryItem queryItemWithName:@"grant_type" value:@"refresh_token"],
            [NSURLQueryItem queryItemWithName:@"client_id" value:kTVOAuthClientId],
            [NSURLQueryItem queryItemWithName:@"refresh_token" value:refresh],
        ]);
        [self postFormToURL:self.tokenEndpoint
                      items:items
                 completion:^(NSData *data, NSHTTPURLResponse *http, NSError *netErr) {
            if (netErr) {
                completion(nil, netErr);
                return;
            }
            NSError *je = nil;
            id obj = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&je] : nil;
            NSDictionary *dict = [obj isKindOfClass:[NSDictionary class]] ? (NSDictionary *)obj : nil;
            NSString *oauthErr = TVRecorderOAuthErrorStringFromDict(dict ?: @{});
            if ([oauthErr isEqualToString:@"invalid_grant"]) {
                DDLogWarn(@"[TVRecorderOAuth] refresh invalid_grant — clearing Keychain session");
                [TVRecorderTokenStore clear];
                id ed = dict[@"error_description"];
                NSString *desc = ([ed isKindOfClass:[NSString class]] && [(NSString *)ed length])
                    ? (NSString *)ed : @"invalid_grant";
                completion(nil, [NSError errorWithDomain:TVRecorderOAuthErrorDomain
                                                    code:TVRecorderOAuthErrorNetwork
                                                userInfo:@{NSLocalizedDescriptionKey: desc}]);
                return;
            }
            id atObj = dict[@"access_token"];
            NSString *at = [atObj isKindOfClass:[NSString class]] ? (NSString *)atObj : nil;
            if (!at.length) {
                NSString *body = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
                completion(nil, [NSError errorWithDomain:TVRecorderOAuthErrorDomain
                                                      code:TVRecorderOAuthErrorNetwork
                                                  userInfo:@{NSLocalizedDescriptionKey:
                                                                 [NSString stringWithFormat:@"Refresh failed %ld %@", (long)http.statusCode, body]}]);
                return;
            }
            id nrtObj = dict[@"refresh_token"];
            NSString *newRt = [nrtObj isKindOfClass:[NSString class]] && [(NSString *)nrtObj length]
                ? (NSString *)nrtObj : refresh;
            NSInteger exp = 3600;
            id ei = dict[@"expires_in"];
            if ([ei isKindOfClass:[NSNumber class]]) {
                exp = [(NSNumber *)ei integerValue];
            } else if ([ei isKindOfClass:[NSString class]]) {
                exp = [(NSString *)ei integerValue];
            }
            [TVRecorderTokenStore saveAccessToken:at refreshToken:newRt expiresIn:exp];
            DDLogInfo(@"[TVRecorderOAuth] refresh OK");
            completion(at, nil);
        }];
    }];
}

#pragma mark - Ensure pipeline (batched waiters)

- (void)flushEnsureWaitersWithToken:(NSString * _Nullable)token error:(NSError * _Nullable)error {
    NSArray<void (^)(NSString *, NSError *)> *batch = [self.ensureWaiters copy];
    [self.ensureWaiters removeAllObjects];
    self.ensurePipelineActive = NO;
    for (void (^b)(NSString *, NSError *) in batch) {
        b(token, error);
    }
}

- (void)runEnsureAfterDiscoveryFromPVC:(UIViewController *)pvc {
    if ([TVRecorderTokenStore hasUsableAccessToken]) {
        [self flushEnsureWaitersWithToken:[TVRecorderTokenStore accessToken] error:nil];
        return;
    }
    NSString *rt = [TVRecorderTokenStore refreshToken];
    if (rt.length) {
        __weak typeof(self) weak = self;
        [self refreshAccessTokenWithCompletion:^(NSString *at, NSError *err) {
            __strong typeof(weak) selfStrong = weak;
            if (!selfStrong) return;
            if (at.length) {
                [selfStrong flushEnsureWaitersWithToken:at error:nil];
            } else {
                DDLogInfo(@"[TVRecorderOAuth] refresh failed — starting device sign-in (%@)",
                          err.localizedDescription ?: @"unknown");
                [selfStrong presentDeviceSignInFrom:pvc];
            }
        }];
        return;
    }
    [self presentDeviceSignInFrom:pvc];
}

- (void)presentDeviceSignInFrom:(UIViewController *)pvc {
    if (!pvc) {
        [self flushEnsureWaitersWithToken:nil
                                    error:[NSError errorWithDomain:TVRecorderOAuthErrorDomain
                                                              code:TVRecorderOAuthErrorNetwork
                                                          userInfo:@{NSLocalizedDescriptionKey: @"No presenter"}]];
        return;
    }
    __weak typeof(self) weak = self;
    TVRecorderDeviceSignInViewController *vc =
        [[TVRecorderDeviceSignInViewController alloc] initWithCompletion:^(BOOL success, NSError * _Nullable err) {
            __strong typeof(weak) selfStrong = weak;
            if (!selfStrong) return;
            if (success && [TVRecorderTokenStore hasUsableAccessToken]) {
                [selfStrong flushEnsureWaitersWithToken:[TVRecorderTokenStore accessToken] error:nil];
            } else {
                NSError *out = err ?: [NSError errorWithDomain:TVRecorderOAuthErrorDomain
                                                            code:TVRecorderOAuthErrorCancelled
                                                        userInfo:@{NSLocalizedDescriptionKey: @"Sign-in cancelled"}];
                [selfStrong flushEnsureWaitersWithToken:nil error:out];
            }
        }];
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    [pvc presentViewController:vc animated:YES completion:nil];
}

- (void)ensureValidAccessTokenPresentingSignInFrom:(UIViewController *)pvc
                                        completion:(void (^)(NSString * _Nullable accessToken,
                                                              NSError * _Nullable error))completion {
    NSParameterAssert(completion);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.ensureWaiters addObject:[completion copy]];
        if (self.ensurePipelineActive) return;
        self.ensurePipelineActive = YES;

        if (kTVWebAppBearerToken.length) {
            [self flushEnsureWaitersWithToken:kTVWebAppBearerToken error:nil];
            return;
        }
        if (!kTVOAuthDiscoveryURL.length || !kTVOAuthClientId.length) {
            [self flushEnsureWaitersWithToken:nil error:nil];
            return;
        }
        if ([TVRecorderTokenStore hasUsableAccessToken]) {
            [self flushEnsureWaitersWithToken:[TVRecorderTokenStore accessToken] error:nil];
            return;
        }

        __weak typeof(self) weak = self;
        [self fetchDiscoveryWithCompletion:^(NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (err) {
                    [weak flushEnsureWaitersWithToken:nil error:err];
                    return;
                }
                [weak runEnsureAfterDiscoveryFromPVC:pvc];
            });
        }];
    });
}

@end
