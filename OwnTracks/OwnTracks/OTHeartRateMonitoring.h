//
//  OTHeartRateMonitoring.h
//  OwnTracks
//
//  Copyright © 2025 OwnTracks. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName _Nonnull const OTHeartRateMonitoringEnabledDidChangeNotification;

/// User preference: heart rate sensors (BLE + HealthKit observer). Default is OFF when the key is absent.
FOUNDATION_EXPORT NSString * const OTHeartRateMonitoringEnabledDefaultsKey;

typedef NS_ENUM(NSInteger, OTHeartRateSource) {
    OTHeartRateSourceNone = 0,
    OTHeartRateSourceBluetooth,
    OTHeartRateSourceHealthKit,
};

/// Central place for HR monitoring preference and resolving BPM for UI / waypoints (matches waypoint logic).
@interface OTHeartRateMonitoring : NSObject

+ (BOOL)isMonitoringEnabled;

+ (void)setMonitoringEnabled:(BOOL)enabled;

/// Applies current \c NSUserDefaults value (call from \c application:didFinishLaunchingWithOptions:).
+ (void)applyCurrentPreference;

/// Same order as waypoint assembly: fresh BLE, BLE within \p maxSampleAge, fresh HK, HK within \p maxSampleAge.
+ (nullable NSNumber *)resolvedHeartRateBPMWithMaxSampleAge:(NSTimeInterval)maxSampleAge
                                                    outSource:(OTHeartRateSource * _Nullable)outSource;

@end

NS_ASSUME_NONNULL_END
