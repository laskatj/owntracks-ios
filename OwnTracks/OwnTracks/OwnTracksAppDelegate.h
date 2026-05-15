//
//  OwnTracksAppDelegate.h
//  OwnTracks
//
//  Created by Christoph Krey on 03.02.14.
//  Copyright © 2014-2025  OwnTracks. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreMotion/CoreMotion.h>

#import <UserNotifications/UNUserNotificationCenter.h>

#import "LocationManager.h"
#import "Connection.h"
#import "Settings.h"

#import "Friend+CoreDataClass.h"
#import "Region+CoreDataClass.h"

#import "NavigationController.h"

#import <CocoaLumberjack/CocoaLumberjack.h>

/// Reasons for `requestHUDAwakeWhileChargingWithReason:` / `releaseHUDAwakeWhileChargingWithReason:`.
FOUNDATION_EXPORT NSString * _Nonnull const OTHUDIdleTimerReasonMap;
FOUNDATION_EXPORT NSString * _Nonnull const OTHUDIdleTimerReasonDeviceDetail;

@interface OwnTracksAppDelegate : UIResponder <UIApplicationDelegate, ConnectionDelegate, LocationManagerDelegate, UNUserNotificationCenterDelegate>

@property (strong, nonatomic) UIWindow * _Nullable window;

@property (strong, nonatomic) NSString * _Nullable processingMessage;

@property (strong, nonatomic) Connection * _Nullable connection;
@property (strong, nonatomic) NSNumber * _Nullable connectionState;
@property (strong, nonatomic) NSNumber * _Nullable connectionBuffered;

@property (strong, nonatomic) NSDate * _Nullable configLoad;
@property (strong, nonatomic) NSString * _Nullable action;
@property (nonatomic) BOOL inRefresh;

#define MAXIMUM_NUMBER_OF_LOG_FILES 5
@property (strong, nonatomic) DDFileLogger * _Nullable fl;
@property (strong, nonatomic) NSNumber * _Nonnull inQueue;

- (BOOL)sendNow:(CLLocation *_Nonnull)location
        withPOI:(nullable NSString *)poi
      withImage:(nullable NSData *)image
  withImageName:(nullable NSString *)imageName;
- (void)dump;
/// Same payload as `dump` but with an explicit MQTT QoS (used for startup config beacon at QoS 2).
- (void)dumpWithQoS:(NSInteger)qos;
- (void)status;
- (void)waypoints;
- (void)sendRegion:(nonnull Region *)region;
- (void)sendEmpty:(nonnull NSString *)topic;
- (void)reconnect;
- (void)connectionOff;
- (void)terminateSession;
- (void)syncProcessing;
- (void)configFromDictionary:(NSDictionary * _Nonnull)json;
- (BOOL)processNSURL:(NSURL * _Nonnull)url;
/// Handles `owntracks://` and `sauron://` URLs (beacon, config, auth callback). Used from `application:openURL:` and from `WebAppViewController` when WKWebView navigates to those schemes.
- (BOOL)handleOwnTracksSchemeURL:(NSURL * _Nonnull)url;

/// Map / friend-detail HUD: keep the screen awake while plugged in or full, only when the app is active.
- (void)requestHUDAwakeWhileChargingWithReason:(NSString * _Nonnull)reason;
- (void)releaseHUDAwakeWhileChargingWithReason:(NSString * _Nonnull)reason;

@end
