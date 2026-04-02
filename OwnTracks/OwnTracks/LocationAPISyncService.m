//
//  LocationAPISyncService.m
//  OwnTracks
//

#import "LocationAPISyncService.h"
#import "WebAppURLResolver.h"
#import "WebAppAuthHelper.h"
#import "Settings.h"
#import "CoreData.h"
#import "OwnTracking.h"
#import "Friend+CoreDataClass.h"
#import <UIKit/UIKit.h>
#import <AuthenticationServices/AuthenticationServices.h>
#import <CocoaLumberjack/CocoaLumberjack.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

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

@interface LocationAPISyncService ()
@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic) BOOL fetchInFlight;
/// Filled from `/.well-known/owntracks-app-auth` when Settings OAuth Client ID is empty; needed so Keychain lookup uses the same client_id the token was stored with.
@property (nonatomic, copy, nullable) NSString *cachedOAuthClientIdFromDiscovery;
/// Most recent access token used for GET /api/location; reused for device image fetches.
@property (nonatomic, copy, nullable) NSString *cachedAccessToken;
- (void)scheduleInteractiveOAuthIfNoTokenAfterFailure;
/// OAuth stores refresh tokens under `keychainAccountForWebAppURL` using discovery `client_id` from `/.well-known/owntracks-app-auth`, not necessarily Settings `oauth_client_id_preference`. Try discovery id first, then settings, then nil lookup.
- (void)trySilentRefreshWithCandidates:(NSArray<NSURL *> *)candidates
                    clientIdsOrdered:(NSArray *)discoveryThenPrefsThenNil
                            idsIndex:(NSUInteger)idsIdx
                            completion:(void (^)(NSString * _Nullable token))completion;
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
    }
    return self;
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
    [self obtainAccessTokenForLocationAPIWithCompletion:^(NSString * _Nullable accessToken) {
        __strong typeof(wself) sself = wself;
        if (!sself) {
            return;
        }
        if (!accessToken.length) {
            DDLogInfo(@"[LocationAPISyncService] Skipping GET /api/location — no access token. "
                      @"Sign in once via a Web tab (embedded map/friends) so a refresh token is stored, "
                      @"or set OAuth Client ID in Settings. MQTT errors do not provide this token.");
            sself.fetchInFlight = NO;
            [sself scheduleInteractiveOAuthIfNoTokenAfterFailure];
            return;
        }
        [sself performGET:apiURL accessToken:accessToken allowRetryOn401:YES];
    }];
}

