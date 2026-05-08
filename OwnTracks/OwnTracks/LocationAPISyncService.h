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
FOUNDATION_EXPORT NSString * const OTLocationDeleteErrorCodeKey;
FOUNDATION_EXPORT NSString * const OTLocationDeleteErrorReferenceCountKey;
FOUNDATION_EXPORT NSString * const OTLocationDeleteErrorMessageKey;

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

/// Discovery `client_id` from owntracks-app-auth this session, if already fetched; used when purging Keychain.
- (nullable NSString *)peekCachedDiscoveryOAuthClientId;

/// Same ordering as Keychain silent refresh: discovery id, settings id if different, then `NSNull` for nil-client lookup.
+ (NSArray *)orderedKeychainClientIdChainDiscovery:(nullable NSString *)discoveryClientId settings:(nullable NSString *)clientPref;

@end

NS_ASSUME_NONNULL_END
