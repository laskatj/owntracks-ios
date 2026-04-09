//
//  WebAppAuthHelper.m
//  OwnTracks
//
//  OAuth 2.0 / OIDC with PKCE via ASWebAuthenticationSession.
//

#import "WebAppAuthHelper.h"
#import <AuthenticationServices/AuthenticationServices.h>
#import <CommonCrypto/CommonCrypto.h>
#import <CocoaLumberjack/CocoaLumberjack.h>
#import <Security/Security.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

NSNotificationName const WebAppAuthCallbackURLNotification = @"WebAppAuthCallbackURL";

static NSString * const kRedirectURI = @"owntracks:///auth/callback";
static NSString * const kWellKnownPath = @"/.well-known/owntracks-app-auth";
static NSString * const kOpenIDConfigurationPath = @"/.well-known/openid-configuration";

static NSString * const kKeychainService = @"OwnTracksWebAppAuth";
static NSString * const kKeychainRefreshTokenKey = @"refresh_token";
static NSString * const kKeychainTokenEndpointKey = @"token_endpoint";
static NSString * const kKeychainClientIdKey = @"client_id";

@interface WebAppAuthHelper () <ASWebAuthenticationPresentationContextProviding>
@property (nonatomic, copy, nullable) WebAppAuthCompletion pendingCompletion;
@property (nonatomic, copy, nullable) NSString *pendingState;
@property (nonatomic, copy, nullable) NSString *pendingCodeVerifier;
@property (nonatomic, copy, nullable) NSString *pendingTokenEndpoint;
@property (nonatomic, copy, nullable) NSString *pendingClientId;
@property (nonatomic, copy, nullable) NSURL *pendingWebAppURL;
@property (nonatomic, strong, nullable) ASWebAuthenticationSession *currentSession;
// Per-account in-flight refresh coalescing: maps Keychain account key → array of pending completions.
// Only one token exchange is started per account at a time; all concurrent callers share the result.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *pendingRefreshCallbacks;
@end

@implementation WebAppAuthHelper

+ (instancetype)sharedInstance {
    static WebAppAuthHelper *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[WebAppAuthHelper alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _pendingRefreshCallbacks = [NSMutableDictionary dictionary];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleAuthCallbackURL:)
                                                     name:WebAppAuthCallbackURLNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Discovery

- (void)fetchDiscoveryFromOrigin:(NSURL *)webAppOrigin completion:(void (^)(NSDictionary * _Nullable config, NSError * _Nullable error))completion {
    NSURL *discoveryURL = [NSURL URLWithString:kWellKnownPath relativeToURL:webAppOrigin];
    if (!discoveryURL) {
        completion(nil, [NSError errorWithDomain:@"WebAppAuthHelper" code:-1 userInfo:@{ NSLocalizedDescriptionKey: @"Invalid discovery URL" }]);
        return;
    }
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:discoveryURL completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
            return;
        }
        if (![response isKindOfClass:[NSHTTPURLResponse class]] || [(NSHTTPURLResponse *)response statusCode] != 200) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSError errorWithDomain:@"WebAppAuthHelper" code:-2 userInfo:@{ NSLocalizedDescriptionKey: @"Discovery request failed or non-200" }]);
            });
            return;
        }
        NSError *jsonError;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
        if (![json isKindOfClass:[NSDictionary class]]) {
            NSString *bodyPreview = (data.length > 0)
                ? [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, MIN(data.length, 200))]
                                        encoding:NSUTF8StringEncoding]
                : @"(empty body)";
            DDLogWarn(@"[WebAppAuthHelper] owntracks-app-auth: JSON parse failed (status=%ld, body=%@)",
                      (long)[(NSHTTPURLResponse *)response statusCode],
                      bodyPreview ?: @"(non-UTF8 body)");
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, jsonError ?: [NSError errorWithDomain:@"WebAppAuthHelper" code:-3 userInfo:@{ NSLocalizedDescriptionKey: @"Invalid discovery JSON" }]);
            });
            return;
        }
        NSString *authEndpoint = json[@"authorization_endpoint"];
        NSString *tokenEndpoint = json[@"token_endpoint"];
        NSString *clientId = json[@"client_id"];
        if (![authEndpoint isKindOfClass:[NSString class]] || authEndpoint.length == 0 ||
            ![tokenEndpoint isKindOfClass:[NSString class]] || tokenEndpoint.length == 0 ||
            ![clientId isKindOfClass:[NSString class]] || clientId.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSError errorWithDomain:@"WebAppAuthHelper" code:-4 userInfo:@{ NSLocalizedDescriptionKey: @"Discovery missing authorization_endpoint, token_endpoint, or client_id" }]);
            });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion((NSDictionary *)json, nil); });
    }];
    [task resume];
}

