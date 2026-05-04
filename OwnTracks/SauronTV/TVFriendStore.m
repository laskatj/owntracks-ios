//
//  TVFriendStore.m
//  SauronTV
//

#import "TVFriendStore.h"
#import "TVLocationDevicesFetcher.h"
#import <CocoaLumberjack/CocoaLumberjack.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

NSString * const TVFriendStoreDidUpdateNotification = @"TVFriendStoreDidUpdate";

static NSString * const kLocationNote  = @"OTLiveFriendLocation";
static NSString * const kCardNote      = @"OTFriendCard";

static NSSet *TVFriendStoreMQTTSubtopicLeafs(void) {
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithObjects:@"info", @"event", @"waypoints", @"waypoint", @"status", @"cmd", nil];
    });
    return s;
}

@interface TVFriendStore ()
@property (strong, nonatomic) NSMutableArray<NSString *>                   *mTopics;
@property (strong, nonatomic) NSMutableDictionary<NSString *, NSString *>  *mLabels;
@property (strong, nonatomic) NSMutableDictionary<NSString *, NSString *>  *mTimes;
@property (strong, nonatomic) NSMutableDictionary<NSString *, UIImage *>   *mImages;
@property (strong, nonatomic) NSMutableDictionary<NSString *, NSValue *>   *mCoords;
@property (strong, nonatomic) NSMutableDictionary<NSString *, NSNumber *>  *mRawTimestamps;
@property (strong, nonatomic) NSMutableSet<NSString *>                     *mAllowedTopics;
@property (strong, nonatomic) NSMutableDictionary<NSString *, NSString *>  *mAPIDeviceNames;
@property (strong, nonatomic) NSMutableDictionary<NSString *, NSString *>  *mMarkerImageURLs;
@property (strong, nonatomic) NSMutableSet<NSString *>                     *mInFlightMarkerImageTopics;
@end

@implementation TVFriendStore

+ (instancetype)shared {
    static TVFriendStore *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _mTopics         = [NSMutableArray array];
        _mLabels         = [NSMutableDictionary dictionary];
        _mTimes          = [NSMutableDictionary dictionary];
        _mImages         = [NSMutableDictionary dictionary];
        _mCoords         = [NSMutableDictionary dictionary];
        _mRawTimestamps  = [NSMutableDictionary dictionary];
        _mAllowedTopics  = [NSMutableSet set];
        _mAPIDeviceNames = [NSMutableDictionary dictionary];
        _mMarkerImageURLs = [NSMutableDictionary dictionary];
        _mInFlightMarkerImageTopics = [NSMutableSet set];
    }
    return self;
}

- (void)start {
    [self loadCachedImages];

    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(locationUpdated:)
                name:kLocationNote object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(cardUpdated:)
                name:kCardNote object:nil];

    DDLogInfo(@"[TVFriendStore] started");
}

#pragma mark - Public readonly accessors

- (NSArray<NSString *> *)friendTopics  { return [self.mTopics copy]; }

- (NSDictionary<NSString *, NSString *> *)friendLabels {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *topic in self.mTopics) {
        NSString *api = self.mAPIDeviceNames[topic];
        if ([api isKindOfClass:[NSString class]] && api.length) {
            out[topic] = api;
        } else {
            NSString *l = self.mLabels[topic];
            if (l.length) {
                out[topic] = l;
            }
        }
    }
    return [out copy];
}

- (NSDictionary<NSString *, NSString *> *)friendTimes  { return [self.mTimes  copy]; }
- (NSDictionary<NSString *, UIImage *>  *)friendImages { return [self.mImages copy]; }
- (NSDictionary<NSString *, NSValue *>  *)friendCoords { return [self.mCoords copy]; }

- (NSArray<NSString *> *)allowedBaseMQTTTopics {
    NSArray *arr = [self.mAllowedTopics allObjects];
    return [arr sortedArrayUsingSelector:@selector(compare:)];
}

- (NSTimeInterval)rawTimestampForTopic:(NSString *)topic {
    return [self.mRawTimestamps[topic] doubleValue];
}

