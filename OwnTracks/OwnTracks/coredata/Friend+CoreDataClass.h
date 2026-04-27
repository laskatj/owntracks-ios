//
//  Friend+CoreDataClass.h
//  OwnTracks
//
//  Created by Christoph Krey on 08.12.16.
//  Copyright © 2016-2025  OwnTracks. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import <MapKit/MapKit.h>
#import <AddressBook/AddressBook.h>

@class Location, Region, Subscription, Waypoint;

NS_ASSUME_NONNULL_BEGIN

@interface Friend : NSManagedObject <MKAnnotation, MKOverlay>

@property (nonatomic) CLLocationCoordinate2D coordinate;
- (void)setLiveCoordinate:(CLLocationCoordinate2D)coord;

+ (Friend * _Nullable)existsFriendWithTopic:(NSString *)topic
           inManagedObjectContext:(NSManagedObjectContext *)context;

+ (Friend *)friendWithTopic:(NSString *)topic
     inManagedObjectContext:(NSManagedObjectContext *)context;

+ (NSString * _Nullable)nameOfPerson:(NSString *)contactId;
+ (NSData * _Nullable)imageDataOfPerson:(NSString *)contactId;

+ (void)deleteAllFriendsInManagedObjectContext:(NSManagedObjectContext *)context;
+ (NSArray *)allFriendsInManagedObjectContext:(NSManagedObjectContext *)context;
+ (NSArray *)allNonStaleFriendsInManagedObjectContext:(NSManagedObjectContext *)context;

- (Waypoint *)addWaypoint:(nonnull CLLocation *)location
createdAt:(nullable NSDate *)createdAt
trigger:(nullable NSString *)trigger
poi:(nullable NSString *)poi
tag:(nullable NSString *)tag
battery:(nullable NSNumber *)battery
image:(nullable NSData *)image
imageName:(nullable NSString *)imageName
inRegions:(nullable NSArray <NSString *> *)inRegions
inRids:(nullable NSArray <NSString *> *)inRids
bssid:(nullable NSString *)bssid
ssid:(nullable NSString *)ssid
m:(nullable NSNumber *)m
conn:(nullable NSString *)conn
bs:(nullable NSNumber *)bs
pressure:(nullable NSNumber *)pressure
motionActivities:(nullable NSArray <NSString *> *)motionActivities
zoneName:(nullable NSString *)zoneName;

- (NSInteger)limitWaypointsToMaximum:(NSInteger)max;
- (NSInteger)limitWaypointsToMaximumDays:(NSInteger)days;

- (void)trackToGPX:(NSOutputStream *)output;

@property (NS_NONATOMIC_IOSONLY, readonly, copy) NSString * _Nonnull name;
@property (NS_NONATOMIC_IOSONLY, readonly, copy) NSString * _Nonnull nameOrTopic;
@property (NS_NONATOMIC_IOSONLY, readonly, copy) NSData * _Nonnull image;

+ (NSString *)effectiveTid:(NSString *)tid device:(NSString *)device;
@property (NS_NONATOMIC_IOSONLY, getter=getEffectiveTid, readonly, copy) NSString * _Nonnull effectiveTid;
@property (NS_NONATOMIC_IOSONLY, readonly, strong) Waypoint * _Nullable newestWaypoint;
@property (NS_NONATOMIC_IOSONLY, readonly, strong) MKPolyline * _Nonnull polyLine;

/// Display user name used in the REST route API path (e.g. "Laska Tom").
/// Set from /api/location response; nil if friend was only seen via MQTT.
@property (nonatomic, copy, nullable) NSString *routeAPIUser;

@end

NS_ASSUME_NONNULL_END

#import "Friend+CoreDataProperties.h"