- (void)fetchOIDCDiscoveryFromURL:(NSURL *)oidcDiscoveryURL clientId:(NSString *)clientId completion:(void (^)(NSDictionary * _Nullable config, NSError * _Nullable error))completion {
    NSURL *configURL = oidcDiscoveryURL;
    if (![oidcDiscoveryURL.lastPathComponent isEqualToString:@"openid-configuration"]) {
        configURL = [NSURL URLWithString:kOpenIDConfigurationPath relativeToURL:oidcDiscoveryURL];
    }
    if (!configURL) {
        completion(nil, [NSError errorWithDomain:@"WebAppAuthHelper" code:-1 userInfo:@{ NSLocalizedDescriptionKey: @"Invalid OIDC discovery URL" }]);
        return;
    }
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:configURL completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
            return;
        }
        if (![response isKindOfClass:[NSHTTPURLResponse class]] || [(NSHTTPURLResponse *)response statusCode] != 200) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSError errorWithDomain:@"WebAppAuthHelper" code:-2 userInfo:@{ NSLocalizedDescriptionKey: @"OIDC discovery request failed or non-200" }]);
            });
            return;
        }
        NSError *jsonError;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
        if (![json isKindOfClass:[NSDictionary class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, jsonError ?: [NSError errorWithDomain:@"WebAppAuthHelper" code:-3 userInfo:@{ NSLocalizedDescriptionKey: @"Invalid OIDC discovery JSON" }]);
            });
            return;
        }
        NSString *authEndpoint = json[@"authorization_endpoint"];
        NSString *tokenEndpoint = json[@"token_endpoint"];
        if (![authEndpoint isKindOfClass:[NSString class]] || authEndpoint.length == 0 ||
            ![tokenEndpoint isKindOfClass:[NSString class]] || tokenEndpoint.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSError errorWithDomain:@"WebAppAuthHelper" code:-4 userInfo:@{ NSLocalizedDescriptionKey: @"OIDC discovery missing authorization_endpoint or token_endpoint" }]);
            });
            return;
        }
        NSDictionary *config = @{
            @"authorization_endpoint": authEndpoint,
            @"token_endpoint": tokenEndpoint,
            @"client_id": clientId,
            @"scope": @"openid profile email offline_access"
        };
        dispatch_async(dispatch_get_main_queue(), ^{ completion(config, nil); });
    }];
    [task resume];
}

- (void)fetchOIDCAuthorizationEndpointFromDiscoveryURL:(NSURL *)discoveryURL
                                             completion:(void (^)(NSURL * _Nullable authEndpointURL, NSError * _Nullable error))completion {
    NSURL *configURL = discoveryURL;
    if (![discoveryURL.lastPathComponent isEqualToString:@"openid-configuration"]) {
        configURL = [NSURL URLWithString:kOpenIDConfigurationPath relativeToURL:discoveryURL];
    }
    if (!configURL) {
        completion(nil, [NSError errorWithDomain:@"WebAppAuthHelper" code:-1 userInfo:@{ NSLocalizedDescriptionKey: @"Invalid OIDC discovery URL" }]);
        return;
    }
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:configURL completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
            return;
        }
        if (![response isKindOfClass:[NSHTTPURLResponse class]] || [(NSHTTPURLResponse *)response statusCode] != 200) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSError errorWithDomain:@"WebAppAuthHelper" code:-2 userInfo:@{ NSLocalizedDescriptionKey: @"OIDC discovery request failed or non-200" }]);
            });
            return;
        }
        NSError *jsonError;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
        if (![json isKindOfClass:[NSDictionary class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, jsonError ?: [NSError errorWithDomain:@"WebAppAuthHelper" code:-3 userInfo:@{ NSLocalizedDescriptionKey: @"Invalid OIDC discovery JSON" }]);
            });
            return;
        }
        NSString *authEndpointStr = json[@"authorization_endpoint"];
        if (![authEndpointStr isKindOfClass:[NSString class]] || authEndpointStr.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSError errorWithDomain:@"WebAppAuthHelper" code:-4 userInfo:@{ NSLocalizedDescriptionKey: @"OIDC discovery missing authorization_endpoint" }]);
            });
            return;
        }
        NSURL *authURL = [NSURL URLWithString:authEndpointStr];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(authURL, nil); });
    }];
    [task resume];
}

