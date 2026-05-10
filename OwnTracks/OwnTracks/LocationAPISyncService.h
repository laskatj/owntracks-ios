//
//  LocationAPISyncService.h
//  OwnTracks
//
//  Fetches GET {origin}/api/location with Web App OAuth and applies positions via OwnTracking (API-authoritative).
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main queue after a new OAuth access token is obtained (PKCE exchange or silent refresh).
/// `LocationAPISyncService` observes this to run native `POST /api/config/provision` when needed, without the Web tab.
FOUNDATION_EXPORT NSNotificationName const OwnTracksOAuthAccessTokenBecameAvailableNotification;
FOUNDATION_EXPORT NSString * const OTLocationDeleteErrorCodeKey;
FOUNDATION_EXPORT NSString * const OTLocationDeleteErrorReferenceCountKey;
FOUNDATION_EXPORT NSString * const OTLocationDeleteErrorMessageKey;

/// Posted on the main queue when `GET /api/geolocationcache` succeeds and the in-memory cache is updated.
FOUNDATION_EXPORT NSNotificationName const OwnTracksGeolocationCacheDidUpdateNotification;

/// Posted on the main queue after `GET /api/authorization/user` payload is applied (or cleared on logout).
FOUNDATION_EXPORT NSNotificationName _Nonnull const OwnTracksCurrentUserProfileDidUpdateNotification;

@interface OTWebLocationItem : NSObject
@property (nonatomic) NSInteger locationId;
@property (nonatomic) double latitude;
@property (nonatomic) double longitude;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy, nullable) NSString *originalDisplayName;
@property (nonatomic, copy, nullable) NSString *mapsUrl;
@property (nonatomic, strong) NSDate *createdAt;
@property (nonatomic, strong) NSDate *lastAccessed;
@property (nonatomic, copy, nullable) NSString *sourceType;
@property (nonatomic, strong, nullable) NSNumber *radius;
@property (nonatomic, copy, nullable) NSString *sourceDeviceName;
@end

@interface OTWebNotificationItem : NSObject
@property (nonatomic) NSInteger notificationIdValue;
@property (nonatomic) NSInteger userId;
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, copy, nullable) NSString *dataString;
@property (nonatomic, strong, nullable) NSDictionary *dataDictionary;
@property (nonatomic, copy) NSString *notificationId;
@property (nonatomic) BOOL isRead;
@property (nonatomic, strong) NSDate *createdAt;
@property (nonatomic, strong, nullable) NSDate *readAt;
@end

@interface OTWebNotificationsPage : NSObject
@property (nonatomic, strong) NSArray<OTWebNotificationItem *> *notifications;
@property (nonatomic) NSInteger totalCount;
@property (nonatomic) NSInteger skip;
@property (nonatomic) NSInteger take;
@end

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

/// GET /api/geolocationcache
- (void)fetchGeolocationCacheWithCompletion:(void (^)(NSArray<OTWebLocationItem *> * _Nullable locations,
                                                      NSError * _Nullable error))completion;

/// Debounced prefetch of geolocation cache (Friends tab, foreground). Safe to call often.
- (void)requestGeolocationCachePrefetchIfAppropriate;

/// Best eligible cached location whose circle contains `coordinate` (excludes `Destination` and `+follow` names). Main-thread use recommended.
- (nullable OTWebLocationItem *)geolocationItemContainingCoordinate:(CLLocationCoordinate2D)coordinate;

/// DELETE /api/geolocationcache/{id}[?replacementZoneId=...]
- (void)deleteGeolocationCacheLocationId:(NSInteger)locationId
                       replacementZoneId:(nullable NSNumber *)replacementZoneId
                              completion:(void (^)(NSInteger updatedReferences,
                                                   NSNumber * _Nullable echoedReplacementZoneId,
                                                   NSError * _Nullable error))completion;

/// GET /api/notifications with parity pagination and filters.
- (void)fetchNotificationsWithSkip:(NSInteger)skip
                              take:(NSInteger)take
                       includeRead:(BOOL)includeRead
                              type:(nullable NSString *)type
                        completion:(void (^)(OTWebNotificationsPage * _Nullable page,
                                             NSError * _Nullable error))completion;

/// GET /api/notifications/unread-count
- (void)fetchUnreadNotificationCountWithCompletion:(void (^)(NSInteger count,
                                                             NSError * _Nullable error))completion;

