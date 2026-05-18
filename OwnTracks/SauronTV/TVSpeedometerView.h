//
//  TVSpeedometerView.h
//  SauronTV
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Circular speedometer drawn with Core Graphics (green / yellow / red arc by speed).
@interface TVSpeedometerView : UIView

/// Current speed in km/h (negative hides arc fill; display shows 0).
@property (nonatomic) double speedKmh;

/// Full-scale speed for the arc (default 200 km/h, or 120 mph when imperial).
@property (nonatomic) double maxSpeedKmh;

/// When YES (default), display MPH and use mph arc thresholds.
@property (nonatomic) BOOL usesImperial;

/// Recent speed samples in km/h (oldest first) for the bottom graphlet.
@property (nonatomic, copy) NSArray<NSNumber *> *speedHistoryKmh;

@end

NS_ASSUME_NONNULL_END
