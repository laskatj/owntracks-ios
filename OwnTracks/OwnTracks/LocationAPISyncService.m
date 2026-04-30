//
//  LocationAPISyncService.m
//  OwnTracks
//
//  GET /api/location updates Core Data (Friend/Waypoint) via OwnTracking — same store as MQTT.
//  Recorder route history (GET .../history/.../route) is ViewController liveTrackPoints only, not persisted here.
//

#import "LocationAPISyncService.h"
#import "WebAppURLResolver.h"
#import "WebAppAuthHelper.h"
#import "Settings.h"
#import "CoreData.h"
#import "OwnTracking.h"
#import "OwnTracksAppDelegate.h"
#import "Friend+CoreDataClass.h"
#import <UIKit/UIKit.h>
#import <AuthenticationServices/AuthenticationServices.h>
#import <CocoaLumberjack/CocoaLumberjack.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

static NSURLSession *LocationAPISyncURLSession(void) {
    static NSURLSession *session;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 30.0;
        cfg.timeoutIntervalForResource = 90.0;
        cfg.waitsForConnectivity = YES;
        session = [NSURLSession sessionWithConfiguration:cfg];
    });
    return session;
}

/// Server allows `^[a-zA-Z0-9 ]+$` for POST /api/config/provision `deviceName`.
static NSString *OTProvisionSanitizedDeviceName(void) {
    NSString *raw = [UIDevice currentDevice].name ?: @"";
    NSMutableString *out = [NSMutableString stringWithCapacity:raw.length];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == ' ') {
            [out appendFormat:@"%C", c];
        }
    }
    NSString *collapsed = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    while ([collapsed rangeOfString:@"  "].location != NSNotFound) {
        collapsed = [collapsed stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    if (collapsed.length == 0) {
        return @"Device";
    }
    return collapsed;
}

static NSString * const kOTProvisionAPIDomain = @"OTProvisionAPI";
/// Returned when `provisionRemoteDeviceConfigurationIfNeededWithCompletion:` is invoked while a provision POST is already in flight.
static const NSInteger kOTProvisionAPICodeBusy = 998;

NSNotificationName const OwnTracksOAuthAccessTokenBecameAvailableNotification = @"OwnTracksOAuthAccessTokenBecameAvailable";

/// One interactive OAuth prompt per app process when the location API has no refresh token (same idea as WebAppViewController `startFullNativeAuth`).
static BOOL gLocationAPIOAuthPromptScheduledThisSession;

static UIViewController *LocationAPISyncTopMostViewController(void) {
    UIWindow *keyWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) {
                keyWindow = w;
                break;
            }
        }
        if (keyWindow) {
            break;
        }
    }
    if (!keyWindow) {
        UIWindowScene *scene = (UIWindowScene *)[UIApplication sharedApplication].connectedScenes.anyObject;
        keyWindow = scene.windows.firstObject;
    }
    UIViewController *root = keyWindow.rootViewController;
    while (root.presentedViewController) {
        root = root.presentedViewController;
    }
    return root;
}

/// Poll interval while app is active (no Settings UI).
static const NSTimeInterval kLocationAPIPollIntervalSeconds = 60.0;
/// Minimum seconds between debounced refreshes (Friends tab, etc.) and the last successful GET /api/location apply.
static const NSTimeInterval kLocationAPIDebouncedRefreshMinIntervalSeconds = 25.0;

@interface LocationAPISyncService ()
@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic) BOOL fetchInFlight;
@property (nonatomic) BOOL provisionInFlight;
@property (nonatomic, strong, nullable) NSDate *lastSuccessfulLocationAPIFetchDate;
/// Filled from `/.well-known/owntracks-app-auth` when Settings OAuth Client ID is empty; needed so Keychain lookup uses the same client_id the token was stored with.
@property (nonatomic, copy, nullable) NSString *cachedOAuthClientIdFromDiscovery;
/// Most recent access token used for GET /api/location; reused for device image fetches.
@property (nonatomic, copy, nullable) NSString *cachedAccessToken;
/// Unix timestamp (exp claim) of cachedAccessToken. Zero means unknown/uncached.
@property (nonatomic) NSTimeInterval cachedAccessTokenExpiry;
- (void)scheduleInteractiveOAuthIfNoTokenAfterFailure;
/// OAuth stores refresh tokens under `keychainAccountForWebAppURL` using discovery `client_id` from `/.well-known/owntracks-app-auth`, not necessarily Settings `oauth_client_id_preference`. Try discovery id first, then settings, then nil lookup.
- (void)trySilentRefreshWithCandidates:(NSArray<NSURL *> *)candidates
                    clientIdsOrdered:(NSArray *)discoveryThenPrefsThenNil
                            idsIndex:(NSUInteger)idsIdx
                            completion:(void (^)(NSString * _Nullable token))completion;
- (void)performGET:(NSURL *)apiURL
      accessToken:(NSString *)accessToken
 allowRetryOn401:(BOOL)allowRetryOn401
 transientAttempt:(NSUInteger)transientAttempt;
- (BOOL)isTransientLocationAPIURLSessionError:(NSError *)error;
- (BOOL)isTransientLocationAPIHTTPStatus:(NSInteger)status;
- (void)scheduleLocationAPIGETRetry:(NSURL *)apiURL
                      accessToken:(NSString *)accessToken
                  allowRetryOn401:(BOOL)allowRetryOn401
                 transientAttempt:(NSUInteger)nextAttempt;
- (void)oauthAccessTokenBecameAvailable:(NSNotification *)notification;
- (void)attemptNativeProvisionAfterOAuthOrForegroundIfNeeded;
@end

@implementation LocationAPISyncService

