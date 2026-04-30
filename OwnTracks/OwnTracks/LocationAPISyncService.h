//
//  LocationAPISyncService.h
//  OwnTracks
//
//  Fetches GET {origin}/api/location with Web App OAuth and applies positions via OwnTracking (API-authoritative).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main queue after a new OAuth access token is obtained (PKCE exchange or silent refresh).
/// `LocationAPISyncService` observes this to run native `POST /api/config/provision` when needed, without the Web tab.
FOUNDATION_EXPORT NSNotificationName const OwnTracksOAuthAccessTokenBecameAvailableNotification;

@interface LocationAPISyncService : NSObject

+ (instancetype)sharedInstance;

/// Registers for foreground/background notifications. Safe to call once from application:didFinishLaunchingWithOptions:.
- (void)start;

/// Triggers GET /api/location when not already in flight and the last successful fetch is older than a short debounce (e.g. Friends tab pull-to-refresh on appear).
- (void)requestLocationRefreshIfAppropriate;

/// Makes an authenticated GET to `url`, obtaining and refreshing the OAuth token as needed.
/// Completion is called on an arbitrary background thread with the raw response data or an error.
- (void)performAuthenticatedGET:(NSURL *)url
                     completion:(void (^)(NSData * _Nullable data, NSError * _Nullable error))completion;

/// When the app still needs remote device configuration, POST `/api/config/provision` with Bearer auth
/// and apply the JSON response via `OwnTracksAppDelegate configFromDictionary:` on the main queue.
/// Completion is called on an arbitrary background thread: `applied` YES if configuration was applied.
- (void)provisionRemoteDeviceConfigurationIfNeededWithCompletion:(void (^)(BOOL applied, NSError * _Nullable error))completion;

/// Clears cached access token, discovery client id hint, and in-flight GET state after Keychain OAuth purge.
- (void)invalidateOAuthCredentialCache;

/// Discovery `client_id` from owntracks-app-auth this session, if already fetched; used when purging Keychain.
- (nullable NSString *)peekCachedDiscoveryOAuthClientId;

/// Same ordering as Keychain silent refresh: discovery id, settings id if different, then `NSNull` for nil-client lookup.
+ (NSArray *)orderedKeychainClientIdChainDiscovery:(nullable NSString *)discoveryClientId settings:(nullable NSString *)clientPref;

@end

NS_ASSUME_NONNULL_END
