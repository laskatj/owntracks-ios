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
/// API user key for grouping devices by person (same as routeAPIUser when set).
@property (copy, nonatomic, nullable) NSString *userKey;
@property (copy, nonatomic, nullable) NSString *routeAPIUser;
/// Speed in km/h from API `velocity`; -1 if unknown.
@property (nonatomic) double velocity;
/// Altitude in meters from API `altitude`; NAN if unknown.
@property (nonatomic) double altitudeMeters;
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