+ (instancetype)sharedInstance {
    static LocationAPISyncService *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[self alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidEnterBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(oauthAccessTokenBecameAvailable:)
                                                     name:OwnTracksOAuthAccessTokenBecameAvailableNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (instancetype)init {
    return [self initPrivate];
}

- (void)start {
    DDLogInfo(@"[LocationAPISyncService] start");
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    [self fetchAndApply];
    [self startPollTimer];
    // Native-only UI never loads WebAppViewController; deferred provision covers cold start once LAS token path is warm.
    __weak typeof(self) wself = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(wself) sself = wself;
        if (!sself) {
            return;
        }
        DDLogVerbose(@"[ProvisionAPI] deferred foreground attempt (native provision if needed)");
        [sself attemptNativeProvisionAfterOAuthOrForegroundIfNeeded];
    });
}

- (void)oauthAccessTokenBecameAvailable:(NSNotification *)notification {
    DDLogInfo(@"[ProvisionAPI] OAuth access token available — attempting native provision if needed");
    [self attemptNativeProvisionAfterOAuthOrForegroundIfNeeded];
}

- (void)attemptNativeProvisionAfterOAuthOrForegroundIfNeeded {
    [self provisionRemoteDeviceConfigurationIfNeededWithCompletion:^(BOOL applied, NSError *err) {
        if (applied) {
            DDLogInfo(@"[ProvisionAPI] configuration applied (native trigger)");
        } else if (err && [err.domain isEqualToString:kOTProvisionAPIDomain] && err.code == kOTProvisionAPICodeBusy) {
            DDLogVerbose(@"[ProvisionAPI] native trigger skipped (provision already in flight)");
        } else if (err) {
            DDLogVerbose(@"[ProvisionAPI] native trigger: %@", err.localizedDescription);
        }
    }];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    [self stopPollTimer];
}

- (void)startPollTimer {
    [self stopPollTimer];
    __weak typeof(self) wself = self;
    self.pollTimer = [NSTimer timerWithTimeInterval:kLocationAPIPollIntervalSeconds
                                            repeats:YES
                                              block:^(NSTimer * _Nonnull timer) {
        __strong typeof(wself) sself = wself;
        if (!sself) {
            return;
        }
        [sself fetchAndApply];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
}

- (void)stopPollTimer {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
}

- (void)requestLocationRefreshIfAppropriate {
    if (self.fetchInFlight) {
        DDLogVerbose(@"[LocationAPISyncService] debounced refresh skipped (fetch in flight)");
        return;
    }
    NSDate *last = self.lastSuccessfulLocationAPIFetchDate;
    if (last && [[NSDate date] timeIntervalSinceDate:last] < kLocationAPIDebouncedRefreshMinIntervalSeconds) {
        DDLogVerbose(@"[LocationAPISyncService] debounced refresh skipped (last fetch %.1fs ago)",
                      [[NSDate date] timeIntervalSinceDate:last]);
        return;
    }
    [self fetchAndApply];
}

- (void)fetchAndApply {
    if (self.fetchInFlight) {
        DDLogVerbose(@"[LocationAPISyncService] fetch skipped (already in flight)");
        return;
    }

    NSManagedObjectContext *mainMOC = CoreData.sharedInstance.mainMOC;
    NSURL *apiURL = [WebAppURLResolver locationAPIRequestURLFromPreferenceInMOC:mainMOC];
    NSArray<NSURL *> *candidates = [WebAppURLResolver webAppKeychainURLCandidatesFromPreferenceInMOC:mainMOC];
    if (!apiURL || candidates.count == 0) {
        return;
    }

    self.fetchInFlight = YES;
    __weak typeof(self) wself = self;

    // Use the cached access token if it still has >60 seconds of life remaining.
    // This avoids a refresh-grant POST to Authentik on every 60-second poll — with
    // token rotation enabled (Authentik threshold=seconds=0), unnecessary calls rotate
    // the refresh token each time, creating race conditions between concurrent callers
    // (WebApp tab, background wakeup processes) that share the same Keychain entry.
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *preCachedToken = nil;
    if (self.cachedAccessToken.length > 0 && self.cachedAccessTokenExpiry > now + 60.0) {
        preCachedToken = self.cachedAccessToken;
        DDLogVerbose(@"[LocationAPISyncService] Reusing cached access token (exp in %.0fs)", self.cachedAccessTokenExpiry - now);
    }

    void (^withToken)(NSString *) = ^(NSString *accessToken) {
        __strong typeof(wself) sself = wself;
        if (!sself) return;
        if (!accessToken.length) {
            DDLogInfo(@"[LocationAPISyncService] Skipping GET /api/location — no access token. "
                      @"Sign in once via a Web tab (embedded map/friends) so a refresh token is stored, "
                      @"or set OAuth Client ID in Settings. MQTT errors do not provide this token.");
            sself.fetchInFlight = NO;
            [sself scheduleInteractiveOAuthIfNoTokenAfterFailure];
            return;
        }
        [sself performGET:apiURL accessToken:accessToken allowRetryOn401:YES];
    };

    if (preCachedToken) {
        withToken(preCachedToken);
    } else {
        [self obtainAccessTokenForLocationAPIWithCompletion:^(NSString * _Nullable accessToken) {
            withToken(accessToken);
        }];
    }
}

/// Presents the same PKCE flow as the Web tab when there is no Keychain refresh token, so GET /api/location can run. At most once per cold start.
- (void)scheduleInteractiveOAuthIfNoTokenAfterFailure {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gLocationAPIOAuthPromptScheduledThisSession) {
            return;
        }
        // Only present interactive auth when the app is truly foreground-active.
        // Background wakeups (SLC, geofence) are too short-lived to host an
        // ASWebAuthenticationSession — presenting causes applicationWillTerminate
        // within milliseconds, killing the auth flow before a token is stored.
        // Do NOT set the flag so the prompt can retry on the next poll when active.
        UIApplicationState appState = [UIApplication sharedApplication].applicationState;
        if (appState != UIApplicationStateActive) {
            DDLogInfo(@"[LocationAPISyncService] Skipping OAuth prompt — app not active (state=%ld); will retry when foregrounded", (long)appState);
            return;
        }
        // Set flag immediately to prevent concurrent re-entrant calls during the async pre-check.
        // Will be reset to NO only if the prompt itself fails with a transient error.
        gLocationAPIOAuthPromptScheduledThisSession = YES;
        NSManagedObjectContext *moc = CoreData.sharedInstance.mainMOC;
        NSString *webPref = [Settings stringForKey:@"webappurl_preference" inMOC:moc];
        if (webPref.length == 0) {
            return;
        }
        NSURL *webAppURL = [WebAppURLResolver webAppKeychainURLFromPreferenceInMOC:moc];
        if (!webAppURL) {
            return;
        }
        UIViewController *presenter = LocationAPISyncTopMostViewController();
        if (!presenter) {
            DDLogWarn(@"[LocationAPISyncService] Cannot present OAuth — no key window");
            return;
        }
        NSString *oidcURLString = [Settings stringForKey:@"oidc_discovery_url_preference" inMOC:moc];
        NSURL *oidcURL = oidcURLString.length > 0 ? [NSURL URLWithString:oidcURLString] : nil;
        NSString *clientId = [Settings stringForKey:@"oauth_client_id_preference" inMOC:moc];
        if (!clientId.length) {
            clientId = nil;
        }

        // Re-check for a token before showing the prompt. The web app tab may have completed
        // its own OIDC passthrough and stored a refresh token in Keychain between the first
        // failed poll and now — in that case we can use it directly and skip the prompt.
        __weak typeof(self) wself = self;
        [self obtainAccessTokenForLocationAPIWithCompletion:^(NSString * _Nullable preCheckToken) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(wself) sself = wself;
                if (!sself) return;

                if (preCheckToken.length > 0) {
                    DDLogInfo(@"[LocationAPISyncService] Token found on pre-prompt re-check — skipping OAuth prompt");
                    NSManagedObjectContext *fetchMOC = CoreData.sharedInstance.mainMOC;
                    NSURL *apiURL = [WebAppURLResolver locationAPIRequestURLFromPreferenceInMOC:fetchMOC];
                    if (apiURL && !sself.fetchInFlight) {
                        sself.fetchInFlight = YES;
                        [sself performGET:apiURL accessToken:preCheckToken allowRetryOn401:YES];
                    }
                    return;
                }

                // Still no token — present the interactive sign-in prompt.
                DDLogInfo(@"[LocationAPISyncService] No refresh token — presenting sign-in (once per app launch)");
                [[WebAppAuthHelper sharedInstance] startAuthWithWebAppOrigin:webAppURL
                                                          oidcDiscoveryURL:oidcURL
                                                                  clientId:clientId
                                                    presentingViewController:presenter
                                                                 completion:^(NSString * _Nullable accessToken, NSError * _Nullable error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        __strong typeof(wself) sself2 = wself;
                        if (!sself2) return;
                        if (accessToken.length > 0) {
                            DDLogInfo(@"[LocationAPISyncService] Interactive OAuth succeeded; performing location API fetch");
                            NSManagedObjectContext *fetchMOC = CoreData.sharedInstance.mainMOC;
                            NSURL *apiURL = [WebAppURLResolver locationAPIRequestURLFromPreferenceInMOC:fetchMOC];
                            if (apiURL) {
                                sself2.fetchInFlight = YES;
                                [sself2 performGET:apiURL accessToken:accessToken allowRetryOn401:YES];
                            }
                        } else {
                            BOOL userCancelled = (error.domain == ASWebAuthenticationSessionErrorDomain &&
                                                 error.code == ASWebAuthenticationSessionErrorCodeCanceledLogin);
                            if (userCancelled) {
                                DDLogInfo(@"[LocationAPISyncService] Interactive OAuth cancelled by user");
                                // flag stays YES — user chose to skip, respect it for this session
                            } else {
                                gLocationAPIOAuthPromptScheduledThisSession = NO; // transient failure — allow retry next poll
                                DDLogVerbose(@"[LocationAPISyncService] Interactive OAuth failed: %@", error.localizedDescription);
                            }
                        }
                    });
                }];
            });
        }];
    });
}

