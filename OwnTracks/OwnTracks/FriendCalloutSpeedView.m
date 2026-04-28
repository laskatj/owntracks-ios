//
//  FriendCalloutSpeedView.m
//  OwnTracks
//

#import "FriendCalloutSpeedView.h"

/// Full sweep of the gauge = 100 mph so **50% arc = 50 mph**.
static const double kGaugeMaxMph = 100.0;

static double OTWaypointKmHToMph(double kmh) {
    return kmh * 0.621371192237337;
}

static UIColor *OTGaugeFillColorForMph(double mph) {
    if (mph < 50.0) {
        return [UIColor systemGreenColor];
    }
    if (mph < 75.0) {
        return [UIColor systemYellowColor];
    }
    return [UIColor systemRedColor];
}

@interface FriendCalloutSpeedView ()
@property (nonatomic, strong) UILabel *speedLabel;
/// Speed shown on label and gauge (mph); < 0 means invalid / placeholder.
@property (nonatomic, assign) double displayMph;
@property (nonatomic, strong) NSMeasurementFormatter *measurementFormatter;
@end

@implementation FriendCalloutSpeedView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _displayMph = -1.0;
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;

        _speedLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _speedLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        _speedLabel.textAlignment = NSTextAlignmentCenter;
        _speedLabel.textColor = [UIColor secondaryLabelColor];
        _speedLabel.numberOfLines = 1;
        [self addSubview:_speedLabel];

        _measurementFormatter = [[NSMeasurementFormatter alloc] init];
        _measurementFormatter.unitOptions = NSMeasurementFormatterUnitOptionsProvidedUnit;
        _measurementFormatter.numberFormatter.maximumFractionDigits = 0;
    }
    return self;
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(132.0, 52.0);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds);
    CGFloat labelH = 22.0;
    self.speedLabel.frame = CGRectMake(4.0, 2.0, w - 8.0, labelH);
}

- (void)updateSpeedKmH:(double)waypointSpeedKmH {
    BOOL valid = isfinite(waypointSpeedKmH) && waypointSpeedKmH >= 0.0;
    if (valid) {
        double mph = OTWaypointKmHToMph(waypointSpeedKmH);
        if (!isfinite(mph) || mph < 0.0) {
            mph = 0.0;
        }
        self.displayMph = mph;
        NSMeasurement<NSUnitSpeed *> *m =
            [[NSMeasurement alloc] initWithDoubleValue:mph unit:NSUnitSpeed.milesPerHour];
        self.speedLabel.text = [self.measurementFormatter stringFromMeasurement:m];
        self.speedLabel.textColor = [UIColor labelColor];
    } else {
        self.displayMph = -1.0;
        self.speedLabel.text = @"—";
        self.speedLabel.textColor = [UIColor secondaryLabelColor];
    }
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    [super drawRect:rect];

    CGFloat w = CGRectGetWidth(rect);
    CGFloat labelBottom = CGRectGetMaxY(self.speedLabel.frame) + 2.0;
    CGFloat gaugeBottom = CGRectGetHeight(rect) - 3.0;
    CGFloat radius = MIN((w - 12.0) / 2.0, (gaugeBottom - labelBottom) * 0.95);
    if (radius < 8.0) {
        return;
    }
    CGPoint center = CGPointMake(w / 2.0, gaugeBottom);

    const CGFloat startAngle = (CGFloat)(M_PI_2 + M_PI / 6.0);
    const CGFloat fullSweep = (CGFloat)(M_PI * 2.0 * 5.0 / 6.0);

    // Track (full scale)
    UIBezierPath *track = [UIBezierPath bezierPathWithArcCenter:center
                                                         radius:radius
                                                     startAngle:startAngle
                                                       endAngle:startAngle + fullSweep
                                                      clockwise:YES];
    track.lineWidth = 3.0;
    [[UIColor tertiaryLabelColor] setStroke];
    [track stroke];

    BOOL valid = isfinite(self.displayMph) && self.displayMph >= 0.0;
    if (!valid) {
        return;
    }

    CGFloat t = (CGFloat)MIN(self.displayMph / kGaugeMaxMph, 1.0);
    if (t <= 0.0) {
        return;
    }

    CGFloat endAngle = startAngle + fullSweep * t;

    UIBezierPath *fill = [[UIBezierPath alloc] init];
    [fill moveToPoint:center];
    [fill addArcWithCenter:center
                    radius:radius
                startAngle:startAngle
                  endAngle:endAngle
                 clockwise:YES];
    [fill addLineToPoint:center];
    [fill closePath];

    [OTGaugeFillColorForMph(self.displayMph) setFill];
    [fill fill];

    [[UIColor colorNamed:@"circleColor"] ?: [UIColor systemGrayColor] setStroke];
    fill.lineWidth = 1.0;
    [fill stroke];
}

@end
