# Essential Features Extract for Clean Fork

## 1. App Identifier (CRITICAL - Keep Same for TestFlight)
```
Bundle Identifier: org.mqttitude.MQTTitude
Location: PROJECT_SETTINGS -> PRODUCT_BUNDLE_IDENTIFIER
```

## 2. Status Publishing Method (OwnTracking.m)

### Method Declaration (OwnTracking.h):
```objc
- (void)publishStatus:(BOOL)isActive;
```

### Method Implementation (OwnTracking.m):
```objc
- (void)publishStatus:(BOOL)isActive {
    // Only publish user_status when app is in foreground
    UIApplicationState appState = [UIApplication sharedApplication].applicationState;
    if (appState != UIApplicationStateActive) {
        DDLogInfo(@"[OwnTracking] Skipping publishStatus: app not in foreground (state: %ld)", (long)appState);
        return;
    }
    
    NSString *tid = [Settings stringForKey:@"tid_preference" inMOC:CoreData.sharedInstance.mainMOC];
    NSString *topic = [Settings theGeneralTopicInMOC:CoreData.sharedInstance.mainMOC];
    
    if (!tid || !topic || !self.connection.session) {
        DDLogWarn(@"[OwnTracking] Skipping publishStatus: missing tid, topic, or connection");
        return;
    }
    
    NSString *statusTopic = [topic stringByAppendingString:@"/user_status"];
    
    NSMutableDictionary *json = [[NSMutableDictionary alloc] init];
    json[@"_type"] = @"user_status";
    json[@"tid"] = tid;
    json[@"isActive"] = @(isActive);
    json[@"timestamp"] = @((long long)([[NSDate date] timeIntervalSince1970] * 1000));
    
    [self.connection sendData:[self jsonToData:json]
                        topic:statusTopic
                   topicAlias:@(7)
                          qos:[Settings intForKey:@"qos_preference" inMOC:CoreData.sharedInstance.mainMOC]
                       retain:NO];
    
    DDLogInfo(@"[OwnTracking] Published user_status (%@) to %@ (app state: %ld)", isActive ? @"active" : @"inactive", statusTopic, (long)appState);
}
```

## 3. Config Publishing Method (OwnTracksAppDelegate.m)

### Method Implementation:
```objc
- (void)status {
    NSMutableDictionary *json = [[NSMutableDictionary alloc] init];
    json[@"_type"] = @"status";

    NSMutableDictionary *iOS = [NSMutableDictionary dictionary];
    
    iOS[@"version"] = [NSBundle mainBundle].infoDictionary[@"CFBundleVersion"];
    iOS[@"locale"] = [NSLocale currentLocale].localeIdentifier;
    iOS[@"localeUsesMetricSystem"] = [NSNumber numberWithBool:[NSLocale currentLocale].usesMetricSystem];

    UIBackgroundRefreshStatus status = [UIApplication sharedApplication].backgroundRefreshStatus;
    switch (status) {
        case UIBackgroundRefreshStatusAvailable:
            iOS[@"backgroundRefreshStatus"] = @"UIBackgroundRefreshStatusAvailable";
            break;
        case UIBackgroundRefreshStatusDenied:
            iOS[@"backgroundRefreshStatus"] = @"UIBackgroundRefreshStatusDenied";
            break;
        case UIBackgroundRefreshStatusRestricted:
            iOS[@"backgroundRefreshStatus"] = @"UIBackgroundRefreshStatusRestricted";
            break;
    }
    
    switch([LocationManager sharedInstance].locationManagerAuthorizationStatus) {
        case kCLAuthorizationStatusNotDetermined:
            iOS[@"locationManagerAuthorizationStatus"] = @"kCLAuthorizationStatusNotDetermined";
            break;
        case kCLAuthorizationStatusRestricted:
            iOS[@"locationManagerAuthorizationStatus"] = @"kCLAuthorizationStatusRestricted";
            break;
        case kCLAuthorizationStatusDenied:
            iOS[@"locationManagerAuthorizationStatus"] = @"kCLAuthorizationStatusDenied";
            break;
        case kCLAuthorizationStatusAuthorizedAlways:
            iOS[@"locationManagerAuthorizationStatus"] = @"kCLAuthorizationStatusAuthorizedAlways";
            break;
        case kCLAuthorizationStatusAuthorizedWhenInUse:
            iOS[@"locationManagerAuthorizationStatus"] = @"kCLAuthorizationStatusAuthorizedWhenInUse";
            break;
    }
    
    switch([LocationManager sharedInstance].altimeterAuthorizationStatus) {
        case CMAuthorizationStatusDenied:
            iOS[@"altimeterAuthorizationStatus"] = @"CMAuthorizationStatusDenied";
            break;
        case CMAuthorizationStatusAuthorized:
            iOS[@"altimeterAuthorizationStatus"] = @"CMAuthorizationStatusAuthorized";
            break;
        case CMAuthorizationStatusRestricted:
            iOS[@"altimeterAuthorizationStatus"] = @"CMAuthorizationStatusRestricted";
            break;
        case CMAuthorizationStatusNotDetermined:
            iOS[@"altimeterAuthorizationStatus"] = @"CMAuthorizationStatusNotDetermined";
            break;
    }
    
    iOS[@"altimeterIsRelativeAltitudeAvailable"] = @([LocationManager sharedInstance].altimeterIsRelativeAltitudeAvailable);
    
    switch([LocationManager sharedInstance].motionActivityManagerAuthorizationStatus) {
        case CMAuthorizationStatusDenied:
            iOS[@"motionActivityManagerAuthorizationStatus"] = @"CMAuthorizationStatusDenied";
            break;
        case CMAuthorizationStatusAuthorized:
            iOS[@"motionActivityManagerAuthorizationStatus"] = @"CMAuthorizationStatusAuthorized";
            break;
        case CMAuthorizationStatusRestricted:
            iOS[@"motionActivityManagerAuthorizationStatus"] = @"CMAuthorizationStatusRestricted";
            break;
        case CMAuthorizationStatusNotDetermined:
            iOS[@"motionActivityManagerAuthorizationStatus"] = @"CMAuthorizationStatusNotDetermined";
            break;
    }
    
    iOS[@"motionActivityManagerIsActivityAvailable"] = @([LocationManager sharedInstance].motionActivityManagerIsActivityAvailable);
    
    switch([UIDevice currentDevice].userInterfaceIdiom) {
        case UIUserInterfaceIdiomPhone:
            iOS[@"deviceUserInterfaceIdiom"] = @"UIUserInterfaceIdiomPhone";
            break;
        case UIUserInterfaceIdiomPad:
            iOS[@"deviceUserInterfaceIdiom"] = @"UIUserInterfaceIdiomPad";
            break;
        case UIUserInterfaceIdiomTV:
            iOS[@"deviceUserInterfaceIdiom"] = @"UIUserInterfaceIdiomTV";
            break;
        case UIUserInterfaceIdiomCarPlay:
            iOS[@"deviceUserInterfaceIdiom"] = @"UIUserInterfaceIdiomCarPlay";
            break;
        case UIUserInterfaceIdiomMac:
            iOS[@"deviceUserInterfaceIdiom"] = @"UIUserInterfaceIdiomMac";
            break;
        case UIUserInterfaceIdiomVision:
            iOS[@"deviceUserInterfaceIdiom"] = @"UIUserInterfaceIdiomVision";
            break;
    }

    json[@"iOS"] = iOS;
    
    [self.connection sendData:[self jsonToData:json]
                        topic:[[Settings theGeneralTopicInMOC:CoreData.sharedInstance.mainMOC] stringByAppendingString:@"/device_status"]
                   topicAlias:@(8)
                          qos:[Settings intForKey:@"qos_preference" inMOC:CoreData.sharedInstance.mainMOC]
                       retain:NO];
}
```

