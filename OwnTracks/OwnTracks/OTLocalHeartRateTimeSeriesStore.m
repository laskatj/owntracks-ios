//
//  OTLocalHeartRateTimeSeriesStore.m
//  OwnTracks
//

#import "OTLocalHeartRateTimeSeriesStore.h"
#import "OTHeartRateMonitoring.h"
#import "BluetoothHeartRateManager.h"
#import <UIKit/UIKit.h>

NSNotificationName const OTLocalHeartRateSamplesDidUpdateNotification = @"OTLocalHeartRateSamplesDidUpdateNotification";

static NSString *const kJSONFileName = @"OTLocalHeartRateSamples.json";
static const NSTimeInterval kDefaultRetainSeconds = 24 * 3600;
static const NSInteger kDefaultMaxEntries = 10000;
static const NSTimeInterval kForegroundTimerInterval = 25.0;
static NSString *const kSamplesKey = @"samples";

@interface OTLocalHeartRateTimeSeriesStore ()
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *samples;
@property (nonatomic, strong) NSDate *lastAppendAt;
@property (nonatomic, strong) NSURL *fileURL;
@end

static NSTimer *OTForegroundHRSampleTimer = nil;
static BOOL OTLocalHRStoreObserversRegistered = NO;
static const NSTimeInterval kBLEAppendThrottleSeconds = 10.0;

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
    [nc addObserverForName:OTBluetoothHeartRateDidUpdateNotification object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *note) {
        if (![OTHeartRateMonitoring isMonitoringEnabled]) {
            return;
        }
        if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
            return;
        }
        NSNumber *hr = [BluetoothHeartRateManager sharedInstance].heartRate;
        if (!hr || hr.integerValue <= 0) {
            hr = [[BluetoothHeartRateManager sharedInstance] heartRateIfSampleWithin:15 * 60];
        }
        if (hr.integerValue > 0) {
            [[OTLocalHeartRateTimeSeriesStore shared] appendSampleAtDate:[NSDate date]
                                                                     bpm:hr.integerValue
                                               throttleMinimumInterval:kBLEAppendThrottleSeconds];
        }
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
        _samples = [NSMutableArray array];
        NSURL *base = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                             inDomains:NSUserDomainMask].firstObject;
        NSString *folder = @"OwnTracks";
        NSURL *dir = [base URLByAppendingPathComponent:folder isDirectory:YES];
        NSError *err = nil;
        [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES
                                                  attributes:nil error:&err];
        _fileURL = [dir URLByAppendingPathComponent:kJSONFileName];
        [self loadFromDisk];
        [self trimRetainingLastSeconds:kDefaultRetainSeconds maxEntries:kDefaultMaxEntries];
    }
    return self;
}

- (instancetype)init {
    NSAssert(NO, @"Use +shared");
    return [self initPrivate];
}

- (void)loadFromDisk {
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

- (void)saveToDisk {
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

- (void)trimRetainingLastSeconds:(NSTimeInterval)retainSeconds maxEntries:(NSInteger)maxEntries {
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

- (NSArray<NSDictionary *> *)samplesFromDate:(NSDate *)start toDate:(NSDate *)end {
    if (!start || !end || [start compare:end] == NSOrderedDescending) {
        return @[];
    }
    NSMutableArray *out = [NSMutableArray array];
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
        [out addObject:@{ @"date": d, @"bpm": row[@"bpm"] ?: @0 }];
    }
    return out;
}

- (void)appendSampleAtDate:(NSDate *)date bpm:(NSInteger)bpm throttleMinimumInterval:(NSTimeInterval)minInterval {
    if (bpm <= 0 || !date) {
        return;
    }
    if (minInterval > 0 && self.lastAppendAt) {
        NSTimeInterval dt = [date timeIntervalSinceDate:self.lastAppendAt];
        if (dt >= 0 && dt < minInterval) {
            return;
        }
    }
    self.lastAppendAt = date;
    [self.samples addObject:@{ @"date": date, @"bpm": @(bpm) }];
    [self trimRetainingLastSeconds:kDefaultRetainSeconds maxEntries:kDefaultMaxEntries];
    [self saveToDisk];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:OTLocalHeartRateSamplesDidUpdateNotification
                                                            object:nil];
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
        [[OTLocalHeartRateTimeSeriesStore shared] appendSampleAtDate:[NSDate date]
                                                                 bpm:hr.integerValue
                                           throttleMinimumInterval:0];
    }
}

@end
