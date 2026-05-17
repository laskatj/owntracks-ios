//
//  DashcamGridViewController.h
//  OwnTracks
//
//  Admin-only Dash Cam tab: fetches `/api/users/devices?includeAllForAdmin=true`,
//  then `/api/dashcam/clips` per accessible device in a sliding time window, and
//  merges the results into a single grid sorted by event time descending.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DashcamGridViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
