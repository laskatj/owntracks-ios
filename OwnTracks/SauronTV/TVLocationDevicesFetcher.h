//
//  TVLocationDevicesFetcher.h
//  SauronTV
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVLocationAPIDevice : NSObject
@property (copy, nonatomic) NSString *mqttTopic;
@property (copy, nonatomic, nullable) NSString *deviceName;
@property (nonatomic) BOOL hasValidCoordinate;
@property (nonatomic) CLLocationCoordinate2D coordinate;
@property (nonatomic) NSTimeInterval timestamp;
@property (copy, nonatomic, nullable) NSString *routeAPIUser;
@property (copy, nonatomic, nullable) NSString *markerImageURLString;
@end

@interface TVLocationDevicesFetcher : NSObject

/// GET {kTVWebAppOriginURL origin}/api/location?showTeslaBeacons=false
+ (nullable NSURL *)locationAPIURL;

/// Parses JSON on a background queue; calls completion on the main queue.
+ (void)fetchDevicesWithBearerToken:(NSString *)token
                         completion:(void (^)(NSArray<TVLocationAPIDevice *> * _Nullable devices,
                                              NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
