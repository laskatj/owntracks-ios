//
//  OIDCManager.m
//  OwnTracks
//
//  Manages OIDC authentication via AppAuth-iOS.
//  Persists OIDAuthState to Keychain so tokens survive app restarts.
//

#import "OIDCManager.h"
#import "Settings.h"
#import "CoreData.h"
#import <AppAuth/AppAuth.h>
#import <CocoaLumberjack/CocoaLumberjack.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

// Keychain storage key for the serialized OIDAuthState
static NSString * const kOIDCKeychainService = @"org.owntracks.oidc";
static NSString * const kOIDCKeychainAccount = @"authstate";

@interface OIDCManager ()
@property (nonatomic, strong, nullable) OIDAuthState *authState;
@end

@implementation OIDCManager

+ (instancetype)sharedInstance {
    static OIDCManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[OIDCManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self loadAuthStateFromKeychain];
    }
    return self;
}

#pragma mark - Public API

- (BOOL)hasStoredSession {
    return self.authState != nil;
}

- (void)freshAccessToken:(void(^)(NSString * _Nullable accessToken, NSError * _Nullable error))completion {
    if (!self.authState) {
        NSError *error = [NSError errorWithDomain:@"OIDCManager"
                                             code:1
                                         userInfo:@{NSLocalizedDescriptionKey: @"No auth session. Please sign in."}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
        return;
    }

    [self.authState performActionWithFreshTokens:^(NSString *accessToken,
                                                    NSString *idToken,
                                                    NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                DDLogWarn(@"[OIDCManager] Token refresh failed: %@", error.localizedDescription);
                // Auth state is now invalid — clear it so the caller can re-authenticate
                [self clearSession];
                completion(nil, error);
                return;
            }
            DDLogInfo(@"[OIDCManager] Fresh access token obtained.");
            completion(accessToken, nil);
        });
    }];
}

- (void)startAuthFromViewController:(UIViewController *)viewController
                         completion:(void(^)(NSString * _Nullable accessToken, NSError * _Nullable error))completion {
    NSManagedObjectContext *moc = CoreData.sharedInstance.mainMOC;
    NSString *issuerString = [Settings stringForKey:@"oidc_issuer_preference" inMOC:moc];
    NSString *clientId = [Settings stringForKey:@"oidc_clientid_preference" inMOC:moc];
    NSString *redirectScheme = [Settings stringForKey:@"oidc_redirect_scheme_preference" inMOC:moc];

    if (issuerString.length == 0 || clientId.length == 0) {
        NSError *error = [NSError errorWithDomain:@"OIDCManager"
                                             code:2
                                         userInfo:@{NSLocalizedDescriptionKey: @"OIDC issuer URL and client ID must be configured in Settings."}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
        return;
    }

    if (redirectScheme.length == 0) {
        redirectScheme = @"owntracks";
    }

    NSURL *issuerURL = [NSURL URLWithString:issuerString];
    if (!issuerURL) {
        NSError *error = [NSError errorWithDomain:@"OIDCManager"
                                             code:3
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid OIDC issuer URL."}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
        return;
    }

    NSString *redirectURIString = [NSString stringWithFormat:@"%@://auth/callback", redirectScheme];
    NSURL *redirectURI = [NSURL URLWithString:redirectURIString];

    DDLogInfo(@"[OIDCManager] Discovering OIDC configuration from %@", issuerString);

    [OIDAuthorizationService discoverServiceConfigurationForIssuer:issuerURL
                                                        completion:^(OIDServiceConfiguration *config, NSError *error) {
        if (error || !config) {
            DDLogError(@"[OIDCManager] OIDC discovery failed: %@", error.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
            return;
        }

        DDLogInfo(@"[OIDCManager] OIDC config discovered. Starting auth request.");

        OIDAuthorizationRequest *request =
            [[OIDAuthorizationRequest alloc] initWithConfiguration:config
                                                          clientId:clientId
                                                            scopes:@[OIDScopeOpenID, OIDScopeProfile, OIDScopeEmail, @"offline_access"]
                                                       redirectURL:redirectURI
                                                      responseType:OIDResponseTypeCode
                                              additionalParameters:nil];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.currentAuthorizationFlow =
                [OIDAuthState authStateByPresentingAuthorizationRequest:request
                                                     presentingViewController:viewController
                                                                    callback:^(OIDAuthState *authState, NSError *error) {
                if (error || !authState) {
                    DDLogError(@"[OIDCManager] Auth flow failed: %@", error.localizedDescription);
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
                    return;
                }

                DDLogInfo(@"[OIDCManager] Auth flow succeeded. Storing auth state.");
                self.authState = authState;
                [self saveAuthStateToKeychain];

                NSString *accessToken = authState.lastTokenResponse.accessToken;
                dispatch_async(dispatch_get_main_queue(), ^{ completion(accessToken, nil); });
            }];
        });
    }];
}

- (void)clearSession {
    DDLogInfo(@"[OIDCManager] Clearing OIDC session.");
    self.authState = nil;
    [self deleteAuthStateFromKeychain];
}

#pragma mark - Keychain Persistence

- (void)saveAuthStateToKeychain {
    if (!self.authState) return;
    NSData *data;
    if (@available(iOS 11.0, *)) {
        data = [NSKeyedArchiver archivedDataWithRootObject:self.authState
                                    requiringSecureCoding:NO
                                                    error:nil];
    } else {
        data = [NSKeyedArchiver archivedDataWithRootObject:self.authState];
    }
    if (!data) return;

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kOIDCKeychainService,
        (__bridge id)kSecAttrAccount: kOIDCKeychainAccount,
    };

    // Try update first, then add
    NSDictionary *update = @{ (__bridge id)kSecValueData: data };
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)update);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *addQuery = [query mutableCopy];
        addQuery[(__bridge id)kSecValueData] = data;
        addQuery[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        SecItemAdd((__bridge CFDictionaryRef)addQuery, nil);
    }
}

- (void)loadAuthStateFromKeychain {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kOIDCKeychainService,
        (__bridge id)kSecAttrAccount: kOIDCKeychainAccount,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecSuccess && result) {
        NSData *data = (__bridge_transfer NSData *)result;
        OIDAuthState *state;
        if (@available(iOS 11.0, *)) {
            state = [NSKeyedUnarchiver unarchivedObjectOfClass:[OIDAuthState class]
                                                     fromData:data
                                                        error:nil];
        } else {
            state = [NSKeyedUnarchiver unarchiveObjectWithData:data];
        }
        if ([state isKindOfClass:[OIDAuthState class]]) {
            self.authState = state;
            DDLogInfo(@"[OIDCManager] Loaded auth state from Keychain.");
        }
    }
}

- (void)deleteAuthStateFromKeychain {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kOIDCKeychainService,
        (__bridge id)kSecAttrAccount: kOIDCKeychainAccount,
    };
    SecItemDelete((__bridge CFDictionaryRef)query);
}

@end
