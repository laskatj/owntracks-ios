//
//  TVFriendStore.m
//  SauronTV
//

#import "TVFriendStore.h"
#import <CocoaLumberjack/CocoaLumberjack.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

NSString * const TVFriendStoreDidUpdateNotification = @"TVFriendStoreDidUpdate";

static const CGFloat kImageSize        = 60.0;
static NSString * const kCacheSubdir   = @"OTCards";
static NSString * const kLocationNote  = @"OTLiveFriendLocation";
static NSString * const kCardNote      = @"OTFriendCard";

@interface TVFriendStore ()
@property (strong, nonatomic) NSMutableArray<NSString *>              *mTopics;
@property (strong, nonatomic) NSMutableDictionary<NSString *, NSString *> *mLabels;
@property (strong, nonatomic) NSMutableDictionary<NSString *, NSString *> *mTimes;
@property (strong, nonatomic) NSMutableDictionary<NSString *, UIImage *>  *mImages;
@property (strong, nonatomic) NSMutableDictionary<NSString *, NSValue *>  *mCoords;
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
        _mTopics = [NSMutableArray array];
        _mLabels = [NSMutableDictionary dictionary];
        _mTimes  = [NSMutableDictionary dictionary];
        _mImages = [NSMutableDictionary dictionary];
        _mCoords = [NSMutableDictionary dictionary];
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
- (NSDictionary<NSString *, NSString *> *)friendLabels { return [self.mLabels copy]; }
- (NSDictionary<NSString *, NSString *> *)friendTimes  { return [self.mTimes  copy]; }
- (NSDictionary<NSString *, UIImage *>  *)friendImages { return [self.mImages copy]; }
- (NSDictionary<NSString *, NSValue *>  *)friendCoords { return [self.mCoords copy]; }

- (UIImage *)imageForTopic:(NSString *)topic {
    UIImage *img = self.mImages[topic];
    if (img) return img;
    NSString *label = self.mLabels[topic] ?: [topic lastPathComponent];
    return [self placeholderImageForLabel:label];
}

#pragma mark - OTLiveFriendLocation

- (void)locationUpdated:(NSNotification *)note {
    NSDictionary *info = note.userInfo;
    NSString *topic = info[@"topic"];
    if (!topic.length) return;

    double lat = [info[@"lat"] doubleValue];
    double lon = [info[@"lon"] doubleValue];
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(lat, lon);

    NSString *label = info[@"label"] ?: [topic lastPathComponent];
    self.mLabels[topic] = label;
    self.mTimes[topic]  = [self timestampStringFromInfo:info];
    self.mCoords[topic] = [NSValue valueWithBytes:&coord objCType:@encode(CLLocationCoordinate2D)];

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
    if (!topic.length) return;

    BOOL changed = NO;

    // Apply the display name if provided — overrides the tid-derived label.
    if (name.length) {
        self.mLabels[topic] = name;
        // Propagate name to the map annotation title too.
        [self sortTopics];
        changed = YES;
        DDLogInfo(@"[TVFriendStore] card name updated for %@: %@", topic, name);
    }

    // Apply the face image if provided.
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

    if (!changed) return;

    // Use @"card" so consumers know both label and image may have changed.
    [[NSNotificationCenter defaultCenter]
        postNotificationName:TVFriendStoreDidUpdateNotification
                      object:nil
                    userInfo:@{@"topic": topic, @"change": @"card"}];
}

#pragma mark - Sorting

- (void)sortTopics {
    [self.mTopics sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSString *la = self.mLabels[a] ?: [a lastPathComponent];
        NSString *lb = self.mLabels[b] ?: [b lastPathComponent];
        return [la localizedCaseInsensitiveCompare:lb]; // A → Z
    }];
}

#pragma mark - Image helpers

- (UIImage *)circularImageFromData:(NSData *)data {
    UIImage *src = [UIImage imageWithData:data];
    if (!src) return nil;
    CGFloat size = kImageSize;
    CGRect rect = CGRectMake(0, 0, size, size);
    UIGraphicsBeginImageContextWithOptions(rect.size, NO, 0);
    [[UIBezierPath bezierPathWithOvalInRect:rect] addClip];
    [src drawInRect:rect];
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}

- (UIImage *)placeholderImageForLabel:(NSString *)label {
    CGFloat size = kImageSize;
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
    if (!tst || tst.doubleValue == 0) return nil;
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:tst.doubleValue];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateStyle = NSDateFormatterNoStyle;
    fmt.timeStyle = NSDateFormatterShortStyle;
    return [fmt stringFromDate:date];
}

#pragma mark - Disk cache

- (NSURL *)cacheDirectory {
    NSURL *caches = [[[NSFileManager defaultManager]
        URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];
    return [caches URLByAppendingPathComponent:kCacheSubdir isDirectory:YES];
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
    if (!files) return;

    NSUInteger count = 0;
    for (NSURL *file in files) {
        NSData *data = [NSData dataWithContentsOfURL:file];
        if (!data) continue;
        NSString *encoded = [file.lastPathComponent stringByDeletingPathExtension];
        NSString *topic   = [encoded stringByRemovingPercentEncoding];
        if (!topic.length) continue;
        UIImage *img = [self circularImageFromData:data];
        if (img) { self.mImages[topic] = img; count++; }
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
    if (err) DDLogInfo(@"[TVFriendStore] cache write failed for %@: %@",
                       topic, err.localizedDescription);
}

@end