/// Resolves an access token: tries multiple Keychain base URLs (/, /map, preference path), and discovery `client_id` for Keychain lookup (must match WebAppAuthHelper storage after OAuth).
- (void)obtainAccessTokenForLocationAPIWithCompletion:(void (^)(NSString * _Nullable token))completion {
    NSManagedObjectContext *mainMOC = CoreData.sharedInstance.mainMOC;
    NSArray<NSURL *> *candidates = [WebAppURLResolver webAppKeychainURLCandidatesFromPreferenceInMOC:mainMOC];
    if (candidates.count == 0) {
        completion(nil);
        return;
    }

    NSString *clientPref = [Settings stringForKey:@"oauth_client_id_preference" inMOC:mainMOC];
    if (clientPref.length == 0) {
        clientPref = nil;
    }

    // Fast path: already cached discovery client_id — build chain without network.
    if (self.cachedOAuthClientIdFromDiscovery.length > 0) {
        NSArray *chain = [self.class orderedKeychainClientIdChainDiscovery:self.cachedOAuthClientIdFromDiscovery settings:clientPref];
        [self trySilentRefreshWithCandidates:candidates clientIdsOrdered:chain idsIndex:0 completion:completion];
        return;
    }

    NSURL *origin = [WebAppURLResolver webAppOriginURLFromPreferenceInMOC:mainMOC];
    if (!origin) {
        NSArray *chain = [self.class orderedKeychainClientIdChainDiscovery:nil settings:clientPref];
        [self trySilentRefreshWithCandidates:candidates clientIdsOrdered:chain idsIndex:0 completion:completion];
        return;
    }

    __weak typeof(self) wself = self;
    [[WebAppAuthHelper sharedInstance] fetchDiscoveryFromOrigin:origin completion:^(NSDictionary * _Nullable config, NSError * _Nullable error) {
        __strong typeof(wself) sself = wself;
        if (!sself) {
            completion(nil);
            return;
        }
        NSString *cid = nil;
        if ([config[@"client_id"] isKindOfClass:[NSString class]] && [(NSString *)config[@"client_id"] length] > 0) {
            cid = config[@"client_id"];
            sself.cachedOAuthClientIdFromDiscovery = cid;
            DDLogInfo(@"[LocationAPISyncService] Cached client_id from owntracks-app-auth for Keychain lookup (may differ from Settings)");
        } else if (error) {
            DDLogVerbose(@"[LocationAPISyncService] Discovery fetch failed: %@ — trying Keychain lookup with Settings client_id only", error.localizedDescription);
        }
        NSArray *chain = [LocationAPISyncService orderedKeychainClientIdChainDiscovery:cid settings:clientPref];
        [sself trySilentRefreshWithCandidates:candidates clientIdsOrdered:chain idsIndex:0 completion:completion];
    }];
}

