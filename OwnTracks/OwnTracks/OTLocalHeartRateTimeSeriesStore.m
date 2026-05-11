//
//  OTLocalHeartRateTimeSeriesStore.m
//  OwnTracks
//

#import "OTLocalHeartRateTimeSeriesStore.h"
#import "OTHeartRateMonitoring.h"
#import "BluetoothHeartRateManager.h"
#import "HealthKitHeartRateManager.h"
#import <UIKit/UIKit.h>

NSNotificationName const OTLocalHeartRateSamplesDidUpdateNotification = @"OTLocalHeartRateSamplesDidUpdateNotification";

static NSString *const kJSONFileName = @"OTLocalHeartRateSamples.json";
static const NSTimeInterval kDefaultRetainSeconds = 24 * 3600;
static const NSInteger kDefaultMaxEntries = 10000;
static const NSTimeInterval kForegroundTimerInterval = 25.0;
static NSString *const kSamplesKey = @"samples";
static const NSTimeInterval kBLELiveWallThrottleSeconds = 10.0;
static const NSTimeInterval kHealthKitSampleEndDedupeSeconds = 0.5;

@interface OTLocalHeartRateTimeSeriesStore ()
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *samples;
@property (nonatomic, strong) NSURL *fileURL;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@property (nonatomic, strong, nullable) NSDate *lastLiveWallThrottleDate;
@property (nonatomic, strong, nullable) NSDate *lastHealthKitLoggedSampleEndDate;
@end

static NSTimer *OTForegroundHRSampleTimer = nil;
static BOOL OTLocalHRStoreObserversRegistered = NO;

@implementation OTLocalHeartRateTimeSeriesStore

+ (void)setupApplicationObservers {
    if (OTLocalHRStoreObserversRegistered) {
        return;
    }
    OTLocalHRStoreObserversRegistered = YES;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSOperationQueue *mainQ = [NSOperationQueue mainQueue];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:mainQ
                usingBlock:^(__unused NSNotification *note) {
        [OTLocalHeartRateTimeSeriesStore startForegroundSampling];
    }];
    [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:mainQ
                usingBlock:^(__unused NSNotification *note) {
        [OTLocalHeartRateTimeSeriesStore stopForegroundSampling];
    }];
    [nc addObserverForName:OTHeartRateMonitoringEnabledDidChangeNotification object:nil queue:mainQ
                usingBlock:^(__unused NSNotification *note) {
        if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
            [OTLocalHeartRateTimeSeriesStore startForegroundSampling];
        } else {
            [OTLocalHeartRateTimeSeriesStore stopForegroundSampling];
        }
    }];
    [nc addObserverForName:OTBluetoothHeartRateDidUpdateNotification object:nil queue:mainQ
                usingBlock:^(__unused NSNotification *note) {
        if (![OTHeartRateMonitoring isMonitoringEnabled]) {
            return;
        }
        UIApplicationState st = [UIApplication sharedApplication].applicationState;
        if (st != UIApplicationStateActive && st != UIApplicationStateBackground) {
            return;
        }
        NSNumber *hr = [BluetoothHeartRateManager sharedInstance].heartRate;
        if (!hr || hr.integerValue <= 0) {
            hr = [[BluetoothHeartRateManager sharedInstance] heartRateIfSampleWithin:15 * 60];
        }
        if (hr.integerValue > 0) {
            [[OTLocalHeartRateTimeSeriesStore shared] appendLiveSampleWithBPM:hr.integerValue
                                                        wallThrottleInterval:kBLELiveWallThrottleSeconds];
        }
    }];
    [nc addObserverForName:OTHealthKitHeartRateDidUpdateNotification object:nil queue:nil
                usingBlock:^(NSNotification *note) {
        [[OTLocalHeartRateTimeSeriesStore shared] handleHealthKitHeartRateDidUpdateNotification:note];
    }];
}