- (UIImage *)imageForTopic:(NSString *)topic {
    UIImage *img = self.mImages[topic];
    if (img) {
        return img;
    }
    NSString *label = self.mAPIDeviceNames[topic] ?: self.mLabels[topic] ?: [topic lastPathComponent];
    return [self placeholderImageForLabel:label];
}

+ (NSString *)baseMQTTTopicFromMessageTopic:(NSString *)topic {
    if (!topic.length) {
        return topic;
    }
    NSString *last = [topic lastPathComponent];
    if ([TVFriendStoreMQTTSubtopicLeafs() containsObject:last]) {
        return [topic stringByDeletingLastPathComponent];
    }
    return topic;
}

- (BOOL)isBaseTopicAllowed:(NSString *)baseTopic {
    if (!baseTopic.length) {
        return NO;
    }
    return [self.mAllowedTopics containsObject:baseTopic];
}

- (void)applyLocationAPIDevices:(NSArray<TVLocationAPIDevice *> *)devices {
    NSMutableSet<NSString *> *newAllowed = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSString *> *newNames = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *newMarkerImageURLs = [NSMutableDictionary dictionary];

    for (TVLocationAPIDevice *d in devices) {
        if (!d.mqttTopic.length) {
            continue;
        }
        [newAllowed addObject:d.mqttTopic];
        if (d.deviceName.length) {
            newNames[d.mqttTopic] = d.deviceName;
        }
        if (d.markerImageURLString.length) {
            newMarkerImageURLs[d.mqttTopic] = d.markerImageURLString;
        }
    }

    [self.mAllowedTopics setSet:newAllowed];
    [self.mAPIDeviceNames removeAllObjects];
    [self.mMarkerImageURLs removeAllObjects];
    [self.mAPIDeviceNames addEntriesFromDictionary:newNames];
    [self.mMarkerImageURLs addEntriesFromDictionary:newMarkerImageURLs];

    for (NSString *topic in [self.mTopics copy]) {
        if (![newAllowed containsObject:topic]) {
            [self removeAllStateForTopic:topic];
        }
    }

    for (TVLocationAPIDevice *d in devices) {
        if (!d.mqttTopic.length) {
            continue;
        }
        NSString *topic = d.mqttTopic;
        if (![self.mTopics containsObject:topic]) {
            [self.mTopics addObject:topic];
        }
        if (d.deviceName.length) {
            self.mLabels[topic] = d.deviceName;
        } else if (!self.mLabels[topic]) {
            self.mLabels[topic] = [topic lastPathComponent];
        }

        if (d.hasValidCoordinate && d.timestamp > 0) {
            CLLocationCoordinate2D coord = d.coordinate;
            self.mCoords[topic] = [NSValue valueWithBytes:&coord objCType:@encode(CLLocationCoordinate2D)];
            self.mRawTimestamps[topic] = @(d.timestamp);
            self.mTimes[topic] = [self timestampStringFromTimestamp:d.timestamp];
        }
    }

    [self fetchMissingMarkerImagesForDevices:devices];

    [self sortTopics];

    DDLogInfo(@"[TVFriendStore] applyLocationAPIDevices count=%lu allowed=%lu",
              (unsigned long)devices.count, (unsigned long)newAllowed.count);

    [[NSNotificationCenter defaultCenter]
        postNotificationName:TVFriendStoreDidUpdateNotification
                      object:nil
                    userInfo:@{@"change": @"allowlist"}];
}

- (void)removeAllStateForTopic:(NSString *)topic {
    [self.mTopics removeObject:topic];
    [self.mLabels removeObjectForKey:topic];
    [self.mTimes removeObjectForKey:topic];
    [self.mImages removeObjectForKey:topic];
    [self.mCoords removeObjectForKey:topic];
    [self.mRawTimestamps removeObjectForKey:topic];
    [self.mAPIDeviceNames removeObjectForKey:topic];
    [self.mMarkerImageURLs removeObjectForKey:topic];
    [self.mInFlightMarkerImageTopics removeObject:topic];
    NSURL *file = [[self cacheDirectory] URLByAppendingPathComponent:[self cacheFilenameForTopic:topic]];
    [[NSFileManager defaultManager] removeItemAtURL:file error:nil];
}

#pragma mark - OTLiveFriendLocation