#pragma mark - PKCE

- (NSString *)generateCodeVerifier {
    NSMutableData *data = [NSMutableData dataWithLength:32];
    int result = SecRandomCopyBytes(kSecRandomDefault, 32, data.mutableBytes);
    if (result != errSecSuccess) {
        arc4random_buf(data.mutableBytes, 32);
    }
    return [self base64URLEncode:data];
}

- (NSString *)codeChallengeForVerifier:(NSString *)verifier {
    NSData *input = [verifier dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(input.bytes, (CC_LONG)input.length, digest);
    NSData *hash = [NSData dataWithBytes:digest length:CC_SHA256_DIGEST_LENGTH];
    return [self base64URLEncode:hash];
}

- (NSString *)base64URLEncode:(NSData *)data {
    NSString *base64 = [data base64EncodedStringWithOptions:0];
    base64 = [base64 stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    base64 = [base64 stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    base64 = [base64 stringByReplacingOccurrencesOfString:@"=" withString:@""];
    return base64;
}

- (NSString *)generateState {
    NSMutableData *data = [NSMutableData dataWithLength:16];
    int result = SecRandomCopyBytes(kSecRandomDefault, 16, data.mutableBytes);
    if (result != errSecSuccess) {
        arc4random_buf(data.mutableBytes, 16);
    }
    return [self base64URLEncode:data];
}

#pragma mark - Auth session

- (void)startAuthWithWebAppOrigin:(NSURL *)webAppOrigin
                 oidcDiscoveryURL:(NSURL *)oidcDiscoveryURL
                         clientId:(NSString *)clientId
          presentingViewController:(UIViewController *)presentingViewController
                       completion:(WebAppAuthCompletion)completion {
    self.pendingWebAppURL = webAppOrigin;
    void (^runWithConfig)(NSDictionary *, NSError *) = ^(NSDictionary *config, NSError *err) {
        if (err || !config) {
            DDLogWarn(@"[WebAppAuthHelper] Discovery failed: %@", err.localizedDescription);
            completion(nil, err);
            return;
        }
        [self runAuthWithConfig:config completion:completion];
    };
    if (oidcDiscoveryURL && oidcDiscoveryURL.absoluteString.length > 0 && clientId.length > 0) {
        [self fetchOIDCDiscoveryFromURL:oidcDiscoveryURL clientId:clientId completion:runWithConfig];
    } else {
        [self fetchDiscoveryFromOrigin:webAppOrigin completion:runWithConfig];
    }
}

- (void)runAuthWithConfig:(NSDictionary *)config completion:(WebAppAuthCompletion)completion {
    NSString *authEndpoint = config[@"authorization_endpoint"];
    NSString *tokenEndpoint = config[@"token_endpoint"];
    NSString *clientId = config[@"client_id"];
    NSString *scope = [config[@"scope"] isKindOfClass:[NSString class]] ? config[@"scope"] : @"openid profile email";

    NSString *codeVerifier = [self generateCodeVerifier];
    NSString *codeChallenge = [self codeChallengeForVerifier:codeVerifier];
    NSString *state = [self generateState];

    self.pendingCodeVerifier = codeVerifier;
    self.pendingState = state;
    self.pendingTokenEndpoint = tokenEndpoint;
    self.pendingClientId = clientId;
    self.pendingCompletion = completion;

    NSURLComponents *components = [NSURLComponents componentsWithString:authEndpoint];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray arrayWithArray:components.queryItems ?: @[]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"response_type" value:@"code"]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"client_id" value:clientId]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"redirect_uri" value:kRedirectURI]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"scope" value:scope]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"code_challenge" value:codeChallenge]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"code_challenge_method" value:@"S256"]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"state" value:state]];
    components.queryItems = items;
    NSURL *authURL = components.URL;
    if (!authURL) {
        [self finishWithError:[NSError errorWithDomain:@"WebAppAuthHelper" code:-5 userInfo:@{ NSLocalizedDescriptionKey: @"Invalid authorization URL" }]];
        return;
    }

    __weak typeof(self) wself = self;
    ASWebAuthenticationSession *session = [[ASWebAuthenticationSession alloc] initWithURL:authURL
                                                                          callbackURLScheme:@"owntracks"
                                                                          completionHandler:^(NSURL * _Nullable callbackURL, NSError * _Nullable error) {
        __strong typeof(wself) sself = wself;
        if (!sself) return;
        if (error) {
            if (error.domain == ASWebAuthenticationSessionErrorDomain && error.code == ASWebAuthenticationSessionErrorCodeCanceledLogin) {
                DDLogInfo(@"[WebAppAuthHelper] User canceled");
                [sself finishWithError:nil];
            } else {
                [sself finishWithError:error];
            }
            sself.currentSession = nil;
            return;
        }
        if (callbackURL) {
            [sself handleCallbackURL:callbackURL tokenEndpoint:tokenEndpoint clientId:clientId];
        }
        sself.currentSession = nil;
    }];
    session.presentationContextProvider = self;
    self.currentSession = session;
    if (![session start]) {
        [self finishWithError:[NSError errorWithDomain:@"WebAppAuthHelper" code:-6 userInfo:@{ NSLocalizedDescriptionKey: @"Failed to start authentication session" }]];
        self.currentSession = nil;
    }
}

