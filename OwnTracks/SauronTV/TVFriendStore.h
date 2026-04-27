//
//  TVFriendStore.h
//  SauronTV
//
//  Singleton that owns all MQTT-driven friend state for the tvOS app.
//  Both TVMapViewController and TVFriendsViewController read from this store
//  and observe TVFriendStoreDidUpdateNotification to know when to refresh.
//

#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

@class TVLocationAPIDevice;

/// Posted on the main thread whenever friend data changes.
/// userInfo keys:
///   @"topic"  — NSString, the affected MQTT topic (optional for bulk @"allowlist")
///   @"change" — @"new" | @"location" | @"image" | @"card" | @"allowlist"
extern NSString * const TVFriendStoreDidUpdateNotification;

@interface TVFriendStore : NSObject

+ (instancetype)shared;

/// Call once from TVAppDelegate after the window is set up.
/// Loads disk-cached card images and starts observing MQTT notifications.
- (void)start;

/// Topics sorted A→Z by display label.
@property (nonatomic, readonly) NSArray<NSString *> *friendTopics;

/// topic → display label (API deviceName when available, else tid / last path component)
@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *friendLabels;

/// topic → last-seen time string (short time style)
@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *friendTimes;

/// topic → circular 60pt UIImage decoded from card face
@property (nonatomic, readonly) NSDictionary<NSString *, UIImage *> *friendImages;

/// topic → NSValue wrapping CLLocationCoordinate2D
@property (nonatomic, readonly) NSDictionary<NSString *, NSValue *> *friendCoords;

/// Base MQTT topics from the last successful GET /api/location (authoritative allowlist).
@property (nonatomic, readonly, copy) NSArray<NSString *> *allowedBaseMQTTTopics;

/// Returns the stored photo for topic, or a blue-circle placeholder with the friend's initials.
- (UIImage *)imageForTopic:(NSString *)topic;

/// Returns the Unix-epoch timestamp (seconds) of the most recent location fix,
/// or 0 if unknown.
- (NSTimeInterval)rawTimestampForTopic:(NSString *)topic;

/// Strips /info, /event, etc. so the key matches API mqttTopic.
+ (NSString *)baseMQTTTopicFromMessageTopic:(NSString *)topic;

/// Whether the base topic is in the current API allowlist (NO until first apply).
- (BOOL)isBaseTopicAllowed:(NSString *)baseTopic;

/// Replaces allowlist and friend rows from GET /api/location. Posts change @"allowlist".
- (void)applyLocationAPIDevices:(NSArray<TVLocationAPIDevice *> *)devices;

@end

NS_ASSUME_NONNULL_END