+ (instancetype)shared {
    static OTLocalHeartRateTimeSeriesStore *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[self alloc] initPrivate];
    });
    return s;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _ioQueue = dispatch_queue_create("org.owntracks.OTLocalHeartRateTimeSeriesStore", DISPATCH_QUEUE_SERIAL);
        _samples = [NSMutableArray array];
        NSURL *base = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                             inDomains:NSUserDomainMask].firstObject;
        NSString *folder = @"OwnTracks";
        NSURL *dir = [base URLByAppendingPathComponent:folder isDirectory:YES];
        [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES
                                                  attributes:nil error:nil];
        _fileURL = [dir URLByAppendingPathComponent:kJSONFileName];
        dispatch_sync(self.ioQueue, ^{
            [self loadFromDiskUnsafe];
            [self trimUnsafeRetainingLastSeconds:kDefaultRetainSeconds maxEntries:kDefaultMaxEntries];
        });
    }
    return self;
}

- (instancetype)init {
    NSAssert(NO, @"Use +shared");
    return [self initPrivate];
}

#pragma mark - Disk (must run on ioQueue)

- (void)loadFromDiskUnsafe {
    NSData *data = [NSData dataWithContentsOfURL:self.fileURL];
    if (!data.length) {
        return;
    }
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSArray *arr = obj[kSamplesKey];
    if (![arr isKindOfClass:[NSArray class]]) {
        return;
    }
    [self.samples removeAllObjects];
    for (id row in arr) {
        if (![row isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSNumber *t = row[@"t"];
        NSNumber *bpm = row[@"bpm"] ?: row[@"b"];
        if (![t isKindOfClass:[NSNumber class]] || ![bpm isKindOfClass:[NSNumber class]]) {
            continue;
        }
        NSDate *d = [NSDate dateWithTimeIntervalSince1970:t.doubleValue];
        [self.samples addObject:@{ @"date": d, @"bpm": bpm }];
    }
}

- (void)saveToDiskUnsafe {
    NSMutableArray *jsonRows = [NSMutableArray arrayWithCapacity:self.samples.count];
    for (NSDictionary *row in self.samples) {
        NSDate *d = row[@"date"];
        NSNumber *bpm = row[@"bpm"];
        if (![d isKindOfClass:[NSDate class]] || ![bpm isKindOfClass:[NSNumber class]]) {
            continue;
        }
        [jsonRows addObject:@{ @"t": @([d timeIntervalSince1970]), @"bpm": @(bpm.integerValue) }];
    }
    NSDictionary *root = @{ kSamplesKey: jsonRows };
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingSortedKeys error:&err];
    if (!data.length) {
        return;
    }
    [data writeToURL:self.fileURL options:NSDataWritingAtomic error:nil];
}

- (void)trimUnsafeRetainingLastSeconds:(NSTimeInterval)retainSeconds maxEntries:(NSInteger)maxEntries {
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-retainSeconds];
    NSIndexSet *old = [self.samples indexesOfObjectsPassingTest:^BOOL(NSDictionary *obj, NSUInteger idx, BOOL *stop) {
        NSDate *d = obj[@"date"];
        if (![d isKindOfClass:[NSDate class]]) {
            return YES;
        }
        return [d compare:cutoff] == NSOrderedAscending;
    }];
    if (old.count) {
        [self.samples removeObjectsAtIndexes:old];
    }
    while (self.samples.count > maxEntries) {
        [self.samples removeObjectAtIndex:0];
    }
}

- (void)postSamplesDidUpdateOnMain {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:OTLocalHeartRateSamplesDidUpdateNotification
                                                            object:nil];
    });
}

#pragma mark - Public

- (NSArray<NSDictionary *> *)samplesFromDate:(NSDate *)start toDate:(NSDate *)end {
    if (!start || !end || [start compare:end] == NSOrderedDescending) {
        return @[];
    }
    __block NSArray<NSDictionary *> *out = @[];
    dispatch_sync(self.ioQueue, ^{
        NSMutableArray *acc = [NSMutableArray array];
        for (NSDictionary *row in self.samples) {
            NSDate *d = row[@"date"];
            if (![d isKindOfClass:[NSDate class]]) {
                continue;
            }
            if ([d compare:start] == NSOrderedAscending) {
                continue;
            }
            if ([d compare:end] == NSOrderedDescending) {
                continue;
            }
            [acc addObject:@{ @"date": d, @"bpm": row[@"bpm"] ?: @0 }];
        }
        out = acc;
    });
    return out;
}

- (void)trimRetainingLastSeconds:(NSTimeInterval)retainSeconds maxEntries:(NSInteger)maxEntries {
    dispatch_sync(self.ioQueue, ^{
        [self trimUnsafeRetainingLastSeconds:retainSeconds maxEntries:maxEntries];
        [self saveToDiskUnsafe];
    });
}