- (void)handleAuthCallbackURL:(NSNotification *)notification {
    NSURL *url = notification.userInfo[@"url"];
    if (![url isKindOfClass:[NSURL class]] || !self.pendingState) return;
    // Avoid double-handling: session completion and app delegate notification can both fire.
    [self handleCallbackURL:url tokenEndpoint:nil clientId:nil];
}

- (void)handleCallbackURL:(NSURL *)url tokenEndpoint:(NSString *)tokenEndpoint clientId:(NSString *)clientId {
    if (!self.pendingState) return;  // Already consumed (e.g. by notification or session)
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in components.queryItems) {
        if (item.value) params[item.name] = item.value;
    }
    NSString *code = params[@"code"];
    NSString *state = params[@"state"];
    NSString *errorParam = params[@"error"];

    if (errorParam) {
        NSString *desc = params[@"error_description"] ?: errorParam;
        [self finishWithError:[NSError errorWithDomain:@"WebAppAuthHelper" code:-7 userInfo:@{ NSLocalizedDescriptionKey: desc }]];
        return;
    }
    if (![state isEqualToString:self.pendingState]) {
        [self finishWithError:[NSError errorWithDomain:@"WebAppAuthHelper" code:-8 userInfo:@{ NSLocalizedDescriptionKey: @"State mismatch" }]];
        return;
    }
    // Clear immediately so a second delivery (notification + session) does not process again.
    self.pendingState = nil;
    if (![code isKindOfClass:[NSString class]] || code.length == 0) {
        [self finishWithError:[NSError errorWithDomain:@"WebAppAuthHelper" code:-9 userInfo:@{ NSLocalizedDescriptionKey: @"Missing code" }]];
        return;
    }

    NSString *endpoint = tokenEndpoint.length > 0 ? tokenEndpoint : self.pendingTokenEndpoint;
    NSString *client = clientId.length > 0 ? clientId : self.pendingClientId;
    if (endpoint.length > 0 && client.length > 0) {
        [self exchangeCode:code forTokenWithEndpoint:endpoint clientId:client];
    } else {
        DDLogWarn(@"[WebAppAuthHelper] Callback URL received without token endpoint; cannot exchange");
        [self finishWithError:[NSError errorWithDomain:@"WebAppAuthHelper" code:-10 userInfo:@{ NSLocalizedDescriptionKey: @"Cannot exchange code without discovery" }]];
    }
}