- (void)locationUpdated:(NSNotification *)note {
    NSDictionary *info = note.userInfo;
    NSString *topic = info[@"topic"];
    if (!topic.length) {
        return;
    }
    if (![self isBaseTopicAllowed:topic]) {
        return;
    }

    double lat = [info[@"lat"] doubleValue];
    double lon = [info[@"lon"] doubleValue];
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(lat, lon);

    NSString *label = info[@"label"] ?: [topic lastPathComponent];
    NSString *apiName = self.mAPIDeviceNames[topic];
    if (!apiName.length) {
        self.mLabels[topic] = label;
    }

    self.mTimes[topic]         = [self timestampStringFromInfo:info];
    self.mCoords[topic]        = [NSValue valueWithBytes:&coord objCType:@encode(CLLocationCoordinate2D)];
    self.mRawTimestamps[topic] = @([info[@"tst"] doubleValue]);

    BOOL isNew = ![self.mTopics containsObject:topic];
    NSString *change;
    if (isNew) {
        [self.mTopics addObject:topic];
        [self sortTopics];
        change = @"new";
        DDLogInfo(@"[TVFriendStore] new friend: %@ at %.5f,%.5f", topic, lat, lon);
    } else {
        change = @"location";
    }

    [[NSNotificationCenter defaultCenter]
        postNotificationName:TVFriendStoreDidUpdateNotification
                      object:nil
                    userInfo:@{@"topic": topic, @"change": change}];
}

#pragma mark - OTFriendCard

- (void)cardUpdated:(NSNotification *)note {
    NSString *topic     = note.userInfo[@"topic"];
    NSData   *imageData = note.userInfo[@"imageData"];
    NSString *name      = note.userInfo[@"name"];
    if (!topic.length) {
        return;
    }
    if (![self isBaseTopicAllowed:topic]) {
        return;
    }

    BOOL changed = NO;

    BOOL hasAPIName = [(NSString *)self.mAPIDeviceNames[topic] length] > 0;
    if (name.length && !hasAPIName) {
        self.mLabels[topic] = name;
        [self sortTopics];
        changed = YES;
        DDLogInfo(@"[TVFriendStore] card name updated for %@: %@", topic, name);
    }

    if (imageData.length) {
        UIImage *circular = [self circularImageFromData:imageData];
        if (circular) {
            self.mImages[topic] = circular;
            [self saveImageData:imageData forTopic:topic];
            changed = YES;
            DDLogInfo(@"[TVFriendStore] card image stored for %@", topic);
        } else {
            DDLogInfo(@"[TVFriendStore] card %@ — bad image data", topic);
        }
    }

    if (!changed) {
        return;
    }

    [[NSNotificationCenter defaultCenter]
        postNotificationName:TVFriendStoreDidUpdateNotification
                      object:nil
                    userInfo:@{@"topic": topic, @"change": @"card"}];
}

#pragma mark - Sorting

- (void)sortTopics {
    [self.mTopics sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSString *la = self.mAPIDeviceNames[a] ?: self.mLabels[a] ?: [a lastPathComponent];
        NSString *lb = self.mAPIDeviceNames[b] ?: self.mLabels[b] ?: [b lastPathComponent];
        return [la localizedCaseInsensitiveCompare:lb];
    }];
}

#pragma mark - Image helpers

- (UIImage *)circularImageFromData:(NSData *)data {
    UIImage *src = [UIImage imageWithData:data];
    if (!src) {
        return nil;
    }
    CGFloat size = 60.0;
    CGRect rect = CGRectMake(0, 0, size, size);
    UIGraphicsBeginImageContextWithOptions(rect.size, NO, 0);
    [[UIBezierPath bezierPathWithOvalInRect:rect] addClip];
    [src drawInRect:rect];
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}

- (UIImage *)placeholderImageForLabel:(NSString *)label {
    CGFloat size = 60.0;
    CGRect rect = CGRectMake(0, 0, size, size);
    UIGraphicsBeginImageContextWithOptions(rect.size, NO, 0);
    [[UIColor systemBlueColor] setFill];
    [[UIBezierPath bezierPathWithOvalInRect:rect] fill];
    NSString *text = (label.length > 2) ? [label substringToIndex:2] : (label ?: @"?");
    NSDictionary *attrs = @{
        NSFontAttributeName:            [UIFont boldSystemFontOfSize:22.0],
        NSForegroundColorAttributeName: UIColor.whiteColor,
    };
    CGSize ts = [text sizeWithAttributes:attrs];
    [text drawAtPoint:CGPointMake((size - ts.width) / 2.0, (size - ts.height) / 2.0)
       withAttributes:attrs];
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}