/// PUT /api/notifications/{id}/read
- (void)markNotificationRead:(NSInteger)notificationId completion:(void (^)(NSError * _Nullable error))completion;

/// PUT /api/notifications/read-all
- (void)markAllNotificationsReadWithCompletion:(void (^)(NSError * _Nullable error))completion;

/// PUT /api/notifications/bulk-read { notificationIds: [...] }
- (void)bulkMarkNotificationsRead:(NSArray<NSNumber *> *)notificationIds
                       completion:(void (^)(NSError * _Nullable error))completion;

/// PUT /api/notifications/{id}/unread
- (void)markNotificationUnread:(NSInteger)notificationId completion:(void (^)(NSError * _Nullable error))completion;

/// PUT /api/notifications/bulk-unread { notificationIds: [...] }
- (void)bulkMarkNotificationsUnread:(NSArray<NSNumber *> *)notificationIds
                         completion:(void (^)(NSError * _Nullable error))completion;

/// DELETE /api/notifications/{id}
- (void)deleteNotification:(NSInteger)notificationId completion:(void (^)(NSError * _Nullable error))completion;

/// DELETE /api/notifications/bulk { notificationIds: [...] }
- (void)bulkDeleteNotifications:(NSArray<NSNumber *> *)notificationIds
                     completion:(void (^)(NSError * _Nullable error))completion;

/// When the app still needs remote device configuration, POST `/api/config/provision` with Bearer auth
/// and apply the JSON response via `OwnTracksAppDelegate configFromDictionary:` on the main queue.
/// Completion is called on an arbitrary background thread: `applied` YES if configuration was applied.
- (void)provisionRemoteDeviceConfigurationIfNeededWithCompletion:(void (^)(BOOL applied, NSError * _Nullable error))completion;

/// Clears cached access token, discovery client id hint, and in-flight GET state after Keychain OAuth purge.
- (void)invalidateOAuthCredentialCache;

/// Applies JSON from `GET /api/authorization/user` (keys: \c isAdmin, \c canViewRouteHistory, \c homeZoneId, \c workZoneId). Main-thread only; posts \c OwnTracksCurrentUserProfileDidUpdateNotification.
- (void)updateFromAuthorizationUserAPIPayload:(NSDictionary *)json;

/// YES after a successful parse of `/api/authorization/user` this session (until \c invalidateOAuthCredentialCache).
- (BOOL)hasAuthorizationUserProfilePayload;

/// `isAdmin` from the last authorization user response (meaningful only if \c hasAuthorizationUserProfilePayload).
- (BOOL)currentUserIsAdminFromAuthorizationAPI;

/// Route history (Recorder REST window) allowed. If no profile loaded yet, returns YES (legacy). After profile load, uses \c canViewRouteHistory (defaults to YES if key absent).
- (BOOL)currentUserMayViewRouteHistory;

/// Home / work zone ids from the last authorization user response; nil if absent or null in JSON.
- (nullable NSNumber *)authorizationUserHomeZoneId;
- (nullable NSNumber *)authorizationUserWorkZoneId;

/// Sensitive device UI (e.g. MQTT topic): if \c hasAuthorizationUserProfilePayload, uses API \c isAdmin; else JWT \c claimsIndicateLocationAdmin:. \c OTForceLocationAdminForDeviceDetail forces YES.
- (BOOL)currentUserMayViewSensitiveLocationDeviceFields;

/// Discovery `client_id` from owntracks-app-auth this session, if already fetched; used when purging Keychain.
- (nullable NSString *)peekCachedDiscoveryOAuthClientId;

/// Same ordering as Keychain silent refresh: discovery id, settings id if different, then `NSNull` for nil-client lookup.
+ (NSArray *)orderedKeychainClientIdChainDiscovery:(nullable NSString *)discoveryClientId settings:(nullable NSString *)clientPref;

/// Same silent refresh pipeline as authenticated REST APIs (Bearer token resolution).
- (void)obtainOAuthAccessTokenForAPICallsWithCompletion:(void (^)(NSString * _Nullable token))completion;

/// Registers or updates this device token for inbox push notifications (POST `/api/push/devices/apns`).
- (void)registerApnsDeviceTokenHex:(NSString *)hexString
                           sandbox:(BOOL)sandbox
                        completion:(void (^)(NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