- (void)exchangeCode:(NSString *)code forTokenWithEndpoint:(NSString *)tokenEndpoint clientId:(NSString *)clientId {
    NSString *verifier = self.pendingCodeVerifier;
    if (!verifier) {
        [self finishWithError:[NSError errorWithDomain:@"WebAppAuthHelper" code:-11 userInfo:@{ NSLocalizedDescriptionKey: @"Missing code verifier" }]];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:tokenEndpoint]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    NSString *body = [NSString stringWithFormat:@"grant_type=authorization_code&code=%@&redirect_uri=%@&client_id=%@&code_verifier=%@",
                      [self formEncode:code],
                      [self formEncode:kRedirectURI],
                      [self formEncode:clientId],
                      [self formEncode:verifier]];
    request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    __weak typeof(self) wself = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        __strong typeof(wself) sself = wself;
        if (!sself) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                [sself finishWithError:error];
                return;
            }
            NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
            if (status != 200) {
                [sself finishWithError:[NSError errorWithDomain:@"WebAppAuthHelper" code:status userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Token endpoint returned %ld", (long)status] }]];
                return;
            }
            NSString *accessToken = nil;
            NSString *refreshToken = nil;
            NSError *jsonError = nil;
            id json = data && data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
            if ([json isKindOfClass:[NSDictionary class]]) {
                accessToken = json[@"access_token"];
                id rt = json[@"refresh_token"];
                if ([rt isKindOfClass:[NSString class]] && [(NSString *)rt length] > 0) {
                    refreshToken = rt;
                }
            }
            if (![accessToken isKindOfClass:[NSString class]] || accessToken.length == 0) {
                NSString *bodyStr = data.length > 0 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
                if (bodyStr.length > 0) {
                    NSURLComponents *comp = [NSURLComponents new];
                    comp.query = bodyStr;
                    for (NSURLQueryItem *item in comp.queryItems) {
                        if ([item.name isEqualToString:@"access_token"] && item.value.length > 0) {
                            accessToken = item.value;
                        } else if ([item.name isEqualToString:@"refresh_token"] && item.value.length > 0) {
                            refreshToken = item.value;
                        }
                    }
                }
            }
            if (![accessToken isKindOfClass:[NSString class]] || accessToken.length == 0) {
                [sself finishWithError:jsonError ?: [NSError errorWithDomain:@"WebAppAuthHelper" code:-12 userInfo:@{ NSLocalizedDescriptionKey: @"No access_token in response" }]];
                return;
            }
            DDLogInfo(@"[WebAppAuthHelper] Token received (refresh_token=%@)", refreshToken ? @"yes" : @"no");
            if (refreshToken && sself.pendingWebAppURL && sself.pendingTokenEndpoint && sself.pendingClientId) {
                [sself storeRefreshToken:refreshToken tokenEndpoint:sself.pendingTokenEndpoint clientId:sself.pendingClientId forWebAppURL:sself.pendingWebAppURL];
            }
            [sself finishWithAccessToken:accessToken];
        });
    }];
    [task resume];
}

- (NSString *)formEncode:(NSString *)string {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    return [string stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

- (void)finishWithAccessToken:(NSString *)accessToken {
    WebAppAuthCompletion comp = self.pendingCompletion;
    self.pendingCompletion = nil;
    self.pendingState = nil;
    self.pendingCodeVerifier = nil;
    self.pendingTokenEndpoint = nil;
    self.pendingClientId = nil;
    self.pendingWebAppURL = nil;
    if (comp) comp(accessToken, nil);
}

- (void)finishWithError:(NSError *)error {
    WebAppAuthCompletion comp = self.pendingCompletion;
    self.pendingCompletion = nil;
    self.pendingState = nil;
    self.pendingCodeVerifier = nil;
    self.pendingTokenEndpoint = nil;
    self.pendingClientId = nil;
    self.pendingWebAppURL = nil;
    if (comp) comp(nil, error);
}

- (void)startPassthroughSessionWithURL:(NSURL *)idpURL
                             completion:(void (^)(NSURL * _Nullable callbackURL, NSError * _Nullable error))completion {
    __weak typeof(self) wself = self;
    ASWebAuthenticationSession *session = [[ASWebAuthenticationSession alloc]
        initWithURL:idpURL
        callbackURLScheme:@"owntracks"
        completionHandler:^(NSURL *callbackURL, NSError *error) {
            __strong typeof(wself) sself = wself;
            if (!sself) return;
            sself.currentSession = nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error) {
                    if (error.domain == ASWebAuthenticationSessionErrorDomain &&
                        error.code == ASWebAuthenticationSessionErrorCodeCanceledLogin) {
                        completion(nil, nil); // user cancelled — no error alert needed
                    } else {
                        completion(nil, error);
                    }
                } else {
                    completion(callbackURL, nil);
                }
            });
        }];
    session.presentationContextProvider = self;
    self.currentSession = session;
    if (![session start]) {
        self.currentSession = nil;
        completion(nil, [NSError errorWithDomain:@"WebAppAuthHelper" code:-6
                        userInfo:@{NSLocalizedDescriptionKey: @"Failed to start authentication session"}]);
    }
}

