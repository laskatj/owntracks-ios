//
//  OTSpeedometerView.m
//  OwnTracks
//

#import "OTSpeedometerView.h"

static const CGFloat kArcLineWidth = 10.0;
static const CGFloat kArcStartDeg = 225.0;
static const CGFloat kArcSweepDeg = 270.0;
static const double kKmhToMph = 0.621371;

@implementation OTSpeedometerView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        _maxSpeedKmh = 200.0;
        _speedKmh = -1.0;
        _usesImperial = YES;
        _speedHistoryKmh = @[];
    }
    return self;
}

- (void)setSpeedKmh:(double)speedKmh {
    if (_speedKmh == speedKmh) {
        return;
    }
    _speedKmh = speedKmh;
    [self setNeedsDisplay];
}

- (void)setMaxSpeedKmh:(double)maxSpeedKmh {
    if (_maxSpeedKmh == maxSpeedKmh) {
        return;
    }
    _maxSpeedKmh = MAX(1.0, maxSpeedKmh);
    [self setNeedsDisplay];
}

- (void)setUsesImperial:(BOOL)usesImperial {
    if (_usesImperial == usesImperial) {
        return;
    }
    _usesImperial = usesImperial;
    [self setNeedsDisplay];
}

- (void)setSpeedHistoryKmh:(NSArray<NSNumber *> *)speedHistoryKmh {
    speedHistoryKmh = speedHistoryKmh ?: @[];
    if ([_speedHistoryKmh isEqualToArray:speedHistoryKmh]) {
        return;
    }
    _speedHistoryKmh = [speedHistoryKmh copy];
    [self setNeedsDisplay];
}

- (double)displaySpeedFromKmh:(double)kmh {
    if (kmh < 0.0) {
        return 0.0;
    }
    return self.usesImperial ? (kmh * kKmhToMph) : kmh;
}

- (double)displaySpeedForDrawing {
    return [self displaySpeedFromKmh:self.speedKmh >= 0.0 ? self.speedKmh : 0.0];
}

- (double)maxDisplaySpeedForDrawing {
    double maxKmh = self.maxSpeedKmh;
    if (self.usesImperial) {
        double mph = maxKmh * kKmhToMph;
        return mph < 120.0 ? 120.0 : mph;
    }
    return maxKmh;
}

+ (UIColor *)arcColorForDisplaySpeed:(double)speed usesImperial:(BOOL)usesImperial {
    if (usesImperial) {
        if (speed < 37.0) {
            return UIColor.systemGreenColor;
        }
        if (speed < 75.0) {
            return UIColor.systemYellowColor;
        }
        return UIColor.systemRedColor;
    }
    if (speed < 60.0) {
        return UIColor.systemGreenColor;
    }
    if (speed < 120.0) {
        return UIColor.systemYellowColor;
    }
    return UIColor.systemRedColor;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        return;
    }

    CGFloat inset = 8.0;
    CGRect bgRect = CGRectInset(rect, inset, inset);
    UIBezierPath *bgPath = [UIBezierPath bezierPathWithRoundedRect:bgRect cornerRadius:16.0];
    [[UIColor colorWithWhite:0.08 alpha:0.82] setFill];
    [bgPath fill];

    CGRect content = CGRectInset(bgRect, 12.0, 12.0);
    CGFloat graphHeight = CGRectGetHeight(content) * 0.36;
    CGRect gaugeRect = CGRectMake(content.origin.x,
                                content.origin.y,
                                CGRectGetWidth(content),
                                CGRectGetHeight(content) - graphHeight - 8.0);
    CGRect graphRect = CGRectMake(content.origin.x,
                                  CGRectGetMaxY(gaugeRect) + 8.0,
                                  CGRectGetWidth(content),
                                  graphHeight);

    CGPoint center = CGPointMake(CGRectGetMidX(gaugeRect), CGRectGetMidY(gaugeRect) - 2.0);
    CGFloat side = MIN(CGRectGetWidth(gaugeRect), CGRectGetHeight(gaugeRect)) - 20.0;
    CGFloat radius = side * 0.38;

    CGFloat startRad = (CGFloat)(kArcStartDeg * M_PI / 180.0);
    CGFloat sweepRad = (CGFloat)(kArcSweepDeg * M_PI / 180.0);

    UIBezierPath *track = [UIBezierPath bezierPathWithArcCenter:center
                                                         radius:radius
                                                     startAngle:startRad
                                                       endAngle:startRad + sweepRad
                                                      clockwise:YES];
    track.lineWidth = kArcLineWidth;
    track.lineCapStyle = kCGLineCapRound;
    [[UIColor colorWithWhite:0.25 alpha:1.0] setStroke];
    [track stroke];

    double displaySpeed = [self displaySpeedForDrawing];
    double maxDisplay = [self maxDisplaySpeedForDrawing];
    double fraction = displaySpeed / maxDisplay;
    fraction = MIN(MAX(fraction, 0.0), 1.0);

    if (fraction > 0.001) {
        CGFloat valueSweep = (CGFloat)(sweepRad * fraction);
        UIBezierPath *valueArc = [UIBezierPath bezierPathWithArcCenter:center
                                                               radius:radius
                                                           startAngle:startRad
                                                             endAngle:startRad + valueSweep
                                                            clockwise:YES];
        valueArc.lineWidth = kArcLineWidth;
        valueArc.lineCapStyle = kCGLineCapRound;
        [[self.class arcColorForDisplaySpeed:displaySpeed usesImperial:self.usesImperial] setStroke];
        [valueArc stroke];
    }

    BOOL compact = CGRectGetWidth(rect) > 0.0 && CGRectGetWidth(rect) < 110.0;
    CGFloat speedFontSize = compact ? 29.0 : 40.0;
    CGFloat unitFontSize = compact ? 12.0 : 16.0;

    NSString *speedText = [NSString stringWithFormat:@"%.0f", displaySpeed];
    NSDictionary *speedAttrs = @{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:speedFontSize weight:UIFontWeightBold],
        NSForegroundColorAttributeName: UIColor.whiteColor,
    };
    CGSize speedSize = [speedText sizeWithAttributes:speedAttrs];
    [speedText drawAtPoint:CGPointMake(center.x - speedSize.width / 2.0,
                                     center.y - speedSize.height / 2.0 - 6.0)
            withAttributes:speedAttrs];

    NSString *unitText = self.usesImperial ? @"MPH" : @"KM/H";
    NSDictionary *unitAttrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:unitFontSize weight:UIFontWeightMedium],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.55 alpha:1.0],
    };
    CGSize unitSize = [unitText sizeWithAttributes:unitAttrs];
    [unitText drawAtPoint:CGPointMake(center.x - unitSize.width / 2.0,
                                     center.y + speedSize.height / 2.0 - 8.0)
           withAttributes:unitAttrs];

    [self drawSparklineInRect:graphRect];
}