- (void)invalidateOAuthCredentialCache {
    self.cachedAccessToken = nil;
    self.cachedAccessTokenExpiry = 0;
    self.cachedOAuthClientIdFromDiscovery = nil;
    self.fetchInFlight = NO;
    self.provisionInFlight = NO;
    DDLogInfo(@"[LocationAPISyncService] invalidateOAuthCredentialCache");
}

- (nullable NSString *)peekCachedDiscoveryOAuthClientId {
    return self.cachedOAuthClientIdFromDiscovery;
}

/// Ordered list: discovery `client_id` (if any), settings id if different, then [NSNull null] to try WebAppAuthHelper lookup with nil (|path|_ + legacy origin).
+ (NSArray *)orderedKeychainClientIdChainDiscovery:(NSString *)discoveryClientId settings:(NSString *)clientPref {
    NSMutableOrderedSet *seen = [NSMutableOrderedSet orderedSet];
    if (discoveryClientId.length > 0) {
        [seen addObject:discoveryClientId];
    }
    if (clientPref.length > 0) {
        [seen addObject:clientPref];
    }
    NSMutableArray *chain = [NSMutableArray array];
    for (NSString *s in seen) {
        [chain addObject:s];
    }
    [chain addObject:[NSNull null]];
    return chain;
}

- (void)trySilentRefreshWithCandidates:(NSArray<NSURL *> *)candidates
                    clientIdsOrdered:(NSArray *)discoveryThenPrefsThenNil
                            idsIndex:(NSUInteger)idsIdx
                            completion:(void (^)(NSString * _Nullable token))completion {
    if (idsIdx >= discoveryThenPrefsThenNil.count) {
        completion(nil);
        return;
    }
    id raw = discoveryThenPrefsThenNil[idsIdx];
    NSString *cid = (raw == [NSNull null]) ? nil : (NSString *)raw;
    __weak typeof(self) wself = self;
    [self trySilentRefreshWithCandidates:candidates clientId:cid index:0 completion:^(NSString * _Nullable accessToken) {
        __strong typeof(wself) sself = wself;
        if (!sself) {
            completion(nil);
            return;
        }
        if (accessToken.length > 0) {
            completion(accessToken);
            return;
        }
        [sself trySilentRefreshWithCandidates:candidates clientIdsOrdered:discoveryThenPrefsThenNil idsIndex:idsIdx + 1 completion:completion];
    }];
}

- (void)trySilentRefreshWithCandidates:(NSArray<NSURL *> *)candidates
                              clientId:(NSString *)clientId
                                 index:(NSUInteger)idx
                            completion:(void (^)(NSString * _Nullable token))completion {
    if (idx >= candidates.count) {
        DDLogInfo(@"[LocationAPISyncService] No OAuth refresh token matched after trying %lu Keychain base URL(s). "
                  @"The location API requires a prior web sign-in (Web tab) or a stored refresh token.",
                  (unsigned long)candidates.count);
        completion(nil);
        return;
    }
    NSURL *u = candidates[idx];
    __weak typeof(self) wself = self;
    [[WebAppAuthHelper sharedInstance] attemptSilentRefreshForWebAppURL:u clientId:clientId completion:^(NSString * _Nullable accessToken, NSError * _Nullable error) {
        __strong typeof(wself) sself = wself;
        if (!sself) {
            completion(nil);
            return;
        }
        if (accessToken.length > 0) {
            DDLogInfo(@"[LocationAPISyncService] Silent refresh OK for base URL %@", u.absoluteString);
            completion(accessToken);
            return;
        }
        [sself trySilentRefreshWithCandidates:candidates clientId:clientId index:idx + 1 completion:completion];
    }];
}

- (void)performGET:(NSURL *)apiURL accessToken:(NSString *)accessToken allowRetryOn401:(BOOL)allowRetryOn401 {
    [self performGET:apiURL accessToken:accessToken allowRetryOn401:allowRetryOn401 transientAttempt:0];
}

- (BOOL)isTransientLocationAPIURLSessionError:(NSError *)error {
    if (!error) {
        return NO;
    }
    if (![error.domain isEqualToString:NSURLErrorDomain]) {
        return NO;
    }
    switch (error.code) {
        case NSURLErrorTimedOut:
        case NSURLErrorCannotFindHost:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorNotConnectedToInternet:
        case NSURLErrorDNSLookupFailed:
        case NSURLErrorInternationalRoamingOff:
        case NSURLErrorCallIsActive:
        case NSURLErrorDataNotAllowed:
            return YES;
        default:
            return NO;
    }
}

- (BOOL)isTransientLocationAPIHTTPStatus:(NSInteger)status {
    return status == 408 || status == 429 || status == 502 || status == 503 || status == 504;
}

