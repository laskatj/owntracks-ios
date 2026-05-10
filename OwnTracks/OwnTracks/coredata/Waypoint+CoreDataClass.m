//
//  Waypoint+CoreDataClass.m
//  OwnTracks
//
//  Created by Christoph Krey on 30.05.18.
//  Copyright © 2018-2025 OwnTracks. All rights reserved.
//
//

#import "Waypoint+CoreDataClass.h"
#import "Friend+CoreDataClass.h"
#import <MapKit/MapKit.h>
#import <Contacts/Contacts.h>
#import "CoreData.h"
#import "LocationManager.h"

static NSString *OTDisplayStringForConn(NSString *conn) {
    NSString *trimmed = [conn stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) {
        return NSLocalizedString(@"Unknown", @"Network connection type when conn field is missing");
    }
    NSString *low = trimmed.lowercaseString;
    if ([low isEqualToString:@"w"] || [low isEqualToString:@"wifi"] || [low isEqualToString:@"wlan"]) {
        return NSLocalizedString(@"Wi-Fi", @"Network connection type: Wi-Fi");
    }
    if ([low isEqualToString:@"m"] || [low isEqualToString:@"wwan"] || [low isEqualToString:@"cellular"] || [low isEqualToString:@"mobile"]) {
        return NSLocalizedString(@"Cellular", @"Network connection type: cellular data");
    }
    if ([low isEqualToString:@"o"] || [low isEqualToString:@"offline"] || [low isEqualToString:@"none"]) {
        return NSLocalizedString(@"No connection", @"Network connection type: device had no data connection");
    }
    if (trimmed.length > 1) {
        return trimmed;
    }
    return [NSString stringWithFormat:NSLocalizedString(@"Unknown (%@)", @"Network connection type with raw code from device"), trimmed];
}

static NSString *OTDisplayStringForTrigger(NSString *trigger) {
    if (!trigger.length) {
        return NSLocalizedString(@"Automatic", @"Location publish trigger: implicit location update");
    }
    if ([trigger isEqualToString:@"C"]) {
        return NSLocalizedString(@"Follow region", @"Location trigger: left +follow moving geofence");
    }
    NSString *low = trigger.lowercaseString;
    if ([low isEqualToString:@"p"]) {
        return NSLocalizedString(@"After refresh", @"Location trigger: publish after configuration refresh");
    }
    if ([low isEqualToString:@"t"]) {
        return NSLocalizedString(@"Interval timer", @"Location trigger: periodic timer");
    }
    if ([low isEqualToString:@"v"]) {
        return NSLocalizedString(@"Visit", @"Location trigger: iOS visit service");
    }
    if ([low isEqualToString:@"b"]) {
        return NSLocalizedString(@"iBeacon region", @"Location trigger: iBeacon geofence");
    }
    if ([low isEqualToString:@"c"]) {
        return NSLocalizedString(@"Circular region", @"Location trigger: circular geofence");
    }
    if ([low isEqualToString:@"u"]) {
        return NSLocalizedString(@"Manual send", @"Location trigger: user tapped send");
    }
    if ([low isEqualToString:@"r"]) {
        return NSLocalizedString(@"Report", @"Location trigger: report location command");
    }
    if ([low isEqualToString:@"g"]) {
        return NSLocalizedString(@"GPS", @"Location trigger: GPS update (common on other clients)");
    }
    if ([low isEqualToString:@"i"]) {
        return NSLocalizedString(@"Ping", @"Location trigger: ping");
    }
    if (trigger.length > 1) {
        return trigger;
    }
    return [NSString stringWithFormat:NSLocalizedString(@"Other (%@)", @"Location trigger: unknown single-letter code"), trigger];
}

@implementation Waypoint

