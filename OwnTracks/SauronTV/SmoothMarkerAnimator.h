//
//  SmoothMarkerAnimator.h
//  SauronTV
//
//  Drives a single MKPointAnnotation with smooth, GPS-timing-aware
//  linear interpolation via CADisplayLink (60 fps on tvOS).
//

#import <MapKit/MapKit.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SmoothMarkerAnimator : NSObject

- (instancetype)initWithAnnotation:(MKPointAnnotation *)annotation NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Call on the main thread whenever a new GPS fix arrives for this marker.
- (void)startOrUpdateWithLatitude:(double)latitude
                        longitude:(double)longitude
                        timestamp:(NSTimeInterval)timestamp;

/// Cancels any in-progress animation. Safe to call multiple times.
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
