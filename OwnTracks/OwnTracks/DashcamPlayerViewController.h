//
//  DashcamPlayerViewController.h
//  OwnTracks
//
//  Embedded AVPlayer for a single dashcam clip with a camera switcher and
//  metadata (event time, place, reason).
//

#import <UIKit/UIKit.h>

@class OTDashcamClipItem;

NS_ASSUME_NONNULL_BEGIN

@interface DashcamPlayerViewController : UIViewController

- (instancetype)initWithClip:(OTDashcamClipItem *)clip NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
