//
//  HealthKitHeartRateManager.m
//  OwnTracks
//
//  Copyright © 2025 OwnTracks. All rights reserved.
//

#import "HealthKitHeartRateManager.h"
#import <CocoaLumberjack/CocoaLumberjack.h>

static const NSTimeInterval kHeartRateMaxAge = 30.0;

@interface HealthKitHeartRateManager ()
@property (nonatomic, strong) HKHealthStore *store;
@property (nonatomic, strong, nullable) NSNumber *_heartRate;
@property (nonatomic, strong, nullable) NSDate *_lastReadingDate;
@property (nonatomic, assign) BOOL observing;
@end

@implementation HealthKitHeartRateManager

static const DDLogLevel ddLogLevel = DDLogLevelInfo;
static HealthKitHeartRateManager *theInstance = nil;

+ (HealthKitHeartRateManager *)sharedInstance {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        theInstance = [[HealthKitHeartRateManager alloc] init];
    });
    return theInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _store = [[HKHealthStore alloc] init];
    }
    return self;
}

#pragma mark - Public API

- (nullable NSNumber *)heartRate {
    if (!self._heartRate || !self._lastReadingDate) {
        return nil;
    }
    if (-self._lastReadingDate.timeIntervalSinceNow > kHeartRateMaxAge) {
        return nil;
    }
    return self._heartRate;
}

- (nullable NSDate *)lastReadingDate {
    return self._lastReadingDate;
}

- (void)startObserving {
    if (![HKHealthStore isHealthDataAvailable]) {
        DDLogInfo(@"[HKHRM] HealthKit not available on this device");
        return;
    }
    if (self.observing) {
        return;
    }

    HKQuantityType *hrType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierHeartRate];
    NSSet *readTypes = [NSSet setWithObject:hrType];

    [self.store requestAuthorizationToShareTypes:nil
                                       readTypes:readTypes
                                      completion:^(BOOL success, NSError *error) {
        if (!success) {
            DDLogError(@"[HKHRM] HealthKit authorization denied: %@", error.localizedDescription);
            return;
        }
        DDLogInfo(@"[HKHRM] HealthKit authorization granted");
        [self _setupObserver];
    }];
}

#pragma mark - Private

- (void)_setupObserver {
    self.observing = YES;
    HKQuantityType *hrType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierHeartRate];

    // Wake the app in the background when Apple Watch syncs new HR samples.
    [self.store enableBackgroundDeliveryForType:hrType
                                      frequency:HKUpdateFrequencyImmediate
                                 withCompletion:^(BOOL success, NSError *error) {
        if (!success) {
            DDLogError(@"[HKHRM] background delivery enable failed: %@", error.localizedDescription);
        }
    }];

    __weak typeof(self) weakSelf = self;
    HKObserverQuery *observerQuery =
        [[HKObserverQuery alloc] initWithSampleType:hrType
                                          predicate:nil
                                     updateHandler:^(HKObserverQuery *query,
                                                     HKObserverQueryCompletionHandler completionHandler,
                                                     NSError *error) {
            if (error) {
                DDLogError(@"[HKHRM] observer error: %@", error.localizedDescription);
                if (completionHandler) completionHandler();
                return;
            }
            [weakSelf _fetchLatestSampleWithCompletion:completionHandler];
        }];

    [self.store executeQuery:observerQuery];

    // Fetch once immediately so we have a value before the first observer fires.
    [self _fetchLatestSampleWithCompletion:nil];
}

- (void)_fetchLatestSampleWithCompletion:(nullable HKObserverQueryCompletionHandler)completionHandler {
    HKQuantityType *hrType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierHeartRate];
    NSSortDescriptor *mostRecent = [NSSortDescriptor sortDescriptorWithKey:HKSampleSortIdentifierStartDate
                                                                 ascending:NO];
    HKSampleQuery *sampleQuery =
        [[HKSampleQuery alloc] initWithSampleType:hrType
                                        predicate:nil
                                            limit:1
                                  sortDescriptors:@[mostRecent]
                                   resultsHandler:^(HKSampleQuery *query,
                                                    NSArray<__kindof HKSample *> *results,
                                                    NSError *error) {
            if (error) {
                DDLogError(@"[HKHRM] sample query error: %@", error.localizedDescription);
                if (completionHandler) completionHandler();
                return;
            }

            HKQuantitySample *sample = results.firstObject;
            if (sample) {
                HKUnit *bpmUnit = [[HKUnit countUnit] unitDividedByUnit:[HKUnit minuteUnit]];
                double bpm = [sample.quantity doubleValueForUnit:bpmUnit];
                self._heartRate = @((NSInteger)round(bpm));
                self._lastReadingDate = sample.endDate;
                DDLogVerbose(@"[HKHRM] heart rate: %@ bpm (sample at %@)",
                             self._heartRate, sample.endDate);
            }

            if (completionHandler) completionHandler();
        }];

    [self.store executeQuery:sampleQuery];
}

@end