- (void)getReverseGeoCode {
    if (!self.placemark) {
        CLGeocoder *geocoder = [[CLGeocoder alloc] init];
        CLLocation *location = [[CLLocation alloc] initWithLatitude:(self.lat).doubleValue
                                                          longitude:(self.lon).doubleValue];
        [geocoder reverseGeocodeLocation:location completionHandler:
         ^(NSArray *placemarks, NSError *error) {
             [self.managedObjectContext performBlock:^{
                 if (!self.isDeleted) {
                     if (placemarks.count > 0) {
                         CLPlacemark *placemark = placemarks[0];
                         CNPostalAddress *postalAddress = placemark.postalAddress;
                         self.placemark = [CNPostalAddressFormatter
                                           stringFromPostalAddress:postalAddress
                                           style:CNPostalAddressFormatterStyleMailingAddress];
                     } else {
                         self.placemark = [NSString stringWithFormat:@"%@\n%@ %ld\n%@",
                                           NSLocalizedString(@"Address resolver failed", @"reverseGeocodeLocation error"),
                                           error.domain,
                                           (long)error.code,
                                           NSLocalizedString(@"due to rate limit or off-line", @"reverseGeocodeLocation text")
                                           ];
                     }
                     self.belongsTo.topic = self.belongsTo.topic;
                     [CoreData.sharedInstance sync:self.managedObjectContext];
                 }
             }];
         }];
    }
}

- (CLLocationDistance)getDistanceFrom:(CLLocation *)fromLocation {
    CLLocation *location = [[CLLocation alloc] initWithLatitude:(self.lat).doubleValue
                                                      longitude:(self.lon).doubleValue];
    return [location distanceFromLocation:fromLocation];
}

- (NSString *)shortCoordinateText {
    return [NSString stringWithFormat:@"%g,%g",
            (self.lat).doubleValue,
            (self.lon).doubleValue
            ];
}

+ (NSString *)CLLocationAccuracyText:(CLLocation *)location {
    if (location && 
        CLLocationCoordinate2DIsValid(location.coordinate) &&
        location.horizontalAccuracy >= 0.0) {
        NSMeasurement *m = [[NSMeasurement alloc] initWithDoubleValue:location.horizontalAccuracy
                                                                 unit:[NSUnitLength meters]];
        NSMeasurementFormatter *mf = [[NSMeasurementFormatter alloc] init];
        mf.unitOptions = NSMeasurementFormatterUnitOptionsNaturalScale;
        mf.numberFormatter.maximumFractionDigits = 0;
        
        return [NSString stringWithFormat:@"±%@",
                [mf stringFromMeasurement:m]];
    } else {
        return @"-";
    }
}

+ (NSString *)CLLocationCoordinateText:(CLLocation *)location {
    if (location && CLLocationCoordinate2DIsValid(location.coordinate)) {
        return [NSString stringWithFormat:@"%g,%g (%@)",
                location.coordinate.latitude,
                location.coordinate.longitude,
                [Waypoint CLLocationAccuracyText:location]];
    } else {
        return @"-";
    }
}

- (NSString *)coordinateText {
    CLLocation *location = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake((self.lat).doubleValue,
                                                                                             (self.lon).doubleValue)
                                                         altitude:(self.alt).doubleValue
                                               horizontalAccuracy:(self.acc).doubleValue
                                                 verticalAccuracy:(self.vac).doubleValue
                                                        timestamp:self.tst];
    return [Waypoint CLLocationCoordinateText:location];
}

- (NSString *)timestampText {
    return [NSDateFormatter localizedStringFromDate:self.tst
                                          dateStyle:NSDateFormatterShortStyle
                                          timeStyle:NSDateFormatterMediumStyle];
}

- (NSString *)createdAtText {
    return [NSDateFormatter localizedStringFromDate:self.createdAt
                                          dateStyle:NSDateFormatterShortStyle
                                          timeStyle:NSDateFormatterMediumStyle];
}

- (NSDate *)effectiveTimestamp {
    if (self.createdAt != nil &&
        self.createdAt.timeIntervalSince1970 > self.tst.timeIntervalSince1970) {
        return self.createdAt;
    }
    return self.tst;
}