#pragma mark - Timestamp

- (NSString *)timestampStringFromInfo:(NSDictionary *)info {
    NSNumber *tst = info[@"tst"];
    if (!tst || tst.doubleValue == 0) {
        return nil;
    }
    return [self timestampStringFromTimestamp:tst.doubleValue];
}

- (NSString *)timestampStringFromTimestamp:(NSTimeInterval)tst {
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:tst];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateStyle = NSDateFormatterNoStyle;
    fmt.timeStyle = NSDateFormatterShortStyle;
    return [fmt stringFromDate:date];
}

#pragma mark - Disk cache

- (NSURL *)cacheDirectory {
    NSURL *caches = [[[NSFileManager defaultManager]
        URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];
    return [caches URLByAppendingPathComponent:@"OTCards" isDirectory:YES];
}

- (NSString *)cacheFilenameForTopic:(NSString *)topic {
    NSCharacterSet *safe = [NSCharacterSet alphanumericCharacterSet];
    return [[topic stringByAddingPercentEncodingWithAllowedCharacters:safe]
            stringByAppendingPathExtension:@"dat"];
}

- (void)loadCachedImages {
    NSURL *dir = [self cacheDirectory];
    NSArray<NSURL *> *files = [[NSFileManager defaultManager]
        contentsOfDirectoryAtURL:dir
      includingPropertiesForKeys:nil
                         options:NSDirectoryEnumerationSkipsHiddenFiles
                           error:nil];
    if (!files) {
        return;
    }

    NSUInteger count = 0;
    for (NSURL *file in files) {
        NSData *data = [NSData dataWithContentsOfURL:file];
        if (!data) {
            continue;
        }
        NSString *encoded = [file.lastPathComponent stringByDeletingPathExtension];
        NSString *topic   = [encoded stringByRemovingPercentEncoding];
        if (!topic.length) {
            continue;
        }
        UIImage *img = [self circularImageFromData:data];
        if (img) {
            self.mImages[topic] = img;
            count++;
        }
    }
    DDLogInfo(@"[TVFriendStore] loaded %lu cached card images", (unsigned long)count);
}

- (void)saveImageData:(NSData *)data forTopic:(NSString *)topic {
    NSURL *dir = [self cacheDirectory];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir
                             withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *file = [dir URLByAppendingPathComponent:[self cacheFilenameForTopic:topic]];
    NSError *err = nil;
    [data writeToURL:file options:NSDataWritingAtomic error:&err];
    if (err) {
        DDLogInfo(@"[TVFriendStore] cache write failed for %@: %@",
                  topic, err.localizedDescription);
    }
}


- (void)fetchMissingMarkerImagesForDevices:(NSArray<TVLocationAPIDevice *> *)devices {
    for (TVLocationAPIDevice *d in devices) {
        NSString *topic = d.mqttTopic;
        NSString *urlString = self.mMarkerImageURLs[topic];
        if (!topic.length || !urlString.length || self.mImages[topic] || [self.mInFlightMarkerImageTopics containsObject:topic]) {
            continue;
        }
        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) {
            continue;
        }
        [self.mInFlightMarkerImageTopics addObject:topic];
        __weak typeof(self) weakSelf = self;
        [[[NSURLSession sharedSession] dataTaskWithURL:url
                                     completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self) return;
                [self.mInFlightMarkerImageTopics removeObject:topic];
                if (error || !data.length) {
                    return;
                }
                UIImage *circular = [self circularImageFromData:data];
                if (!circular) {
                    return;
                }
                self.mImages[topic] = circular;
                [self saveImageData:data forTopic:topic];
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:TVFriendStoreDidUpdateNotification
                                  object:nil
                                userInfo:@{@"topic": topic, @"change": @"marker-image"}];
            });
        }] resume];
    }
}

@end