- (void)scheduleLocationAPIGETRetry:(NSURL *)apiURL
                      accessToken:(NSString *)accessToken
                  allowRetryOn401:(BOOL)allowRetryOn401
                   transientAttempt:(NSUInteger)nextAttempt {
    NSTimeInterval delay = MIN(pow(2.0, (double)nextAttempt), 32.0);
    DDLogInfo(@"[LocationAPISyncService] GET retry in %.0fs (attempt %lu)", delay, (unsigned long)nextAttempt);
    __weak typeof(self) wself = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(wself) sself = wself;
        if (!sself) {
            return;
        }
        [sself performGET:apiURL accessToken:accessToken allowRetryOn401:allowRetryOn401 transientAttempt:nextAttempt];
    });
}

- (void)performGET:(NSURL *)apiURL
      accessToken:(NSString *)accessToken
 allowRetryOn401:(BOOL)allowRetryOn401
 transientAttempt:(NSUInteger)transientAttempt {
    self.cachedAccessToken = accessToken;
    NSDictionary *atClaims = [WebAppAuthHelper jwtPayloadClaimsFromToken:accessToken];
    self.cachedAccessTokenExpiry = [atClaims[@"exp"] doubleValue]; // 0 if opaque/missing
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:apiURL];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 30.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", accessToken] forHTTPHeaderField:@"Authorization"];

    __weak typeof(self) wself = self;
    NSURLSessionDataTask *task = [LocationAPISyncURLSession() dataTaskWithRequest:request
                                                                 completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        __strong typeof(wself) sself = wself;
        if (!sself) {
            return;
        }
        if (error) {
            DDLogWarn(@"[LocationAPISyncService] GET failed: %@", error.localizedDescription);
            if (transientAttempt < 3 && [sself isTransientLocationAPIURLSessionError:error]) {
                [sself scheduleLocationAPIGETRetry:apiURL accessToken:accessToken allowRetryOn401:allowRetryOn401 transientAttempt:transientAttempt + 1];
            } else {
                sself.fetchInFlight = NO;
            }
            return;
        }
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (status == 401 && allowRetryOn401) {
            // Invalidate the cached token so the retry path always gets a fresh one.
            sself.cachedAccessToken = nil;
            sself.cachedAccessTokenExpiry = 0;
            [sself obtainAccessTokenForLocationAPIWithCompletion:^(NSString * _Nullable newToken) {
                __strong typeof(wself) sself2 = wself;
                if (!sself2) {
                    return;
                }
                if (!newToken.length) {
                    DDLogWarn(@"[LocationAPISyncService] 401 and could not obtain a new access token");
                    sself2.fetchInFlight = NO;
                    return;
                }
                [sself2 performGET:apiURL accessToken:newToken allowRetryOn401:NO transientAttempt:0];
            }];
            return;
        }
        if (status != 200) {
            DDLogWarn(@"[LocationAPISyncService] GET status %ld", (long)status);
            if (transientAttempt < 3 && [sself isTransientLocationAPIHTTPStatus:status]) {
                [sself scheduleLocationAPIGETRetry:apiURL accessToken:accessToken allowRetryOn401:allowRetryOn401 transientAttempt:transientAttempt + 1];
            } else {
                sself.fetchInFlight = NO;
            }
            return;
        }
        [sself applyLocationJSONData:data];
        sself.lastSuccessfulLocationAPIFetchDate = [NSDate date];
        sself.fetchInFlight = NO;
    }];
    [task resume];
}