/// Foreground timer + BLE: sample time is wall clock; optional wall-clock throttle between writes.
- (void)appendLiveSampleWithBPM:(NSInteger)bpm wallThrottleInterval:(NSTimeInterval)wallMin {
    if (bpm <= 0) {
        return;
    }
    dispatch_async(self.ioQueue, ^{
        if (![OTHeartRateMonitoring isMonitoringEnabled]) {
            return;
        }
        NSDate *now = [NSDate date];
        if (wallMin > 0 && self.lastLiveWallThrottleDate) {
            if ([now timeIntervalSinceDate:self.lastLiveWallThrottleDate] < wallMin) {
                return;
            }
        }
        self.lastLiveWallThrottleDate = now;
        [self.samples addObject:@{ @"date": now, @"bpm": @(bpm) }];
        [self trimUnsafeRetainingLastSeconds:kDefaultRetainSeconds maxEntries:kDefaultMaxEntries];
        [self saveToDiskUnsafe];
        [self postSamplesDidUpdateOnMain];
    });
}

- (void)handleHealthKitHeartRateDidUpdateNotification:(NSNotification *)note {
    NSDictionary *ui = note.userInfo;
    if (![ui isKindOfClass:[NSDictionary class]] || ui.count == 0) {
        return;
    }
    id dObj = ui[OTHealthKitHeartRateUserInfoSampleEndDateKey];
    id bObj = ui[OTHealthKitHeartRateUserInfoBPMKey];
    if (![dObj isKindOfClass:[NSDate class]] || ![bObj isKindOfClass:[NSNumber class]]) {
        return;
    }
    NSDate *endDate = (NSDate *)dObj;
    NSInteger bpm = [(NSNumber *)bObj integerValue];
    dispatch_async(self.ioQueue, ^{
        if (![OTHeartRateMonitoring isMonitoringEnabled]) {
            return;
        }
        if (bpm <= 0) {
            return;
        }
        if (self.lastHealthKitLoggedSampleEndDate &&
            fabs([endDate timeIntervalSinceDate:self.lastHealthKitLoggedSampleEndDate]) < kHealthKitSampleEndDedupeSeconds) {
            return;
        }
        self.lastHealthKitLoggedSampleEndDate = endDate;
        [self.samples addObject:@{ @"date": endDate, @"bpm": @(bpm) }];
        [self trimUnsafeRetainingLastSeconds:kDefaultRetainSeconds maxEntries:kDefaultMaxEntries];
        [self saveToDiskUnsafe];
        [self postSamplesDidUpdateOnMain];
    });
}

#pragma mark - Foreground sampling

+ (void)startForegroundSampling {
    dispatch_async(dispatch_get_main_queue(), ^{
        [OTForegroundHRSampleTimer invalidate];
        OTForegroundHRSampleTimer = nil;
        if (![OTHeartRateMonitoring isMonitoringEnabled]) {
            return;
        }
        if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
            return;
        }
        OTForegroundHRSampleTimer = [NSTimer scheduledTimerWithTimeInterval:kForegroundTimerInterval
                                                                     target:self
                                                                   selector:@selector(foregroundSampleTick:)
                                                                   userInfo:nil
                                                                    repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:OTForegroundHRSampleTimer forMode:NSRunLoopCommonModes];
        [self foregroundSampleTick:nil];
    });
}

+ (void)stopForegroundSampling {
    dispatch_async(dispatch_get_main_queue(), ^{
        [OTForegroundHRSampleTimer invalidate];
        OTForegroundHRSampleTimer = nil;
    });
}

+ (void)foregroundSampleTick:(NSTimer *_Nullable)timer {
    if (![OTHeartRateMonitoring isMonitoringEnabled]) {
        [self stopForegroundSampling];
        return;
    }
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        return;
    }
    NSNumber *hr = [OTHeartRateMonitoring resolvedHeartRateBPMWithMaxSampleAge:15 * 60 outSource:NULL];
    if (hr.integerValue > 0) {
        [[OTLocalHeartRateTimeSeriesStore shared] appendLiveSampleWithBPM:hr.integerValue wallThrottleInterval:0];
    }
}

@end