#pragma mark - ASWebAuthenticationPresentationContextProviding

#pragma mark - Keychain token storage

/// Returns a stable origin key (scheme+host+port) for account names.
- (NSString *)originKeyForURL:(NSURL *)url {
    NSURLComponents *c = [NSURLComponents new];
    c.scheme = url.scheme;
    c.host = url.host;
    c.port = url.port;
    return c.URL.absoluteString ?: url.absoluteString;
}

/// Normalized path key so path-scoped apps on the same host don't overwrite each other.
- (NSString *)pathKeyForURL:(NSURL *)url {
    NSString *path = url.path ?: @"/";
    if (path.length == 0) path = @"/";
    if (path.length > 1 && [path hasSuffix:@"/"]) {
        path = [path substringToIndex:path.length - 1];
    }
    return path;
}

/// Context-aware Keychain account key: origin + path + client id.
- (NSString *)keychainAccountForWebAppURL:(NSURL *)webAppURL clientId:(NSString *)clientId {
    NSString *originKey = [self originKeyForURL:webAppURL];
    NSString *pathKey = [self pathKeyForURL:webAppURL];
    NSString *cid = clientId.length > 0 ? clientId : @"_";
    return [NSString stringWithFormat:@"%@|%@|%@", originKey, pathKey, cid];
}

- (NSDictionary *)tokenQueryForAccount:(NSString *)account {
    return @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: account
    };
}

- (void)deleteTokenForAccount:(NSString *)account {
    NSDictionary *query = [self tokenQueryForAccount:account];
    SecItemDelete((__bridge CFDictionaryRef)query);
}

- (nullable NSDictionary *)loadTokenDataForAccount:(NSString *)account {
    NSMutableDictionary *query = [[self tokenQueryForAccount:account] mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = nil;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || !result) return nil;
    NSData *data = (__bridge_transfer NSData *)result;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:[NSDictionary class]] ? json : nil;
}

- (NSArray<NSString *> *)tokenLookupAccountsForWebAppURL:(NSURL *)webAppURL clientId:(NSString *)clientId {
    NSMutableArray<NSString *> *accounts = [NSMutableArray array];
    NSString *exact = [self keychainAccountForWebAppURL:webAppURL clientId:clientId];
    [accounts addObject:exact];
    if (clientId.length > 0) {
        [accounts addObject:[self keychainAccountForWebAppURL:webAppURL clientId:nil]];
    }
    // Legacy fallback from pre-context-aware storage.
    [accounts addObject:[self originKeyForURL:webAppURL]];
    return accounts;
}

/// Stores the refresh token + metadata in Keychain keyed by web app URL + client context.
- (void)storeRefreshToken:(NSString *)refreshToken
            tokenEndpoint:(NSString *)tokenEndpoint
                 clientId:(NSString *)clientId
            forWebAppURL:(NSURL *)webAppURL {
    NSString *account = [self keychainAccountForWebAppURL:webAppURL clientId:clientId];
    NSDictionary *payload = @{
        kKeychainRefreshTokenKey: refreshToken,
        kKeychainTokenEndpointKey: tokenEndpoint,
        kKeychainClientIdKey: clientId
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!data) return;

    [self deleteTokenForAccount:account];
    // Best-effort cleanup of legacy account so old stale token won't be used.
    [self deleteTokenForAccount:[self originKeyForURL:webAppURL]];

    NSMutableDictionary *addQuery = [[self tokenQueryForAccount:account] mutableCopy];
    addQuery[(__bridge id)kSecValueData] = data;
    addQuery[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)addQuery, nil);
    if (status == errSecSuccess) {
        DDLogInfo(@"[WebAppAuthHelper] Refresh token stored in Keychain for origin=%@", account);
    } else {
        DDLogWarn(@"[WebAppAuthHelper] Failed to store refresh token: %d", (int)status);
    }
}