- (void)applyLocationJSONData:(NSData *)data {
    if (!data.length) {
        return;
    }
    NSError *jsonError = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (jsonError || ![obj isKindOfClass:[NSDictionary class]]) {
        DDLogWarn(@"[LocationAPISyncService] JSON parse error: %@", jsonError.localizedDescription);
        return;
    }
    NSDictionary *root = (NSDictionary *)obj;

    NSString *accessTokenSnapshot = self.cachedAccessToken;
    NSManagedObjectContext *mainMOC2 = CoreData.sharedInstance.mainMOC;
    NSURL *originSnapshot = [WebAppURLResolver webAppOriginURLFromPreferenceInMOC:mainMOC2];
    NSManagedObjectContext *queuedMOC = CoreData.sharedInstance.queuedMOC;
    [queuedMOC performBlock:^{
        NSMutableSet<NSString *> *allowedTopics = [NSMutableSet set];
        for (NSString *userKey in root) {
            id entry = root[userKey];
            if (![entry isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSDictionary *userDict = (NSDictionary *)entry;
            id devices = userDict[@"devices"];
            if (![devices isKindOfClass:[NSArray class]]) {
                continue;
            }
            for (id dev in (NSArray *)devices) {
                if (![dev isKindOfClass:[NSDictionary class]]) {
                    continue;
                }
                NSDictionary *device = (NSDictionary *)dev;
                NSString *topic = [LocationAPISyncService mqttTopicForLocationAPIDevice:device userKey:userKey];
                if (topic.length) {
                    [allowedTopics addObject:topic];
                }

                NSDictionary *payload = [self.class ownTracksLocationDictionaryFromAPIDevice:device];
                if (!payload) {
                    continue;
                }
                if (!topic.length) {
                    DDLogWarn(@"[LocationAPISyncService] location payload without resolvable MQTT topic, skipping apply");
                    continue;
                }
                if ([topic hasPrefix:@"api/"]) {
                    DDLogInfo(@"[LocationAPISyncService] REST-only device, using synthetic topic %@", topic);
                }

                [[OwnTracking sharedInstance] applyAPILocationPayloadForMqttTopic:topic
                                                                       dictionary:payload
                                                                          context:queuedMOC];

                // Store user name for route API URL construction, and deviceName as the
                // display name if the Friend has no card name yet.
                Friend *syncFriend = [Friend friendWithTopic:topic inManagedObjectContext:queuedMOC];
                if (syncFriend) {
                    syncFriend.routeAPIUser = userKey;
                    id deviceNameObj = device[@"deviceName"];
                    if ([deviceNameObj isKindOfClass:[NSString class]] && [(NSString *)deviceNameObj length] > 0
                            && syncFriend.cardName == nil) {
                        syncFriend.cardName = (NSString *)deviceNameObj;
                    }
                }

                // Fetch device image if not yet stored.
                id imagePathObj = device[@"deviceImage"];
                if ([imagePathObj isKindOfClass:[NSString class]] && [(NSString *)imagePathObj length] > 0) {
                    NSString *imagePath = (NSString *)imagePathObj;
                    Friend *friend = [Friend friendWithTopic:topic inManagedObjectContext:queuedMOC];
                    if (friend && friend.cardImage == nil) {
                        [self fetchDeviceImageAtPath:imagePath accessToken:accessTokenSnapshot forTopic:topic originURL:originSnapshot];
                    }
                }
            }
        }

        NSString *ownTopic = [Settings theGeneralTopicInMOC:queuedMOC];
        NSUInteger pruned = 0;
        NSArray *friendsSnapshot = [Friend allFriendsInManagedObjectContext:queuedMOC];
        for (Friend *friend in friendsSnapshot) {
            NSString *t = friend.topic;
            if (!t.length) {
                continue;
            }
            if (ownTopic.length && [t isEqualToString:ownTopic]) {
                continue;
            }
            if ([allowedTopics containsObject:t]) {
                continue;
            }
            [queuedMOC deleteObject:friend];
            pruned++;
        }

        [CoreData.sharedInstance sync:queuedMOC];
        DDLogInfo(@"[LocationAPISyncService] applied location API payload (allowedTopics=%lu prunedFriends=%lu)",
                  (unsigned long)allowedTopics.count, (unsigned long)pruned);
    }];
}

+ (nullable NSString *)mqttTopicForLocationAPIDevice:(NSDictionary *)device userKey:(NSString *)userKey {
    id topicObj = device[@"mqttTopic"];
    if ([topicObj isKindOfClass:[NSString class]] && [(NSString *)topicObj length] > 0) {
        return (NSString *)topicObj;
    }
    id trackerIdObj = device[@"trackerId"];
    if (![trackerIdObj isKindOfClass:[NSString class]] || [(NSString *)trackerIdObj length] == 0) {
        DDLogVerbose(@"[LocationAPISyncService] device missing mqttTopic and trackerId, skipping");
        return nil;
    }
    if (!userKey.length) {
        return nil;
    }
    return [NSString stringWithFormat:@"api/%@/%@", userKey, (NSString *)trackerIdObj];
}

+ (nullable NSDictionary *)ownTracksLocationDictionaryFromAPIDevice:(NSDictionary *)device {
    NSNumber *tst = nil;
    id ts = device[@"timestamp"];
    if ([ts isKindOfClass:[NSNumber class]]) {
        tst = (NSNumber *)ts;
    }
    if (!tst) {
        return nil;
    }

    id latObj = device[@"latitude"];
    id lonObj = device[@"longitude"];
    if (![latObj isKindOfClass:[NSNumber class]] || ![lonObj isKindOfClass:[NSNumber class]]) {
        return nil;
    }
    NSNumber *lat = (NSNumber *)latObj;
    NSNumber *lon = (NSNumber *)lonObj;
    if (lat.doubleValue == 0.0 && lon.doubleValue == 0.0) {
        return nil;
    }

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"tst"] = tst;
    d[@"lat"] = lat;
    d[@"lon"] = lon;

    id acc = device[@"accuracy"];
    if ([acc isKindOfClass:[NSNumber class]]) {
        d[@"acc"] = acc;
    }
    id alt = device[@"altitude"];
    if ([alt isKindOfClass:[NSNumber class]]) {
        d[@"alt"] = alt;
    }
    id batt = device[@"battery"];
    if ([batt isKindOfClass:[NSNumber class]]) {
        d[@"batt"] = batt;
    }
    id cog = device[@"courseOverGround"];
    if ([cog isKindOfClass:[NSNumber class]]) {
        d[@"cog"] = cog;
    }
    id vel = device[@"velocity"];
    if ([vel isKindOfClass:[NSNumber class]]) {
        d[@"vel"] = vel;
    }
    id trig = device[@"trigger"];
    if ([trig isKindOfClass:[NSString class]]) {
        d[@"t"] = trig;
    }
    id tid = device[@"trackerId"];
    if ([tid isKindOfClass:[NSString class]]) {
        d[@"tid"] = tid;
    }
    id pressure = device[@"pressure"];
    if ([pressure isKindOfClass:[NSNumber class]]) {
        d[@"p"] = pressure;
    }
    id conn = device[@"connection"];
    if ([conn isKindOfClass:[NSString class]] && [(NSString *)conn length] > 0) {
        d[@"conn"] = conn;
    }

    id zoneName = device[@"zoneName"];
    if ([zoneName isKindOfClass:[NSString class]] && [(NSString *)zoneName length] > 0) {
        d[@"zonename"] = zoneName;
    }

    return [d copy];
}

- (void)performAuthenticatedGET:(NSURL *)url completion:(void (^)(NSData * _Nullable, NSError * _Nullable))completion {
    DDLogInfo(@"[LocationAPISyncService] performAuthenticatedGET: obtaining token for %@", url);
    __weak typeof(self) wself = self;
    [self obtainAccessTokenForLocationAPIWithCompletion:^(NSString * _Nullable accessToken) {
        __strong typeof(wself) sself = wself;
        if (!sself) {
            completion(nil, [NSError errorWithDomain:@"LocationAPISyncService" code:0 userInfo:nil]);
            return;
        }
        if (!accessToken.length) {
            DDLogWarn(@"[LocationAPISyncService] performAuthenticatedGET: no access token for %@", url);
            completion(nil, [NSError errorWithDomain:@"LocationAPISyncService" code:401 userInfo:nil]);
            return;
        }
        DDLogInfo(@"[LocationAPISyncService] performAuthenticatedGET: token OK, sending GET %@", url);

        __block void (^runGET)(NSString *token, NSUInteger transientAttempt);
        runGET = ^(NSString *token, NSUInteger transientAttempt) {
            __strong typeof(wself) sselfInner = wself;
            if (!sselfInner) {
                completion(nil, [NSError errorWithDomain:@"LocationAPISyncService" code:0 userInfo:nil]);
                return;
            }
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
            request.HTTPMethod = @"GET";
            request.timeoutInterval = 30.0;
            [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
            [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];

            [[LocationAPISyncURLSession() dataTaskWithRequest:request
                                            completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
                __strong typeof(wself) sself2 = wself;
                if (!sself2) {
                    completion(nil, [NSError errorWithDomain:@"LocationAPISyncService" code:0 userInfo:nil]);
                    return;
                }
                if (error) {
                    DDLogWarn(@"[LocationAPISyncService] performAuthenticatedGET network error: %@", error.localizedDescription);
                    if (transientAttempt < 3 && [sself2 isTransientLocationAPIURLSessionError:error]) {
                        NSTimeInterval delay = MIN(pow(2.0, (double)(transientAttempt + 1)), 32.0);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            runGET(token, transientAttempt + 1);
                        });
                    } else {
                        completion(nil, error);
                    }
                    return;
                }
                NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
                DDLogInfo(@"[LocationAPISyncService] performAuthenticatedGET: HTTP %ld (%lu bytes) for %@",
                          (long)status, (unsigned long)data.length, url);
                if (status == 401) {
                    DDLogInfo(@"[LocationAPISyncService] performAuthenticatedGET: 401 — refreshing token and retrying %@", url);
                    [sself2 obtainAccessTokenForLocationAPIWithCompletion:^(NSString * _Nullable newToken) {
                        if (!newToken.length) {
                            DDLogWarn(@"[LocationAPISyncService] performAuthenticatedGET: 401 retry — could not refresh token for %@", url);
                            completion(nil, [NSError errorWithDomain:@"LocationAPISyncService" code:401 userInfo:nil]);
                            return;
                        }
                        runGET(newToken, 0);
                    }];
                    return;
                }
                if (status != 200) {
                    DDLogWarn(@"[LocationAPISyncService] performAuthenticatedGET HTTP %ld for %@", (long)status, url);
                    if (transientAttempt < 3 && [sself2 isTransientLocationAPIHTTPStatus:status]) {
                        NSTimeInterval delay = MIN(pow(2.0, (double)(transientAttempt + 1)), 32.0);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            runGET(token, transientAttempt + 1);
                        });
                    } else {
                        completion(nil, [NSError errorWithDomain:@"LocationAPISyncService" code:status userInfo:nil]);
                    }
                    return;
                }
                completion(data, nil);
            }] resume];
        };
        runGET(accessToken, 0);
    }];
}

