//
//  OwnTracksWatchBridge.m
//

#import "OwnTracksWatchBridge.h"
#import "Settings.h"
#import "CoreData.h"
#import <WatchConnectivity/WatchConnectivity.h>
#import <CocoaLumberjack/CocoaLumberjack.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

@interface OwnTracksWatchBridge () <WCSessionDelegate>
@end

@implementation OwnTracksWatchBridge

+ (instancetype)shared {
    static OwnTracksWatchBridge *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[self alloc] init];
    });
    return s;
}

- (void)activate {
    if (![WCSession isSupported]) {
        DDLogInfo(@"[OwnTracksWatchBridge] WatchConnectivity not supported");
        return;
    }
    WCSession *session = [WCSession defaultSession];
    session.delegate = self;
    [session activateSession];
}

- (void)pushConfigToWatchIfNeeded {
    if (![WCSession isSupported]) {
        return;
    }
    WCSession *session = [WCSession defaultSession];
    if (session.activationState != WCSessionActivationStateActivated) {
        return;
    }
    NSManagedObjectContext *moc = CoreData.sharedInstance.mainMOC;
    NSString *url = [Settings stringForKey:@"url_preference" inMOC:moc];
    if (!url.length) {
        DDLogVerbose(@"[OwnTracksWatchBridge] no url_preference; skip push");
        return;
    }

    BOOL usePassword = [Settings theMqttUsePasswordInMOC:moc];
    NSString *password = @"";
    if (usePassword) {
        password = [Settings theMqttPassInMOC:moc] ?: @"";
    }

    NSString *user = [Settings theMqttUserInMOC:moc] ?: @"user";
    NSString *device = [Settings theDeviceIdInMOC:moc] ?: @"device";
    NSString *publishTopic = [Settings theGeneralTopicInMOC:moc] ?: @"";
    NSString *headers = [Settings stringForKey:@"httpheaders_preference" inMOC:moc] ?: @"";
    NSString *tid = [Settings stringForKey:@"trackerid_preference" inMOC:moc] ?: @"";
    BOOL extended = [Settings boolForKey:@"extendeddata_preference" inMOC:moc];
    NSString *oauthClient = [Settings stringForKey:@"oauth_client_id_preference" inMOC:moc] ?: @"";

    NSDictionary *payload = @{
        @"httpURL": url,
        @"authBasic": @([Settings theMqttAuthInMOC:moc]),
        @"user": user,
        @"pass": password,
        @"limitU": user,
        @"limitD": device,
        @"deviceId": device,
        @"publishTopic": publishTopic,
        @"httpHeaderLines": headers,
        @"trackerId": tid.length ? tid : [NSNull null],
        @"includeExtendedData": @(extended),
        @"oauthClientId": oauthClient.length ? oauthClient : [NSNull null],
        @"oauthRefreshURL": [NSNull null]
    };

    NSMutableDictionary *sanitized = [payload mutableCopy];
    for (id key in [sanitized allKeys]) {
        id v = sanitized[key];
        if (v == [NSNull null]) {
            [sanitized removeObjectForKey:key];
        }
    }

    NSError *err = nil;
    if (![session updateApplicationContext:sanitized error:&err]) {
        DDLogWarn(@"[OwnTracksWatchBridge] updateApplicationContext failed: %@ — trying transferUserInfo", err);
        [session transferUserInfo:sanitized];
    } else {
        DDLogInfo(@"[OwnTracksWatchBridge] pushed watch HTTP config (applicationContext)");
    }
}

#pragma mark - WCSessionDelegate

- (void)session:(WCSession *)session
activationDidCompleteWithState:(WCSessionActivationState)activationState
                          error:(NSError *)error {
    if (error) {
        DDLogWarn(@"[OwnTracksWatchBridge] activation error %@", error);
        return;
    }
    if (activationState == WCSessionActivationStateActivated) {
        [self pushConfigToWatchIfNeeded];
    }
}

- (void)sessionDidBecomeInactive:(WCSession *)session {
}

- (void)sessionDidDeactivate:(WCSession *)session {
    [session activateSession];
}

- (void)sessionWatchStateDidChange:(WCSession *)session {
    if (session.paired && session.watchAppInstalled) {
        [self pushConfigToWatchIfNeeded];
    }
}

@end