- (nullable NSDictionary *)loadTokenDataForWebAppURL:(NSURL *)webAppURL clientId:(NSString *)clientId matchedAccount:(NSString * __autoreleasing *)matchedAccount {
    for (NSString *account in [self tokenLookupAccountsForWebAppURL:webAppURL clientId:clientId]) {
        NSDictionary *tokenData = [self loadTokenDataForAccount:account];
        if (tokenData) {
            if (matchedAccount) *matchedAccount = account;
            return tokenData;
        }
    }
    return nil;
}

#pragma mark - Silent refresh

- (void)attemptSilentRefreshForOrigin:(NSURL *)webAppOrigin completion:(WebAppAuthCompletion)completion {
    [self attemptSilentRefreshForWebAppURL:webAppOrigin clientId:nil completion:completion];
}

- (void)attemptSilentRefreshForWebAppURL:(NSURL *)webAppURL clientId:(NSString *)clientId completion:(WebAppAuthCompletion)completion {
    NSString *matchedAccount = nil;
    NSDictionary *tokenData = [self loadTokenDataForWebAppURL:webAppURL clientId:clientId matchedAccount:&matchedAccount];
    if (!tokenData) {
        DDLogInfo(@"[WebAppAuthHelper] REAUTH REASON: no stored refresh token found (checked account=%@) → will require full re-auth", [self keychainAccountForWebAppURL:webAppURL clientId:clientId]);
        completion(nil, nil);
        return;
    }
    [self performRefreshWithTokenData:tokenData forWebAppURL:webAppURL matchedAccount:matchedAccount completion:completion];
}

- (void)attemptSilentRefreshForWebAppURL:(NSURL *)webAppURL clientId:(NSString *)clientId tokenPairCompletion:(WebAppAuthTokenPairCompletion)completion {
    __weak typeof(self) wself = self;
    [self attemptSilentRefreshForWebAppURL:webAppURL clientId:clientId completion:^(NSString *accessToken, NSError *error) {
        __strong typeof(wself) sself = wself;
        if (!accessToken) { completion(nil, nil, error); return; }
        // After a successful refresh, the rotated refresh token is already stored in Keychain.
        // Read it back so we can pass it to the web app for independent renewal.
        NSDictionary *tokenData = [sself loadTokenDataForWebAppURL:webAppURL clientId:clientId matchedAccount:nil];
        NSString *refreshToken = tokenData[kKeychainRefreshTokenKey];
        completion(accessToken, refreshToken, nil);
    }];
}

