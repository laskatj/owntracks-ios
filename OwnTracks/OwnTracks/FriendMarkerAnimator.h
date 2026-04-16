//
//  FriendMarkerAnimator.h
//  OwnTracks
//
//  Drives a single Friend annotation with smooth, GPS-timing-aware
//  linear interpolation via CADisplayLink (60 fps on iOS).
//
//  Mirrors SmoothMarkerAnimator (SauronTV) but types to Friend * and
//  routes coordinate writes through -setLiveCoordinate: so MapKit's
//  KVO observer fires correctly.
//

#import <MapKit/MapKit.h>
#import "coredata/Friend+CoreDataClass.h"

NS_ASSUME_NONNULL_BEGIN

@interface FriendMarkerAnimator : NSObject

- (instancetype)initWithFriend:(Friend *)friend NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Call on the main thread whenever a new GPS fix arrives for this marker.
- (void)startOrUpdateWithLatitude:(double)latitude
                        longitude:(double)longitude
                        timestamp:(NSTimeInterval)timestamp;

/// Cancels any in-progress animation. Safe to call multiple times.
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
