//
//  TVLocationDevicesFetcher.m
//  SauronTV
//

#import "TVLocationDevicesFetcher.h"
#import "TVHardcodedConfig.h"
#import <CocoaLumberjack/CocoaLumberjack.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

@implementation TVLocationAPIDevice
@end

@implementation TVLocationDevicesFetcher

+ (nullable NSURL *)locationAPIURL {
    if (!kTVWebAppOriginURL.length) {
        return nil;
    }
    NSURL *base = [NSURL URLWithString:kTVWebAppOriginURL];
    if (!base) {
        return nil;
    }
    NSURLComponents *c = [NSURLComponents componentsWithURL:base resolvingAgainstBaseURL:YES];
    c.path = @"/api/location";
    c.queryItems = @[ [NSURLQueryItem queryItemWithName:@"showTeslaBeacons" value:@"false"] ];
    return c.URL;
}

+ (nullable TVLocationAPIDevice *)deviceFromAPIDictionary:(NSDictionary *)device
                                                  userKey:(nullable NSString *)userKey {
    NSString *topic = nil;
    id topicObj = device[@"mqttTopic"];
    if ([topicObj isKindOfClass:[NSString class]] && [(NSString *)topicObj length] > 0) {
        topic = (NSString *)topicObj;
    } else {
        id trackerIdObj = device[@"trackerId"];
        NSString *uk = userKey.length ? userKey : nil;
        if (!uk.length) {
            id u = device[@"user"];
            if ([u isKindOfClass:[NSString class]] && [(NSString *)u length] > 0) {
                uk = (NSString *)u;
            }
        }
        if (![trackerIdObj isKindOfClass:[NSString class]] || [(NSString *)trackerIdObj length] == 0
            || !uk.length) {
            return nil;
        }
        topic = [NSString stringWithFormat:@"api/%@/%@", uk, (NSString *)trackerIdObj];
    }

    TVLocationAPIDevice *d = [[TVLocationAPIDevice alloc] init];
    d.mqttTopic = topic;
    id nameObj = device[@"deviceName"];
    d.deviceName = ([nameObj isKindOfClass:[NSString class]] && [(NSString *)nameObj length] > 0)
        ? (NSString *)nameObj
        : nil;

    id ts = device[@"timestamp"];
    NSNumber *tst = [ts isKindOfClass:[NSNumber class]] ? (NSNumber *)ts : nil;
    d.timestamp = tst ? tst.doubleValue : 0;

    id latObj = device[@"latitude"];
    id lonObj = device[@"longitude"];
    if (![latObj isKindOfClass:[NSNumber class]] || ![lonObj isKindOfClass:[NSNumber class]]) {
        d.hasValidCoordinate = NO;
        return d;
    }
    double lat = [(NSNumber *)latObj doubleValue];
    double lon = [(NSNumber *)lonObj doubleValue];
    if (lat == 0.0 && lon == 0.0) {
        d.hasValidCoordinate = NO;
        return d;
    }
    d.hasValidCoordinate = YES;
    d.coordinate = CLLocationCoordinate2DMake(lat, lon);

    if (userKey.length) {
        d.routeAPIUser = userKey;
    } else {
        id u = device[@"user"];
        if ([u isKindOfClass:[NSString class]] && [(NSString *)u length] > 0) {
            d.routeAPIUser = (NSString *)u;
        }
    }
    return d;
}

+ (NSArray<TVLocationAPIDevice *> *)parseDevicesFromJSONDictionary:(NSDictionary *)root {
    NSMutableArray<TVLocationAPIDevice *> *out = [NSMutableArray array];

    id flat = root[@"devices"];
    if ([flat isKindOfClass:[NSArray class]]) {
        for (id dev in (NSArray *)flat) {
            if (![dev isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            TVLocationAPIDevice *d = [self deviceFromAPIDictionary:(NSDictionary *)dev userKey:nil];
            if (d) {
                [out addObject:d];
            }
        }
        return [out copy];
    }

    for (NSString *userKey in root) {
        id entry = root[userKey];
        if (![entry isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *userDict = (NSDictionary *)entry;
        id devices = userDict[@"devices"];
        if (![devices isKindOfClass:[NSArray class]]) {
            continue;
        }
        for (id dev in (NSArray *)devices) {
            if (![dev isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            TVLocationAPIDevice *d = [self deviceFromAPIDictionary:(NSDictionary *)dev userKey:userKey];
            if (d) {
                [out addObject:d];
            }
        }
    }
    return [out copy];
}

+ (void)fetchDevicesWithBearerToken:(NSString *)token
                         completion:(void (^)(NSArray<TVLocationAPIDevice *> * _Nullable,
                                              NSError * _Nullable))completion {
    NSURL *url = [self locationAPIURL];
    if (!url) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSError errorWithDomain:@"TVLocationDevicesFetcher" code:1
                                                userInfo:@{NSLocalizedDescriptionKey: @"No web app origin URL"}]);
            });
        }
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                 completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(nil, err);
                }
            });
            return;
        }
        NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]]
            ? [(NSHTTPURLResponse *)resp statusCode]
            : 0;
        if (status != 200) {
            NSError *e = [NSError errorWithDomain:@"TVLocationDevicesFetcher"
                                             code:(int)status
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)status]}];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(nil, e);
                }
            });
            return;
        }

        NSError *jsonErr = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data] options:0 error:&jsonErr];
        if (jsonErr || ![obj isKindOfClass:[NSDictionary class]]) {
            NSError *e = jsonErr ?: [NSError errorWithDomain:@"TVLocationDevicesFetcher" code:2
                                                    userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(nil, e);
                }
            });
            return;
        }

        NSArray<TVLocationAPIDevice *> *devices = [self parseDevicesFromJSONDictionary:(NSDictionary *)obj];
        DDLogInfo(@"[TVLocationDevicesFetcher] parsed %lu devices", (unsigned long)devices.count);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(devices, nil);
            }
        });
    }];
    [task resume];
}

@end
