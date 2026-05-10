//
//  OTHeartRateMonitoring.m
//  OwnTracks
//
//  Copyright © 2025 OwnTracks. All rights reserved.
//

#import "OTHeartRateMonitoring.h"
#import "BluetoothHeartRateManager.h"
#import "HealthKitHeartRateManager.h"

NSNotificationName const OTHeartRateMonitoringEnabledDidChangeNotification =
    @"OTHeartRateMonitoringEnabledDidChangeNotification";

NSString * const OTHeartRateMonitoringEnabledDefaultsKey = @"OTHeartRateMonitoringEnabled";

@implementation OTHeartRateMonitoring

+ (BOOL)isMonitoringEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:OTHeartRateMonitoringEnabledDefaultsKey];
}

+ (void)setMonitoringEnabled:(BOOL)enabled {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    [defs setBool:enabled forKey:OTHeartRateMonitoringEnabledDefaultsKey];
    [self applyEnabled:enabled];
    [[NSNotificationCenter defaultCenter] postNotificationName:OTHeartRateMonitoringEnabledDidChangeNotification
                                                        object:nil];
}

+ (void)applyCurrentPreference {
    [self applyEnabled:[self isMonitoringEnabled]];
}

+ (void)applyEnabled:(BOOL)enabled {
    if (enabled) {
        [[BluetoothHeartRateManager sharedInstance] startScanning];
        [[HealthKitHeartRateManager sharedInstance] startObserving];
    } else {
        [[BluetoothHeartRateManager sharedInstance] stopScanning];
        [[HealthKitHeartRateManager sharedInstance] stopObserving];
    }
}

+ (nullable NSNumber *)resolvedHeartRateBPMWithMaxSampleAge:(NSTimeInterval)maxSampleAge
                                                  outSource:(OTHeartRateSource *)outSource {
    NSNumber *heartRate = [BluetoothHeartRateManager sharedInstance].heartRate;
    if (!heartRate) {
        heartRate = [[BluetoothHeartRateManager sharedInstance] heartRateIfSampleWithin:maxSampleAge];
    }
    if (heartRate && heartRate.intValue > 0) {
        if (outSource) {
            *outSource = OTHeartRateSourceBluetooth;
        }
        return heartRate;
    }
    heartRate = [HealthKitHeartRateManager sharedInstance].heartRate;
    if (!heartRate) {
        heartRate = [[HealthKitHeartRateManager sharedInstance] heartRateIfSampleWithin:maxSampleAge];
    }
    if (heartRate && heartRate.intValue > 0) {
        if (outSource) {
            *outSource = OTHeartRateSourceHealthKit;
        }
        return heartRate;
    }
    if (outSource) {
        *outSource = OTHeartRateSourceNone;
    }
    return nil;
}

@end
