//
//  OTAltimeterView.m
//  OwnTracks
//

#import "OTAltimeterView.h"

static const double kMetersToFeet = 3.28084;

static UIColor *OTAltimeterGraphBlue(void) {
    return [UIColor colorWithRed:0.35 green:0.78 blue:1.0 alpha:1.0];
}

@implementation OTAltimeterView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        _altitudeMeters = NAN;
        _altitudeHistoryMeters = @[];
        _usesImperial = YES;
    }
    return self;
}

- (void)setAltitudeMeters:(double)altitudeMeters {
    if (_altitudeMeters == altitudeMeters || (isnan(_altitudeMeters) && isnan(altitudeMeters))) {
        return;
    }
    _altitudeMeters = altitudeMeters;
    [self setNeedsDisplay];
}

- (void)setAltitudeHistoryMeters:(NSArray<NSNumber *> *)altitudeHistoryMeters {
    altitudeHistoryMeters = altitudeHistoryMeters ?: @[];
    if ([_altitudeHistoryMeters isEqualToArray:altitudeHistoryMeters]) {
        return;
    }
    _altitudeHistoryMeters = [altitudeHistoryMeters copy];
    [self setNeedsDisplay];
}

- (void)setUsesImperial:(BOOL)usesImperial {
    if (_usesImperial == usesImperial) {
        return;
    }
    _usesImperial = usesImperial;
    [self setNeedsDisplay];
}

- (double)displayAltitudeFromMeters:(double)meters {
    if (isnan(meters)) {
        return 0.0;
    }
    return self.usesImperial ? (meters * kMetersToFeet) : meters;
}

- (NSString *)unitLabel {
    return self.usesImperial ? @"FT" : @"M";
}

- (void)drawRect:(CGRect)rect {
    CGFloat inset = 8.0;
    CGRect bgRect = CGRectInset(rect, inset, inset);
    UIBezierPath *bgPath = [UIBezierPath bezierPathWithRoundedRect:bgRect cornerRadius:16.0];
    [[UIColor colorWithWhite:0.08 alpha:0.82] setFill];
    [bgPath fill];

    CGRect content = CGRectInset(bgRect, 12.0, 12.0);
    CGFloat graphHeight = CGRectGetHeight(content) * 0.36;
    CGRect valueRect = CGRectMake(content.origin.x,
                                content.origin.y,
                                CGRectGetWidth(content),
                                CGRectGetHeight(content) - graphHeight - 8.0);
    CGRect graphRect = CGRectMake(content.origin.x,
                                  CGRectGetMaxY(valueRect) + 8.0,
                                  CGRectGetWidth(content),
                                  graphHeight);

    CGPoint center = CGPointMake(CGRectGetMidX(valueRect), CGRectGetMidY(valueRect) - 4.0);

    double displayAlt = [self displayAltitudeFromMeters:self.altitudeMeters];
    NSString *altText = isnan(self.altitudeMeters)
        ? @"—"
        : [NSString stringWithFormat:@"%.0f", displayAlt];

    NSDictionary *altAttrs = @{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:44.0 weight:UIFontWeightBold],
        NSForegroundColorAttributeName: UIColor.whiteColor,
    };
    CGSize altSize = [altText sizeWithAttributes:altAttrs];
    [altText drawAtPoint:CGPointMake(center.x - altSize.width / 2.0,
                                     center.y - altSize.height / 2.0 - 8.0)
            withAttributes:altAttrs];

    NSString *unit = [self unitLabel];
    NSDictionary *unitAttrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:16.0 weight:UIFontWeightMedium],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.55 alpha:1.0],
    };
    CGSize unitSize = [unit sizeWithAttributes:unitAttrs];

    UIImageSymbolConfiguration *mountainCfg = [UIImageSymbolConfiguration configurationWithPointSize:15.0
                                                                                              weight:UIImageSymbolWeightSemibold];
    UIImage *mountain = [UIImage systemImageNamed:@"mountain.2.fill" withConfiguration:mountainCfg];
    if (mountain) {
        mountain = [mountain imageWithTintColor:OTAltimeterGraphBlue()
                                  renderingMode:UIImageRenderingModeAlwaysOriginal];
    }
    CGFloat mountainSide = 16.0;
    CGFloat unitRowGap = 5.0;
    CGFloat unitRowWidth = unitSize.width + unitRowGap + mountainSide;
    CGFloat unitRowX = center.x - unitRowWidth / 2.0;
    CGFloat unitRowY = center.y + altSize.height / 2.0 - 6.0;

    [unit drawAtPoint:CGPointMake(unitRowX, unitRowY) withAttributes:unitAttrs];
    if (mountain) {
        CGRect mountainRect = CGRectMake(unitRowX + unitSize.width + unitRowGap,
                                       unitRowY + (unitSize.height - mountainSide) / 2.0,
                                       mountainSide,
                                       mountainSide);
        [mountain drawInRect:mountainRect];
    }

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

    NSArray<NSNumber *> *samples = self.altitudeHistoryMeters;
    if (samples.count < 2) {
        if (!isnan(self.altitudeMeters)) {
            samples = @[@(self.altitudeMeters), @(self.altitudeMeters)];
        } else {
            return;
        }
    }

    NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithCapacity:samples.count];
    for (NSNumber *n in samples) {
        double m = n.doubleValue;
        if (!isnan(m)) {
            [values addObject:@([self displayAltitudeFromMeters:m])];
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

    [OTAltimeterGraphBlue() setStroke];
    [wave stroke];
}

@end