- (void)drawSparklineInRect:(CGRect)graphRect {
    UIBezierPath *baseline = [UIBezierPath bezierPath];
    baseline.lineWidth = 1.0;
    CGFloat midY = CGRectGetMidY(graphRect);
    [baseline moveToPoint:CGPointMake(CGRectGetMinX(graphRect), midY)];
    [baseline addLineToPoint:CGPointMake(CGRectGetMaxX(graphRect), midY)];
    [[UIColor colorWithWhite:0.22 alpha:1.0] setStroke];
    [baseline stroke];

    NSArray<NSNumber *> *samples = self.speedHistoryKmh;
    if (samples.count < 2) {
        if (self.speedKmh >= 0.0) {
            samples = @[@(self.speedKmh), @(self.speedKmh)];
        } else {
            return;
        }
    }

    NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithCapacity:samples.count];
    for (NSNumber *n in samples) {
        double kmh = n.doubleValue;
        if (kmh >= 0.0) {
            [values addObject:@([self displaySpeedFromKmh:kmh])];
        }
    }
    if (values.count < 2) {
        return;
    }

    double minV = values.firstObject.doubleValue;
    double maxV = values.firstObject.doubleValue;
    for (NSNumber *n in values) {
        minV = MIN(minV, n.doubleValue);
        maxV = MAX(maxV, n.doubleValue);
    }
    double range = maxV - minV;
    if (range < 1.0) {
        minV -= 5.0;
        maxV += 5.0;
        range = maxV - minV;
    }

    double latest = values.lastObject.doubleValue;
    UIColor *lineColor = [self.class arcColorForDisplaySpeed:latest usesImperial:self.usesImperial];

    UIBezierPath *wave = [UIBezierPath bezierPath];
    wave.lineWidth = 2.5;
    wave.lineJoinStyle = kCGLineJoinRound;
    wave.lineCapStyle = kCGLineCapRound;

    NSUInteger count = values.count;
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat x = CGRectGetMinX(graphRect) + (CGRectGetWidth(graphRect) * (CGFloat)i / (CGFloat)(count - 1));
        double normalized = (values[i].doubleValue - minV) / range;
        CGFloat y = CGRectGetMaxY(graphRect) - (CGFloat)normalized * (CGRectGetHeight(graphRect) - 4.0) - 2.0;
        CGPoint pt = CGPointMake(x, y);
        if (i == 0) {
            [wave moveToPoint:pt];
        } else {
            [wave addLineToPoint:pt];
        }
    }

    [lineColor setStroke];
    [wave stroke];
}

@end