/// Presents the same PKCE flow as the Web tab when there is no Keychain refresh token, so GET /api/location can run. At most once per cold start.
- (void)scheduleInteractiveOAuthIfNoTokenAfterFailure {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gLocationAPIOAuthPromptScheduledThisSession) {
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
    self.cachedAccessToken = accessToken;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:apiURL];
    request.HTTPMethod = @"GET";
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", accessToken] forHTTPHeaderField:@"Authorization"];

    __weak typeof(self) wself = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                 completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        __strong typeof(wself) sself = wself;
        if (!sself) {
            return;
        }
        if (error) {
            DDLogWarn(@"[LocationAPISyncService] GET failed: %@", error.localizedDescription);
            sself.fetchInFlight = NO;
            return;
        }
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (status == 401 && allowRetryOn401) {
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
                [sself2 performGET:apiURL accessToken:newToken allowRetryOn401:NO];
            }];
            return;
        }
        if (status != 200) {
            DDLogWarn(@"[LocationAPISyncService] GET status %ld", (long)status);
            sself.fetchInFlight = NO;
            return;
        }
        [sself applyLocationJSONData:data];
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
                NSDictionary *payload = [self.class ownTracksLocationDictionaryFromAPIDevice:device];
                if (!payload) {
                    continue;
                }
                // Prefer the MQTT topic for the Friend identifier; fall back to a stable
                // synthetic key for REST-only (HTTP POST) devices that have no MQTT topic.
                NSString *topic = nil;
                id topicObj = device[@"mqttTopic"];
                if ([topicObj isKindOfClass:[NSString class]] && [(NSString *)topicObj length] > 0) {
                    topic = (NSString *)topicObj;
                } else {
                    id trackerIdObj = device[@"trackerId"];
                    if (![trackerIdObj isKindOfClass:[NSString class]] || [(NSString *)trackerIdObj length] == 0) {
                        DDLogVerbose(@"[LocationAPISyncService] device missing mqttTopic and trackerId, skipping");
                        continue;
                    }
                    topic = [NSString stringWithFormat:@"api/%@/%@", userKey, (NSString *)trackerIdObj];
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
        [CoreData.sharedInstance sync:queuedMOC];
        DDLogInfo(@"[LocationAPISyncService] applied location API payload");
    }];
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
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"GET";
        [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        [request setValue:[NSString stringWithFormat:@"Bearer %@", accessToken] forHTTPHeaderField:@"Authorization"];

        [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                        completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            if (error) {
                DDLogWarn(@"[LocationAPISyncService] performAuthenticatedGET network error: %@", error.localizedDescription);
                completion(nil, error);
                return;
            }
            NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
            DDLogInfo(@"[LocationAPISyncService] performAuthenticatedGET: HTTP %ld (%lu bytes) for %@",
                      (long)status, (unsigned long)data.length, url);
            if (status == 401) {
                DDLogInfo(@"[LocationAPISyncService] performAuthenticatedGET: 401 — refreshing token and retrying %@", url);
                __strong typeof(wself) sself2 = wself;
                if (!sself2) {
                    completion(nil, [NSError errorWithDomain:@"LocationAPISyncService" code:401 userInfo:nil]);
                    return;
                }
                [sself2 obtainAccessTokenForLocationAPIWithCompletion:^(NSString * _Nullable newToken) {
                    if (!newToken.length) {
                        DDLogWarn(@"[LocationAPISyncService] performAuthenticatedGET: 401 retry — could not refresh token for %@", url);
                        completion(nil, [NSError errorWithDomain:@"LocationAPISyncService" code:401 userInfo:nil]);
                        return;
                    }
                    DDLogInfo(@"[LocationAPISyncService] performAuthenticatedGET: retrying GET %@", url);
                    NSMutableURLRequest *retry = [NSMutableURLRequest requestWithURL:url];
                    retry.HTTPMethod = @"GET";
                    [retry setValue:@"application/json" forHTTPHeaderField:@"Accept"];
                    [retry setValue:[NSString stringWithFormat:@"Bearer %@", newToken] forHTTPHeaderField:@"Authorization"];
                    [[[NSURLSession sharedSession] dataTaskWithRequest:retry
                                                    completionHandler:^(NSData * _Nullable d2, NSURLResponse * _Nullable r2, NSError * _Nullable e2) {
                        NSInteger s2 = [r2 isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)r2 statusCode] : 0;
                        DDLogInfo(@"[LocationAPISyncService] performAuthenticatedGET: retry HTTP %ld (%lu bytes) for %@",
                                  (long)s2, (unsigned long)d2.length, url);
                        if (e2 || s2 != 200) {
                            DDLogWarn(@"[LocationAPISyncService] performAuthenticatedGET: retry failed HTTP %ld error %@ for %@",
                                      (long)s2, e2.localizedDescription, url);
                            completion(nil, e2 ?: [NSError errorWithDomain:@"LocationAPISyncService" code:s2 userInfo:nil]);
                        } else {
                            completion(d2, nil);
                        }
                    }] resume];
                }];
                return;
            }
            if (status != 200) {
                DDLogWarn(@"[LocationAPISyncService] performAuthenticatedGET HTTP %ld for %@", (long)status, url);
                completion(nil, [NSError errorWithDomain:@"LocationAPISyncService" code:status userInfo:nil]);
                return;
            }
            completion(data, nil);
        }] resume];
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
    [req setValue:[NSString stringWithFormat:@"Bearer %@", accessToken] forHTTPHeaderField:@"Authorization"];

    __weak typeof(self) wself = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
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
