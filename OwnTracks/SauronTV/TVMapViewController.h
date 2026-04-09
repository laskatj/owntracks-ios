//
//  TVMapViewController.h
//  SauronTV
//
//  Full-screen interactive MKMapView showing friend pins.
//  TVFriendsViewController calls selectFriendByTopic: to zoom and follow a friend.
//

#import <UIKit/UIKit.h>
#import <MapKit/MapKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVMapViewController : UIViewController <MKMapViewDelegate>

/// Zoom to the given friend and start following them as they move.
/// Pass nil to clear the selection and zoom to fit all friends.
- (void)selectFriendByTopic:(nullable NSString *)topic;

@end

NS_ASSUME_NONNULL_END
