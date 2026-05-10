//
//  HealthKitHeartRateManager.h
//  OwnTracks
//
//  Copyright © 2025 OwnTracks. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <HealthKit/HealthKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Reads the most recent heart rate sample from HealthKit (written there by Apple Watch).
/// Used as a fallback when no Bluetooth heart rate monitor is connected.
///
/// Readings older than 30 s are considered stale and treated as unavailable.
@interface HealthKitHeartRateManager : NSObject

+ (HealthKitHeartRateManager *)sharedInstance;

/// Most recently received heart rate in beats per minute, or nil if HealthKit is
/// unavailable, permission is denied, or the most recent sample is older than 30 s.
@property (nonatomic, readonly, nullable) NSNumber *heartRate;

/// Timestamp of the most recent HealthKit HR sample, or nil.
@property (nonatomic, readonly, nullable) NSDate *lastReadingDate;

/// Request HealthKit authorization and start observing HR samples.  Safe to call
/// multiple times; subsequent calls are no-ops once authorized.
- (void)startObserving;

@end

NS_ASSUME_NONNULL_END