- (NSString *)infoText {
    NSMeasurement *mAlt = [[NSMeasurement alloc] initWithDoubleValue:(self.alt).doubleValue
                                                                unit:[NSUnitLength meters]];
    NSMeasurement *mVac = [[NSMeasurement alloc] initWithDoubleValue:(self.vac).doubleValue
                                                                unit:[NSUnitLength meters]];
    NSMeasurement *mVel = [[NSMeasurement alloc] initWithDoubleValue:(self.vel).doubleValue
                                                                unit:[NSUnitSpeed kilometersPerHour]];
    NSMeasurement *mCog = [[NSMeasurement alloc] initWithDoubleValue:(self.cog).doubleValue
                                                                unit:[NSUnitAngle degrees]];

    NSMeasurementFormatter *mf = [[NSMeasurementFormatter alloc] init];
    mf.unitOptions = NSMeasurementFormatterUnitOptionsNaturalScale;
    mf.numberFormatter.maximumFractionDigits = 0;

    return [NSString stringWithFormat:@"%@ (%@) %@ %@",
            (self.vac).doubleValue > 0.0 ?
            [NSString stringWithFormat:@"✈︎%@",
             [mf stringFromMeasurement:mAlt]] :
                @"-",
            (self.vac).doubleValue > 0.0 ?
            [NSString stringWithFormat:@"±%@",
             [mf stringFromMeasurement:mVac]] :
                @"-",
            (self.vel).doubleValue >= 0.0 ? 
            [mf stringFromMeasurement:mVel] :
                @"-",
            (self.cog).doubleValue >= 0.0 ?
            [mf stringFromMeasurement:mCog] :
                @"-"
            ];
}

+ (NSString *)distanceText:(CLLocationDistance)distance {
    NSMeasurement *m = [[NSMeasurement alloc] initWithDoubleValue:distance
                                                             unit:[NSUnitLength meters]];
    NSMeasurementFormatter *mf = [[NSMeasurementFormatter alloc] init];
    mf.unitOptions = NSMeasurementFormatterUnitOptionsNaturalScale;
    mf.numberFormatter.maximumFractionDigits = 0;

    return [mf stringFromMeasurement:m];
}

- (NSString *)triggerText {
    return OTDisplayStringForTrigger(self.trigger);
}

- (NSString *)monitoringText {
    if (self.m) {
        switch (self.m.integerValue) {
            case LocationMonitoringMove:
                return NSLocalizedString(@"Move", @"Move");
            case LocationMonitoringSignificant:
                return NSLocalizedString(@"Significant", @"Significant");
            case LocationMonitoringManual:
                return NSLocalizedString(@"Manual", @"Manual");
            case LocationMonitoringQuiet:
                return NSLocalizedString(@"Quiet", @"Quiet");
            default:
                return self.m.stringValue;
        }
    } else {
        return @"-";
    }
}

- (NSString *)connectionText {
    return OTDisplayStringForConn(self.conn);
}

- (NSString *)batteryStatusText {
    if (self.bs) {
        switch (self.bs.integerValue) {
            case 3:
                return NSLocalizedString(@"full", @"Battery status full");
            case 2:
                return NSLocalizedString(@"charging", @"Battery status charging");

            case 1:
                return NSLocalizedString(@"unplugged", @"Battery status unplugged");

            case 0:
            default:
                return NSLocalizedString(@"unknown", @"Battery status unknown");
        }
    } else {
        return @"-";
    }
}

- (NSString *)batteryLevelText {
    if (self.batt && self.batt.doubleValue >= 0.0) {
        NSString *text = [NSString stringWithFormat:@"%0.f%%",
                          (self.batt).doubleValue * 100.0
                          ];
        return text;
    } else {
        return @"-";
    }
}

- (NSString *)defaultPlacemark {
    return [NSString stringWithFormat:@"%@\n%@",
            NSLocalizedString(@"Address resolver disabled", @"Address resolver disabled"),
            self.coordinateText];
}

#pragma MKAnnotation

- (void)setCoordinate:(CLLocationCoordinate2D)newCoordinate {
    //
}

- (CLLocationCoordinate2D)coordinate {
    return CLLocationCoordinate2DMake((self.lat).doubleValue, (self.lon).doubleValue);
}

- (NSString *)title {
    return self.poi ? self.poi : self.placemark ? self.placemark : self.shortCoordinateText;
}

- (NSString *)subtitle {
    return self.poi ? self.placemark : nil;
}

@end