- (void)provisionRemoteDeviceConfigurationIfNeededWithCompletion:(void (^)(BOOL applied, NSError * _Nullable error))completion {
    if (!completion) {
        return;
    }
    if (self.provisionInFlight) {
        DDLogVerbose(@"[ProvisionAPI] provision skipped (already in flight)");
        completion(NO, [NSError errorWithDomain:kOTProvisionAPIDomain
                                            code:kOTProvisionAPICodeBusy
                                        userInfo:@{NSLocalizedDescriptionKey: @"Provision request already in progress"}]);
        return;
    }
    NSManagedObjectContext *moc = CoreData.sharedInstance.mainMOC;
    if (![Settings appEmbeddedWebShouldRequestProvisioningInMOC:moc]) {
        DDLogVerbose(@"[ProvisionAPI] provision skipped (app does not need provisioning)");
        completion(NO, nil);
        return;
    }
    NSURL *provisionURL = [WebAppURLResolver configProvisionAPIRequestURLFromPreferenceInMOC:moc];
    if (!provisionURL) {
        DDLogWarn(@"[ProvisionAPI] provision skipped (no web app origin / provision URL)");
        completion(NO, nil);
        return;
    }

    NSError *jsonErr = nil;
    NSDictionary *bodyDict = @{ @"deviceName": OTProvisionSanitizedDeviceName() };
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:bodyDict options:0 error:&jsonErr];
    if (!bodyData) {
        DDLogError(@"[ProvisionAPI] could not encode provision body: %@", jsonErr);
        completion(NO, jsonErr);
        return;
    }

    self.provisionInFlight = YES;
    __weak typeof(self) wself = self;
    [self obtainAccessTokenForLocationAPIWithCompletion:^(NSString * _Nullable accessToken) {
        __strong typeof(wself) sself = wself;
        if (!sself) {
            completion(NO, [NSError errorWithDomain:kOTProvisionAPIDomain code:0 userInfo:nil]);
            return;
        }
        if (!accessToken.length) {
            DDLogWarn(@"[ProvisionAPI] no access token — cannot POST provision");
            sself.provisionInFlight = NO;
            completion(NO, [NSError errorWithDomain:kOTProvisionAPIDomain
                                                code:401
                                            userInfo:@{NSLocalizedDescriptionKey: @"No access token"}]);
            return;
        }

        __block void (^runPOST)(NSString *token, BOOL allowRetry401);
        runPOST = ^(NSString *token, BOOL allowRetry401) {
            __strong typeof(wself) sselfInner = wself;
            if (!sselfInner) {
                completion(NO, [NSError errorWithDomain:kOTProvisionAPIDomain code:0 userInfo:nil]);
                return;
            }
            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:provisionURL];
            req.HTTPMethod = @"POST";
            req.timeoutInterval = 30.0;
            [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
            [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
            [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
            req.HTTPBody = bodyData;

            [[LocationAPISyncURLSession() dataTaskWithRequest:req
                                            completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
                __strong typeof(wself) sself2 = wself;
                if (!sself2) {
                    completion(NO, nil);
                    return;
                }
                if (error) {
                    DDLogWarn(@"[ProvisionAPI] POST network error: %@", error.localizedDescription);
                    sself2.provisionInFlight = NO;
                    completion(NO, error);
                    return;
                }
                NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
                DDLogInfo(@"[ProvisionAPI] POST %@ → HTTP %ld (%lu bytes)",
                          provisionURL.absoluteString, (long)status, (unsigned long)data.length);

                if (status == 401 && allowRetry401) {
                    sself2.cachedAccessToken = nil;
                    sself2.cachedAccessTokenExpiry = 0;
                    [sself2 obtainAccessTokenForLocationAPIWithCompletion:^(NSString * _Nullable newToken) {
                        __strong typeof(wself) sself3 = wself;
                        if (!sself3) {
                            completion(NO, nil);
                            return;
                        }
                        if (!newToken.length) {
                            DDLogWarn(@"[ProvisionAPI] 401 retry — could not refresh token");
                            sself3.provisionInFlight = NO;
                            completion(NO, [NSError errorWithDomain:kOTProvisionAPIDomain
                                                                code:401
                                                            userInfo:@{NSLocalizedDescriptionKey: @"Unauthorized"}]);
                            return;
                        }
                        runPOST(newToken, NO);
                    }];
                    return;
                }

                if (status == 200) {
                    NSError *parseErr = nil;
                    id obj = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr] : nil;
                    if (parseErr || ![obj isKindOfClass:[NSDictionary class]]) {
                        DDLogWarn(@"[ProvisionAPI] 200 but JSON parse failed: %@", parseErr.localizedDescription);
                        sself2.provisionInFlight = NO;
                        completion(NO, parseErr ?: [NSError errorWithDomain:kOTProvisionAPIDomain
                                                                     code:2
                                                                 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON"}]);
                        return;
                    }
                    NSDictionary *payload = (NSDictionary *)obj;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        __strong typeof(wself) sself4 = wself;
                        if (!sself4) {
                            completion(NO, nil);
                            return;
                        }
                        OwnTracksAppDelegate *ad = (OwnTracksAppDelegate *)[UIApplication sharedApplication].delegate;
                        if (![ad isKindOfClass:[OwnTracksAppDelegate class]]) {
                            sself4.provisionInFlight = NO;
                            completion(NO, [NSError errorWithDomain:kOTProvisionAPIDomain code:3 userInfo:nil]);
                            return;
                        }
                        [ad terminateSession];
                        [ad configFromDictionary:payload];
                        ad.configLoad = [NSDate date];
                        [ad reconnect];
                        sself4.provisionInFlight = NO;
                        DDLogInfo(@"[ProvisionAPI] configuration applied from POST /api/config/provision");
                        completion(YES, nil);
                    });
                    return;
                }

                NSString *serverMsg = nil;
                if (data.length) {
                    id errObj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if ([errObj isKindOfClass:[NSDictionary class]]) {
                        id em = errObj[@"error"];
                        if ([em isKindOfClass:[NSString class]]) {
                            serverMsg = (NSString *)em;
                        }
                    }
                }
                if (!serverMsg.length) {
                    serverMsg = [NSString stringWithFormat:@"HTTP %ld", (long)status];
                }
                NSError *apiErr = [NSError errorWithDomain:kOTProvisionAPIDomain
                                                      code:status
                                                  userInfo:@{NSLocalizedDescriptionKey: serverMsg}];
                DDLogWarn(@"[ProvisionAPI] provision failed: %@", serverMsg);
                sself2.provisionInFlight = NO;
                completion(NO, apiErr);
            }] resume];
        };

        runPOST(accessToken, YES);
    }];
}

