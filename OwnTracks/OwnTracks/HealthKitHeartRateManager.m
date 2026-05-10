//
//  HealthKitHeartRateManager.m
//  OwnTracks
//
//  Copyright © 2025 OwnTracks. All rights reserved.
//

#import "HealthKitHeartRateManager.h"
#import <CocoaLumberjack/CocoaLumberjack.h>

NSNotificationName const OTHealthKitHeartRateDidUpdateNotification = @"OTHealthKitHeartRateDidUpdateNotification";

static const NSTimeInterval kHeartRateMaxAge = 30.0;

@interface HealthKitHeartRateManager ()
@property (nonatomic, strong) HKHealthStore *store;
@property (nonatomic, strong, nullable) NSNumber *_heartRate;
@property (nonatomic, strong, nullable) NSDate *_lastReadingDate;
@property (nonatomic, strong, nullable) HKObserverQuery *observerQuery;
@property (nonatomic, assign) BOOL observing;
/// Set by \c stopObserving so an in-flight \c requestAuthorization completion does not attach an observer.
@property (nonatomic, assign) BOOL observationStartCancelled;
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

- (nullable NSNumber *)heartRateIfSampleWithin:(NSTimeInterval)maxSampleAge {
    if (!self._heartRate || !self._lastReadingDate) {
        return nil;
    }
    if (maxSampleAge <= 0.0) {
        return self._heartRate;
    }
    if (-self._lastReadingDate.timeIntervalSinceNow > maxSampleAge) {
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

    self.observationStartCancelled = NO;
    HKQuantityType *hrType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierHeartRate];
    NSSet *readTypes = [NSSet setWithObject:hrType];

    __weak typeof(self) weakSelf = self;
    [self.store requestAuthorizationToShareTypes:nil
                                       readTypes:readTypes
                                      completion:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            if (strongSelf.observationStartCancelled) {
                DDLogInfo(@"[HKHRM] observation start cancelled before auth completed");
                return;
            }
            if (!success) {
                DDLogError(@"[HKHRM] HealthKit authorization denied: %@", error.localizedDescription);
                return;
            }
            DDLogInfo(@"[HKHRM] HealthKit authorization granted");
            [strongSelf _setupObserver];
        });
    }];
}

- (void)stopObserving {
    self.observationStartCancelled = YES;
    if (!self.observing && !self.observerQuery) {
        return;
    }
    HKQuantityType *hrType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierHeartRate];
    [self.store disableBackgroundDeliveryForType:hrType
                                  withCompletion:^(BOOL success, NSError *error) {
        if (!success && error) {
            DDLogError(@"[HKHRM] disableBackgroundDelivery failed: %@", error.localizedDescription);
        }
    }];
    if (self.observerQuery) {
        [self.store stopQuery:self.observerQuery];
        self.observerQuery = nil;
    }
    self.observing = NO;
    self._heartRate = nil;
    self._lastReadingDate = nil;
    DDLogInfo(@"[HKHRM] stopObserving");
    [[NSNotificationCenter defaultCenter] postNotificationName:OTHealthKitHeartRateDidUpdateNotification
                                                        object:self];
}

#pragma mark - Private

- (void)_setupObserver {
    if (self.observationStartCancelled) {
        return;
    }
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
            [weakSelf _fetchLatestSampleWithObserverCompletion:completionHandler onFinished:nil];
        }];

    self.observerQuery = observerQuery;
    [self.store executeQuery:observerQuery];

    // Fetch once immediately so we have a value before the first observer fires.
    [self _fetchLatestSampleWithObserverCompletion:nil onFinished:nil];
}

- (void)refreshLatestSampleForUIWithCompletion:(nullable dispatch_block_t)completion {
    [self _fetchLatestSampleWithObserverCompletion:nil onFinished:completion];
}

- (void)_fetchLatestSampleWithObserverCompletion:(nullable HKObserverQueryCompletionHandler)completionHandler
                                      onFinished:(nullable dispatch_block_t)onFinished {
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
                if (completionHandler) {
                    completionHandler();
                }
                if (onFinished) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        onFinished();
                    });
                }
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

            if (completionHandler) {
                completionHandler();
            }
            [[NSNotificationCenter defaultCenter] postNotificationName:OTHealthKitHeartRateDidUpdateNotification
                                                                  object:self];
            if (onFinished) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    onFinished();
                });
            }
        }];

    [self.store executeQuery:sampleQuery];
}

- (void)fetchHeartRateSamplesFromDate:(NSDate *)startDate
                               toDate:(NSDate *)endDate
                           completion:(void (^)(NSArray<NSDictionary *> * _Nullable, NSError * _Nullable))completion {
    if (!completion) {
        return;
    }
    void (^deliver)(NSArray<NSDictionary *> *, NSError *) = ^(NSArray<NSDictionary *> *rows, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(rows, err);
        });
    };
    if (![HKHealthStore isHealthDataAvailable]) {
        deliver(@[], nil);
        return;
    }
    if (!startDate || !endDate || [startDate compare:endDate] != NSOrderedAscending) {
        deliver(@[], nil);
        return;
    }

    HKQuantityType *hrType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierHeartRate];
    NSPredicate *pred = [HKQuery predicateForSamplesWithStartDate:startDate endDate:endDate options:0];
    NSSortDescriptor *asc = [NSSortDescriptor sortDescriptorWithKey:HKSampleSortIdentifierEndDate ascending:YES];
    HKSampleQuery *query =
        [[HKSampleQuery alloc] initWithSampleType:hrType
                                        predicate:pred
                                            limit:HKObjectQueryNoLimit
                                  sortDescriptors:@[asc]
                                   resultsHandler:^(HKSampleQuery *q,
                                                    NSArray<__kindof HKSample *> *results,
                                                    NSError *error) {
            if (error) {
                DDLogError(@"[HKHRM] history query error: %@", error.localizedDescription);
                deliver(@[], error);
                return;
            }
            NSUInteger n = results.count;
            NSMutableArray<NSDictionary *> *rows = [NSMutableArray arrayWithCapacity:MIN(n, (NSUInteger)400)];
            HKUnit *bpmUnit = [[HKUnit countUnit] unitDividedByUnit:[HKUnit minuteUnit]];
            const NSUInteger kMaxChartPoints = 400;
            NSUInteger step = (n <= kMaxChartPoints) ? 1 : MAX(1, (n + kMaxChartPoints - 1) / kMaxChartPoints);
            for (NSUInteger i = 0; i < n; i += step) {
                HKQuantitySample *s = (HKQuantitySample *)results[i];
                double bpm = [s.quantity doubleValueForUnit:bpmUnit];
                [rows addObject:@{ @"date": s.endDate, @"bpm": @(bpm) }];
            }
            if (n > 0) {
                HKQuantitySample *last = (HKQuantitySample *)results[n - 1];
                NSDictionary *lastRow = @{ @"date": last.endDate,
                                           @"bpm": @([last.quantity doubleValueForUnit:bpmUnit]) };
                NSDictionary *prev = rows.lastObject;
                if (!prev || ![prev[@"date"] isEqual:lastRow[@"date"]]) {
                    [rows addObject:lastRow];
                }
            }
            DDLogVerbose(@"[HKHRM] history %lu samples → %lu chart points", (unsigned long)n, (unsigned long)rows.count);
            deliver(rows, nil);
        }];
    [self.store executeQuery:query];
}

@end
