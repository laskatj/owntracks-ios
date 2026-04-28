//
//  OTMapFollowHeading.m
//  OwnTracks
//

#import "OTMapFollowHeading.h"

#import <math.h>

double OTMaxFollowMapCameraPitch(void) {
    return 60.0;
}

static const double kMovingVelThreshold_m_s   = 0.5;
static const double kMovingDistThreshold_m    = 5.0;
static const double kMinBearingDisplacement_m  = 1.0;

BOOL OTHeadingDegreesValid(double degrees) {
    return isfinite(degrees) && degrees >= 0.0 && degrees <= 360.0;
}

double OTNormalizeHeadingDegrees(double degrees) {
    if (!isfinite(degrees)) {
        return 0.0;
    }
    double x = fmod(degrees, 360.0);
    if (x < 0.0) {
        x += 360.0;
    }
    return x;
}

double OTBearingDegreesBetween(CLLocationCoordinate2D from, CLLocationCoordinate2D to) {
    if (!CLLocationCoordinate2DIsValid(from) || !CLLocationCoordinate2DIsValid(to)) {
        return NAN;
    }
    double φ1 = from.latitude * M_PI / 180.0;
    double φ2 = to.latitude * M_PI / 180.0;
    double Δλ = (to.longitude - from.longitude) * M_PI / 180.0;

    double y = sin(Δλ) * cos(φ2);
    double x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ);
    if (fabs(y) < 1e-14 && fabs(x) < 1e-14) {
        return NAN;
    }
    double θ = atan2(y, x);
    double deg = θ * 180.0 / M_PI;
    return OTNormalizeHeadingDegrees(deg);
}

static BOOL OTCoordUsable(CLLocationCoordinate2D c) {
    if (!CLLocationCoordinate2DIsValid(c)) {
        return NO;
    }
    if (c.latitude == 0.0 && c.longitude == 0.0) {
        return NO;
    }
    return YES;
}

static BOOL OTIsMoving(NSDictionary *liveUserInfo,
                       CLLocationCoordinate2D coord,
                       CLLocationCoordinate2D prev) {
    NSNumber *velNum = liveUserInfo[@"vel"];
    if ([velNum isKindOfClass:[NSNumber class]]) {
        double v = velNum.doubleValue;
        if (isfinite(v) && v >= kMovingVelThreshold_m_s) {
            return YES;
        }
    }

    if (OTCoordUsable(prev)) {
        CLLocation *a = [[CLLocation alloc] initWithLatitude:prev.latitude longitude:prev.longitude];
        CLLocation *b = [[CLLocation alloc] initWithLatitude:coord.latitude longitude:coord.longitude];
        if ([a distanceFromLocation:b] >= kMovingDistThreshold_m) {
            return YES;
        }
    }

    return NO;
}

double OTEffectiveFollowMapHeading(NSDictionary *liveUserInfo,
                                   CLLocationCoordinate2D coord,
                                   CLLocationCoordinate2D *inOutPrev) {
    if (!inOutPrev || !OTCoordUsable(coord)) {
        return NAN;
    }

    CLLocationCoordinate2D prev = *inOutPrev;
    BOOL moving = OTIsMoving(liveUserInfo, coord, prev);

    NSNumber *cogNum = liveUserInfo[@"cog"];
    double cog = ([cogNum isKindOfClass:[NSNumber class]]) ? cogNum.doubleValue : NAN;
    BOOL cogOk = OTHeadingDegreesValid(cog);

    double heading = NAN;
    if (moving) {
        if (cogOk) {
            heading = OTNormalizeHeadingDegrees(cog);
        } else if (OTCoordUsable(prev)) {
            CLLocation *a = [[CLLocation alloc] initWithLatitude:prev.latitude longitude:prev.longitude];
            CLLocation *b = [[CLLocation alloc] initWithLatitude:coord.latitude longitude:coord.longitude];
            if ([a distanceFromLocation:b] >= kMinBearingDisplacement_m) {
                heading = OTBearingDegreesBetween(prev, coord);
            }
        }
    }

    *inOutPrev = coord;
    return heading;
}
