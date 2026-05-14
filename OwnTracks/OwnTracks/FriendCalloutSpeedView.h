//
//  FriendCalloutSpeedView.h
//  OwnTracks
//
//  Speed label + semicircular gauge for Friend map callouts (detailCalloutAccessoryView).
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface FriendCalloutSpeedView : UIView

/// `waypointSpeedKmH` is OwnTracks waypoint / MQTT speed in **km/h**; callout shows **mph** (imperial).
/// Must be finite and >= 0 for a value; otherwise shows "—".
- (void)updateSpeedKmH:(double)waypointSpeedKmH;

/// Friend device heart rate from MQTT `hr` / waypoint; hides the row when `bpm` is nil or not positive.
- (void)updateHeartRateBPM:(nullable NSNumber *)bpm;

@end

NS_ASSUME_NONNULL_END
