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
@property (nonatomic, strong) UILabel *heartRateLabel;
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
        _speedLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2]
            scaledFontForFont:[UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium]];
        _speedLabel.textAlignment = NSTextAlignmentCenter;
        _speedLabel.textColor = [UIColor secondaryLabelColor];
        _speedLabel.numberOfLines = 1;
        [self addSubview:_speedLabel];

        _heartRateLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _heartRateLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2]
            scaledFontForFont:[UIFont systemFontOfSize:10.0 weight:UIFontWeightSemibold]];
        _heartRateLabel.textAlignment = NSTextAlignmentCenter;
        _heartRateLabel.textColor = [UIColor secondaryLabelColor];
        _heartRateLabel.numberOfLines = 1;
        _heartRateLabel.hidden = YES;
        [self addSubview:_heartRateLabel];

        _measurementFormatter = [[NSMeasurementFormatter alloc] init];
        _measurementFormatter.unitOptions = NSMeasurementFormatterUnitOptionsProvidedUnit;
        _measurementFormatter.numberFormatter.maximumFractionDigits = 0;
    }
    return self;
}

- (CGSize)intrinsicContentSize {
    CGFloat h = self.heartRateLabel.hidden ? 36.0 : 48.0;
    return CGSizeMake(88.0, h);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds);
    const CGFloat sideInset = 2.0;
    const CGFloat speedH = 13.0;
    self.speedLabel.frame = CGRectMake(sideInset, 0.0, w - 2.0 * sideInset, speedH);
    if (self.heartRateLabel.hidden) {
        self.heartRateLabel.frame = CGRectZero;
    } else {
        CGFloat hrTop = CGRectGetMaxY(self.speedLabel.frame);
        self.heartRateLabel.frame = CGRectMake(sideInset, hrTop, w - 2.0 * sideInset, 12.0);
    }
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

- (void)updateHeartRateBPM:(nullable NSNumber *)bpm {
    BOOL show = [bpm isKindOfClass:[NSNumber class]] && bpm.intValue > 0;
    self.heartRateLabel.hidden = !show;
    if (show) {
        self.heartRateLabel.text =
            [NSString stringWithFormat:NSLocalizedString(@"%d bpm", @"Beats per minute (friend device callout)"),
                                       bpm.intValue];
        self.heartRateLabel.textColor = [UIColor systemPinkColor];
    } else {
        self.heartRateLabel.text = nil;
    }
    [self invalidateIntrinsicContentSize];
    [self setNeedsLayout];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    [super drawRect:rect];

    CGFloat w = CGRectGetWidth(rect);
    CGFloat labelBottom = CGRectGetMaxY(self.speedLabel.frame);
    if (!self.heartRateLabel.hidden) {
        labelBottom = MAX(labelBottom, CGRectGetMaxY(self.heartRateLabel.frame));
    }
    labelBottom += 0.5;
    CGFloat gaugeBottom = CGRectGetHeight(rect) - 1.0;
    CGFloat radius = MIN((w - 4.0) / 2.0, (gaugeBottom - labelBottom) * 0.93);
    if (radius < 5.5) {
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
    track.lineWidth = 2.0;
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
