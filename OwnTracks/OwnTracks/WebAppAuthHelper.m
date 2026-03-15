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

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

NSNotificationName const WebAppAuthCallbackURLNotification = @"WebAppAuthCallbackURL";

static NSString * const kRedirectURI = @"owntracks:///auth/callback";
static NSString * const kWellKnownPath = @"/.well-known/owntracks-app-auth";
static NSString * const kOpenIDConfigurationPath = @"/.well-known/openid-configuration";

@interface WebAppAuthHelper () <ASWebAuthenticationPresentationContextProviding>
@property (nonatomic, copy, nullable) WebAppAuthCompletion pendingCompletion;
@property (nonatomic, copy, nullable) NSString *pendingState;
@property (nonatomic, copy, nullable) NSString *pendingCodeVerifier;
@property (nonatomic, copy, nullable) NSString *pendingTokenEndpoint;
@property (nonatomic, copy, nullable) NSString *pendingClientId;
@property (nonatomic, strong, nullable) ASWebAuthenticationSession *currentSession;
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
            @"scope": @"openid profile email"
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
    void (^runWithConfig)(NSDictionary *, NSError *) = ^(NSDictionary *config, NSError *err) {
        if (err || !config) {
            DDLogWarn(@"[DEBUG-2514a7] Discovery failed: %@", err.localizedDescription);
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
                DDLogInfo(@"[DEBUG-2514a7] User canceled");
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
        DDLogWarn(@"[DEBUG-2514a7] Callback URL received without token endpoint; cannot exchange");
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
            NSError *jsonError = nil;
            id json = data && data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
            if ([json isKindOfClass:[NSDictionary class]]) {
                accessToken = json[@"access_token"];
            }
            if (![accessToken isKindOfClass:[NSString class]] || accessToken.length == 0) {
                NSString *body = data.length > 0 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
                if (body.length > 0) {
                    NSURLComponents *comp = [NSURLComponents new];
                    comp.query = body;
                    for (NSURLQueryItem *item in comp.queryItems) {
                        if ([item.name isEqualToString:@"access_token"] && item.value.length > 0) {
                            accessToken = item.value;
                            break;
                        }
                    }
                }
            }
            if (![accessToken isKindOfClass:[NSString class]] || accessToken.length == 0) {
                [sself finishWithError:jsonError ?: [NSError errorWithDomain:@"WebAppAuthHelper" code:-12 userInfo:@{ NSLocalizedDescriptionKey: @"No access_token in response" }]];
                return;
            }
            DDLogInfo(@"[DEBUG-2514a7] Token received, handing to web app");
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
    if (comp) comp(accessToken, nil);
}

- (void)finishWithError:(NSError *)error {
    WebAppAuthCompletion comp = self.pendingCompletion;
    self.pendingCompletion = nil;
    self.pendingState = nil;
    self.pendingCodeVerifier = nil;
    self.pendingTokenEndpoint = nil;
    self.pendingClientId = nil;
    if (comp) comp(nil, error);
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
    return [UIApplication sharedApplication].windows.firstObject;
}

@end
