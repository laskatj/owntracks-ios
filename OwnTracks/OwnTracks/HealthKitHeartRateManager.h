//
//  HealthKitHeartRateManager.h
//  OwnTracks
//
//  Copyright © 2025 OwnTracks. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <HealthKit/HealthKit.h>

FOUNDATION_EXPORT NSNotificationName _Nonnull const OTHealthKitHeartRateDidUpdateNotification;

NS_ASSUME_NONNULL_BEGIN

/// Reads the most recent heart rate sample from HealthKit (written there by Apple Watch).
/// Used as a fallback when no Bluetooth heart rate monitor is connected.
///
/// Readings older than 30 s are considered stale for the \c heartRate property.
@interface HealthKitHeartRateManager : NSObject

+ (HealthKitHeartRateManager *)sharedInstance;

/// Most recently received heart rate in beats per minute, or nil if HealthKit is
/// unavailable, permission is denied, or the most recent sample is older than 30 s.
@property (nonatomic, readonly, nullable) NSNumber *heartRate;

/// Same as the last fetched sample if its end date is within \p maxSampleAge seconds
/// of now. Use a larger window (e.g. 15 minutes) for location payloads: Apple Watch
/// often records heart rate less frequently than every 30 s when idle.
- (nullable NSNumber *)heartRateIfSampleWithin:(NSTimeInterval)maxSampleAge
    NS_SWIFT_NAME(heartRateIfSample(within:));

/// Timestamp of the most recent HealthKit HR sample, or nil.
@property (nonatomic, readonly, nullable) NSDate *lastReadingDate;

/// Request HealthKit authorization and start observing HR samples.  Safe to call
/// multiple times; subsequent calls are no-ops once authorized.
- (void)startObserving;

/// Stops observer query and background delivery; clears cached HR. Safe to call when not observing.
- (void)stopObserving;

/// Re-queries HealthKit for the latest heart rate sample (e.g. when opening a UI).
/// \p completion is always invoked on the main queue when the query finishes.
- (void)refreshLatestSampleForUIWithCompletion:(nullable dispatch_block_t)completion
    NS_SWIFT_NAME(refreshLatestSampleForUI(completion:));

/// Heart rate samples between \p startDate and \p endDate (typically last 12 hours). Each entry is
/// \c @{ @"date": NSDate (sample end), @"bpm": NSNumber (double) }. Downsampled for chart performance.
/// \p completion is always invoked on the main queue.
- (void)fetchHeartRateSamplesFromDate:(NSDate *)startDate
                               toDate:(NSDate *)endDate
                           completion:(void (^)(NSArray<NSDictionary *> * _Nullable samples, NSError * _Nullable error))completion
    NS_SWIFT_NAME(fetchHeartRateSamples(from:to:completion:));

@end

NS_ASSUME_NONNULL_END
