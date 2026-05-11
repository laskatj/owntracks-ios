//
//  OTLocalHeartRateTimeSeriesStore.h
//  OwnTracks
//
//  Persists heart rate samples on disk (denser than MQTT waypoint cadence) for 12h metrics charts.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const OTLocalHeartRateSamplesDidUpdateNotification;

/// JSON-backed ring buffer (~24h) for BPM samples (foreground timer + BLE + HealthKit-driven writes).
@interface OTLocalHeartRateTimeSeriesStore : NSObject

+ (instancetype)shared;

/// Starts a ~25s timer when the app is active and `OTHeartRateMonitoring` is enabled; stops otherwise.
+ (void)startForegroundSampling;
+ (void)stopForegroundSampling;

/// Samples with `date` in `[start, end]` inclusive; each entry `@{ @"date": NSDate, @"bpm": NSNumber }`.
- (NSArray<NSDictionary *> *)samplesFromDate:(NSDate *)start toDate:(NSDate *)end;

/// Drops entries older than \p retainSeconds and caps count (call on launch).
- (void)trimRetainingLastSeconds:(NSTimeInterval)retainSeconds maxEntries:(NSInteger)maxEntries;

/// Registers UIApplication / HR preference / BLE / HealthKit notifications once (call from app delegate at launch).
+ (void)setupApplicationObservers;

@end

NS_ASSUME_NONNULL_END