- (void)fetchDeviceImageAtPath:(NSString *)relativePath
                   accessToken:(NSString *)accessToken
                      forTopic:(NSString *)topic
                    originURL:(NSURL *)origin {
    if (!origin || relativePath.length == 0 || accessToken.length == 0) {
        return;
    }
    NSURLComponents *c = [NSURLComponents componentsWithURL:origin resolvingAgainstBaseURL:NO];
    c.path = relativePath;
    c.query = nil;
    NSURL *imageURL = c.URL;
    if (!imageURL) {
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:imageURL];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 30.0;
    [req setValue:[NSString stringWithFormat:@"Bearer %@", accessToken] forHTTPHeaderField:@"Authorization"];

    __weak typeof(self) wself = self;
    [[LocationAPISyncURLSession() dataTaskWithRequest:req
                                    completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error || !data.length) {
            DDLogVerbose(@"[LocationAPISyncService] Device image fetch failed for %@: %@", topic, error.localizedDescription);
            return;
        }
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (status != 200) {
            DDLogVerbose(@"[LocationAPISyncService] Device image fetch HTTP %ld for %@", (long)status, topic);
            return;
        }
        // Validate it is a recognizable image.
        if (![UIImage imageWithData:data]) {
            DDLogVerbose(@"[LocationAPISyncService] Device image data not a valid image for %@", topic);
            return;
        }
        __strong typeof(wself) sself = wself;
        if (!sself) {
            return;
        }
        NSManagedObjectContext *queuedMOC = CoreData.sharedInstance.queuedMOC;
        [queuedMOC performBlock:^{
            Friend *friend = [Friend friendWithTopic:topic inManagedObjectContext:queuedMOC];
            if (friend && friend.cardImage == nil) {
                friend.cardImage = data;
                [CoreData.sharedInstance sync:queuedMOC];
                DDLogInfo(@"[LocationAPISyncService] Stored device image for %@", topic);
            }
        }];
    }] resume];
}

@end
