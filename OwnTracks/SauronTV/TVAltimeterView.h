//
//  TVAltimeterView.h
//  SauronTV
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Altitude readout with sparkline history (feet when usesImperial).
@interface TVAltimeterView : UIView

/// Current altitude in meters (NAN if unknown).
@property (nonatomic) double altitudeMeters;

/// Recent samples in meters (oldest first) for the sparkline.
@property (nonatomic, copy) NSArray<NSNumber *> *altitudeHistoryMeters;

/// When YES (default), display feet.
@property (nonatomic) BOOL usesImperial;

@end

NS_ASSUME_NONNULL_END