## 4. App Lifecycle Triggers

### In applicationDidBecomeActive:
```objc
- (void)applicationDidBecomeActive:(UIApplication *)application {
    DDLogInfo(@"[OwnTracksAppDelegate] applicationDidBecomeActive");
    [[OwnTracking sharedInstance] publishStatus:YES];
    // ... other code
}
```

### In didFinishLaunchingWithOptions:
```objc
// Publish initial status after a short delay to ensure connection is established
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [self status];
    [[OwnTracking sharedInstance] publishStatus:YES];
});
```

### In applicationWillResignActive:
```objc
- (void)applicationWillResignActive:(UIApplication *)application {
    DDLogInfo(@"[OwnTracksAppDelegate] applicationWillResignActive");
    [[OwnTracking sharedInstance] publishStatus:NO];
}
```

## 5. Required Helper Method

### jsonToData method (if not already present):
```objc
- (NSData *)jsonToData:(NSDictionary *)json {
    NSError *error;
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
    if (error) {
        DDLogError(@"[OwnTracksAppDelegate] JSON serialization error: %@", error);
        return nil;
    }
    return data;
}
```

## 6. Custom App Icons and Name

### App Icons Location:
- Standard iOS app icons should be in: `Assets.xcassets/AppIcon.appiconset/`
- Replace with your custom icons

### App Name:
- Change `CFBundleDisplayName` and `CFBundleName` in Info.plist
- Or change `PRODUCT_NAME` in project settings

## 7. Dependencies Required

Make sure these frameworks are linked:
- Foundation.framework
- UIKit.framework
- CoreLocation.framework
- CoreMotion.framework
- UserNotifications.framework (if using notifications)

## 8. Settings Keys Used

The methods reference these settings keys:
- `tid_preference` - Device identifier
- `qos_preference` - MQTT QoS level
- `theGeneralTopicInMOC` - MQTT topic prefix

Make sure these are defined in your Settings class or equivalent configuration system.

## 9. Payload Examples

### User Status Payload:
```json
{
  "_type": "user_status",
  "tid": "device123",
  "isActive": true,
  "timestamp": 1704067200000
}
```

### Device Status Payload:
```json
{
  "_type": "status",
  "iOS": {
    "version": "18.5.2",
    "locale": "en_US",
    "localeUsesMetricSystem": true,
    "backgroundRefreshStatus": "UIBackgroundRefreshStatusAvailable",
    "locationManagerAuthorizationStatus": "kCLAuthorizationStatusAuthorizedAlways",
    "altimeterAuthorizationStatus": "CMAuthorizationStatusAuthorized",
    "altimeterIsRelativeAltitudeAvailable": true,
    "motionActivityManagerAuthorizationStatus": "CMAuthorizationStatusAuthorized",
    "motionActivityManagerIsActivityAvailable": true,
    "deviceSystemName": "iOS",
    "deviceSystemVersion": "17.2.1",
    "deviceModel": "iPhone",
    "deviceIdentifierForVendor": "12345678-1234-1234-1234-123456789ABC",
    "deviceUserInterfaceIdiom": "UIUserInterfaceIdiomPhone"
  }
}
```

### Publishing Details:
- **User Status Topic:** `{your_topic}/user_status`
- **Device Status Topic:** `{your_topic}/device_status`
- **User Status Topic Alias:** 7
- **Device Status Topic Alias:** 8
- **QoS:** Based on your qos_preference setting
- **Retain:** false for both