- (void)performRefreshWithTokenData:(NSDictionary *)tokenData forWebAppURL:(NSURL *)webAppURL matchedAccount:(NSString *)matchedAccount completion:(WebAppAuthCompletion)completion {
    NSString *refreshToken = tokenData[kKeychainRefreshTokenKey];
    NSString *tokenEndpoint = tokenData[kKeychainTokenEndpointKey];
    NSString *clientId = tokenData[kKeychainClientIdKey];
    if (!refreshToken.length || !tokenEndpoint.length || !clientId.length) {
        DDLogWarn(@"[WebAppAuthHelper] REAUTH REASON: stored token data incomplete — refresh_token=%@ token_endpoint=%@ client_id=%@ → forcing full re-auth",
                  refreshToken.length ? @"present" : @"MISSING",
                  tokenEndpoint.length ? @"present" : @"MISSING",
                  clientId.length ? @"present" : @"MISSING");
        completion(nil, nil);
        return;
    }

    // Coalesce concurrent refresh requests for the same Keychain account.
    // Authentik uses refresh-token rotation: each use invalidates the token. If two callers
    // simultaneously POST the same token, one will get a 400 and delete the Keychain entry,
    // causing spurious "No stored refresh token" failures on the next launch.
    // Solution: only one in-flight exchange per account; latecomers queue their completion
    // and receive the same result when the single request finishes.
    NSString *accountKey = matchedAccount.length > 0 ? matchedAccount : [self originKeyForURL:webAppURL];
    NSMutableArray *pending = self.pendingRefreshCallbacks[accountKey];
    if (pending) {
        DDLogInfo(@"[WebAppAuthHelper] Refresh already in flight for %@ — coalescing caller", accountKey);
        [pending addObject:[completion copy]];
        return;
    }
    self.pendingRefreshCallbacks[accountKey] = [NSMutableArray arrayWithObject:[completion copy]];

    DDLogInfo(@"[WebAppAuthHelper] Attempting silent refresh for account=%@", matchedAccount);
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:tokenEndpoint]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    NSString *body = [NSString stringWithFormat:@"grant_type=refresh_token&refresh_token=%@&client_id=%@",
                      [self formEncode:refreshToken], [self formEncode:clientId]];
    request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    __weak typeof(self) wself = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(wself) sself = wself;
            if (!sself) { completion(nil, nil); return; }

            // Collect all coalesced completions before any early-return path.
            NSArray *allCompletions = [sself.pendingRefreshCallbacks[accountKey] copy];
            [sself.pendingRefreshCallbacks removeObjectForKey:accountKey];
            void (^fireAll)(NSString *, NSError *) = ^(NSString *tok, NSError *err) {
                for (WebAppAuthCompletion cb in allCompletions) { cb(tok, err); }
            };

            if (error) {
                DDLogWarn(@"[WebAppAuthHelper] REAUTH REASON: silent refresh network error → %@", error.localizedDescription);
                fireAll(nil, nil);
                return;
            }
            NSInteger statusCode = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
            if (statusCode == 401 || statusCode == 400) {
                // Only wipe the Keychain entry when the app is foreground-active.
                // A background wakeup hitting a 401 (expired token, server restart, clock skew)
                // would otherwise silently erase the credential with no chance for the user
                // to re-auth in that same session, leaving the app in an unrecoverable state
                // until a manual foreground sign-in. In background, preserve the entry so the
                // next foreground launch can present the sign-in prompt instead.
                BOOL isForeground = ([UIApplication sharedApplication].applicationState == UIApplicationStateActive);
                DDLogInfo(@"[WebAppAuthHelper] REAUTH REASON: silent refresh rejected (%ld) — refresh token expired or revoked%@",
                          (long)statusCode,
                          isForeground ? @", clearing Keychain entry" : @" (background — preserving Keychain entry for foreground re-auth)");
                if (isForeground) {
                    if (matchedAccount.length > 0) {
                        [sself deleteTokenForAccount:matchedAccount];
                    } else {
                        [sself clearStoredTokensForOrigin:webAppURL];
                    }
                }
                fireAll(nil, nil);
                return;
            }
            if (statusCode != 200) {
                DDLogWarn(@"[WebAppAuthHelper] REAUTH REASON: silent refresh unexpected status %ld — will not clear token (may be transient), but re-auth will be needed", (long)statusCode);
                fireAll(nil, nil);
                return;
            }
            id json = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSString *newAccessToken = [json isKindOfClass:[NSDictionary class]] ? json[@"access_token"] : nil;
            NSString *newRefreshToken = [json isKindOfClass:[NSDictionary class]] ? json[@"refresh_token"] : nil;
            if (!newAccessToken.length) {
                DDLogWarn(@"[WebAppAuthHelper] REAUTH REASON: silent refresh response missing access_token (status=%ld)", (long)statusCode);
                fireAll(nil, nil);
                return;
            }
            DDLogInfo(@"[WebAppAuthHelper] Silent refresh successful");
            // Update stored refresh token (servers often rotate them).
            NSString *storedRT = newRefreshToken.length > 0 ? newRefreshToken : tokenData[kKeychainRefreshTokenKey];
            [sself storeRefreshToken:storedRT tokenEndpoint:tokenEndpoint clientId:clientId forWebAppURL:webAppURL];
            fireAll(newAccessToken, nil);
        });
    }] resume];
}

- (void)clearStoredTokensForOrigin:(NSURL *)webAppOrigin {
    [self deleteTokenForAccount:[self originKeyForURL:webAppOrigin]];
    [self deleteTokenForAccount:[self keychainAccountForWebAppURL:webAppOrigin clientId:nil]];
    DDLogInfo(@"[WebAppAuthHelper] Cleared stored tokens for %@", [self originKeyForURL:webAppOrigin]);
}

#pragma mark - ASWebAuthenticationPresentationContextProviding

- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
        }
    }
    UIWindowScene *scene = (UIWindowScene *)[UIApplication sharedApplication].connectedScenes.anyObject;
    return scene.windows.firstObject;
}

@end
