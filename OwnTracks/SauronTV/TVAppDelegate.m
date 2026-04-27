//
//  TVAppDelegate.m
//  SauronTV
//
//  Minimal subscribe-only MQTT client for tvOS.
//  Connects to the broker using TVHardcodedConfig.h credentials,
//  subscribes per allowed device topic after GET /api/location, and posts
//  OTLiveFriendLocation notifications for incoming location messages.
//

#import "TVAppDelegate.h"
#import "TVMapViewController.h"
#import "TVFriendsViewController.h"
#import "TVRecorderAuthViewController.h"
#import "TVFriendStore.h"
#import "TVHardcodedConfig.h"
#import "TVLocationDevicesFetcher.h"
#import "TVRecorderOAuthClient.h"

#import <mqttc/MQTTNWTransport.h>
#import <CocoaLumberjack/CocoaLumberjack.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

#define TV_RECONNECT_DELAY 5.0

@interface TVAppDelegate ()
@property (strong, nonatomic) MQTTSession *mqttSession;
@property (strong, nonatomic) NSMutableDictionary<NSString *, NSData *> *cardImages;
@property (nonatomic) BOOL intentionalDisconnect;
@property (copy, nonatomic) NSArray<NSString *> *lastMQTTSubscriptionPatterns;
@end

@implementation TVAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    [DDLog addLogger:[DDOSLogger sharedInstance]];
    DDLogInfo(@"[TVAppDelegate] didFinishLaunchingWithOptions");

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];

    TVMapViewController        *mapVC     = [[TVMapViewController alloc] init];
    TVFriendsViewController    *friendsVC = [[TVFriendsViewController alloc] init];
    TVRecorderAuthViewController *authVC  = [[TVRecorderAuthViewController alloc] init];

    mapVC.tabBarItem = [[UITabBarItem alloc]
        initWithTitle:@"Map"
                image:[UIImage systemImageNamed:@"map"]
                  tag:0];
    friendsVC.tabBarItem = [[UITabBarItem alloc]
        initWithTitle:@"Friends"
                image:[UIImage systemImageNamed:@"person.2"]
                  tag:1];
    authVC.tabBarItem = [[UITabBarItem alloc]
        initWithTitle:@"Recorder"
                image:[UIImage systemImageNamed:@"key.horizontal"]
                  tag:2];

    UITabBarController *tabs  = [[UITabBarController alloc] init];
    tabs.viewControllers      = @[mapVC, friendsVC, authVC];
    self.window.rootViewController = tabs;
    [self.window makeKeyAndVisible];

    [[TVFriendStore shared] start];
    self.lastMQTTSubscriptionPatterns = @[];

    __weak typeof(self) weakSelf = self;
    [self refreshLocationAllowlistPresentingSignInFrom:tabs
                                             completion:^(BOOL success) {
        [weakSelf connectMQTT];
    }];
    return YES;
}

#pragma mark - Location API allowlist

- (NSArray<NSString *> *)mqttSubscriptionPatterns {
    NSMutableArray<NSString *> *p = [NSMutableArray array];
    for (NSString *base in [TVFriendStore shared].allowedBaseMQTTTopics) {
        [p addObject:[NSString stringWithFormat:@"%@/#", base]];
    }
    return [p copy];
}

- (void)subscribePatterns:(NSArray<NSString *> *)patterns
                  session:(MQTTSession *)session {
    for (NSString *pat in patterns) {
        DDLogInfo(@"[TVAppDelegate] MQTT subscribe %@", pat);
        [session subscribeToTopicV5:pat
                            atLevel:MQTTQosLevelAtLeastOnce
                            noLocal:NO
                  retainAsPublished:NO
                     retainHandling:MQTTSendRetained
             subscriptionIdentifier:0
                     userProperties:nil
                   subscribeHandler:nil];
    }
}

- (void)resyncMQTTSubscriptions {
    MQTTSession *s = self.mqttSession;
    if (!s || s.status != MQTTSessionStatusConnected) {
        return;
    }

    NSArray<NSString *> *newPatterns = [self mqttSubscriptionPatterns];
    NSArray<NSString *> *oldPatterns = self.lastMQTTSubscriptionPatterns ?: @[];
    if ([[NSSet setWithArray:oldPatterns] isEqualToSet:[NSSet setWithArray:newPatterns]]) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    if (oldPatterns.count) {
        [s unsubscribeTopicsV5:oldPatterns
                  userProperties:nil
              unsubscribeHandler:^(NSError *error, NSString *reasonString,
                                   NSArray<NSDictionary<NSString *, NSString *> *> *userProperties,
                                   NSArray<NSNumber *> *reasonCodes) {
                  dispatch_async(dispatch_get_main_queue(), ^{
                      __strong typeof(weakSelf) selfStrong = weakSelf;
                      if (!selfStrong) {
                          return;
                      }
                      MQTTSession *sess = selfStrong.mqttSession;
                      if (!sess || sess.status != MQTTSessionStatusConnected) {
                          return;
                      }
                      [selfStrong subscribePatterns:newPatterns session:sess];
                      selfStrong.lastMQTTSubscriptionPatterns = [newPatterns copy];
                  });
              }];
    } else {
        [self subscribePatterns:newPatterns session:s];
        self.lastMQTTSubscriptionPatterns = [newPatterns copy];
    }
}

- (void)refreshLocationAllowlistPresentingSignInFrom:(UIViewController *)pvc
                                          completion:(void (^)(BOOL))completion {
    NSURL *apiURL = [TVLocationDevicesFetcher locationAPIURL];
    if (!apiURL) {
        DDLogInfo(@"[TVAppDelegate] refreshLocationAllowlist: no API URL");
        [[TVFriendStore shared] applyLocationAPIDevices:@[]];
        [self resyncMQTTSubscriptions];
        if (completion) {
            completion(NO);
        }
        return;
    }
    (void)apiURL;

    __weak typeof(self) weakSelf = self;
    [[TVRecorderOAuthClient shared] ensureValidAccessTokenPresentingSignInFrom:pvc
                                                                    completion:^(NSString *token, NSError *err) {
        __strong typeof(weakSelf) selfStrong = weakSelf;
        if (!selfStrong) {
            if (completion) {
                completion(NO);
            }
            return;
        }

        if (!token.length) {
            DDLogInfo(@"[TVAppDelegate] refreshLocationAllowlist: no bearer token (%@)",
                      err.localizedDescription ?: @"");
            [[TVFriendStore shared] applyLocationAPIDevices:@[]];
            [selfStrong resyncMQTTSubscriptions];
            if (completion) {
                completion(NO);
            }
            return;
        }

        [TVLocationDevicesFetcher fetchDevicesWithBearerToken:token
                                                   completion:^(NSArray<TVLocationAPIDevice *> *devices,
                                                                NSError *fetchErr) {
            __strong typeof(weakSelf) ss = weakSelf;
            if (!ss) {
                if (completion) {
                    completion(NO);
                }
                return;
            }
            if (fetchErr || !devices) {
                DDLogInfo(@"[TVAppDelegate] refreshLocationAllowlist: GET failed %@",
                          fetchErr.localizedDescription ?: @"");
                [[TVFriendStore shared] applyLocationAPIDevices:@[]];
                [ss resyncMQTTSubscriptions];
                if (completion) {
                    completion(NO);
                }
                return;
            }
            [[TVFriendStore shared] applyLocationAPIDevices:devices];
            [ss resyncMQTTSubscriptions];
            if (completion) {
                completion(YES);
            }
        }];
    }];
}

#pragma mark - MQTT

- (void)connectMQTT {
    DDLogInfo(@"[TVAppDelegate] connectMQTT %@@%@:%u tls=%d ws=%d",
              kTVMQTTUser, kTVMQTTHost, kTVMQTTPort, kTVMQTTTLS, kTVMQTTWS);

    MQTTNWTransport *transport = [[MQTTNWTransport alloc] init];
    transport.host = kTVMQTTHost;
    transport.port = kTVMQTTPort;
    transport.tls  = kTVMQTTTLS;
    transport.ws   = kTVMQTTWS;

    MQTTSession *session = [[MQTTSession alloc] init];
    session.transport        = transport;
    session.clientId         = kTVMQTTClientId;
    session.userName         = kTVMQTTUser;
    session.password         = kTVMQTTPassword;
    session.keepAliveInterval = 60;
    session.cleanSessionFlag  = YES;
    session.protocolLevel     = MQTTProtocolVersion311;
    session.delegate          = self;

    self.cardImages = [NSMutableDictionary dictionary];
    self.mqttSession = session;
    self.intentionalDisconnect = NO;
    [session connectWithConnectHandler:nil];
}

- (void)scheduleReconnect {
    DDLogInfo(@"[TVAppDelegate] scheduleReconnect in %.0fs", TV_RECONNECT_DELAY);
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(TV_RECONNECT_DELAY * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{ [self connectMQTT]; }
    );
}

#pragma mark - MQTTSessionDelegate

- (void)connected:(MQTTSession *)session sessionPresent:(BOOL)sessionPresent {
    DDLogInfo(@"[TVAppDelegate] MQTT connected sessionPresent=%d", sessionPresent);

    NSArray<NSString *> *patterns = [self mqttSubscriptionPatterns];
    [self subscribePatterns:patterns session:session];
    self.lastMQTTSubscriptionPatterns = [patterns copy];
}

- (void)handleEvent:(MQTTSession *)session
              event:(MQTTSessionEvent)eventCode
              error:(NSError *)error {
    NSString *desc = @{
        @(MQTTSessionEventConnected):              @"connected",
        @(MQTTSessionEventConnectionRefused):      @"refused",
        @(MQTTSessionEventConnectionClosed):       @"closed",
        @(MQTTSessionEventConnectionError):        @"error",
        @(MQTTSessionEventProtocolError):          @"protocol error",
        @(MQTTSessionEventConnectionClosedByBroker): @"closed by broker",
    }[@(eventCode)] ?: [NSString stringWithFormat:@"event(%ld)", (long)eventCode];

    DDLogInfo(@"[TVAppDelegate] MQTT %@ %@", desc, error ?: @"");

    switch (eventCode) {
        case MQTTSessionEventConnectionClosed:
        case MQTTSessionEventConnectionClosedByBroker:
        case MQTTSessionEventConnectionError:
        case MQTTSessionEventConnectionRefused:
        case MQTTSessionEventProtocolError:
            if (!self.intentionalDisconnect) {
                [self scheduleReconnect];
            }
            break;
        default:
            break;
    }
}

- (BOOL)newMessageWithFeedbackV5:(MQTTSession *)session
                            data:(NSData *)data
                         onTopic:(NSString *)topic
                             qos:(MQTTQosLevel)qos
                        retained:(BOOL)retained
                             mid:(unsigned int)mid
          payloadFormatIndicator:(NSNumber *)payloadFormatIndicator
           messageExpiryInterval:(NSNumber *)messageExpiryInterval
                      topicAlias:(NSNumber *)topicAlias
                   responseTopic:(NSString *)responseTopic
                 correlationData:(NSData *)correlationData
                  userProperties:(NSArray<NSDictionary<NSString *,NSString *> *> *)userProperties
                     contentType:(NSString *)contentType
         subscriptionIdentifiers:(NSArray<NSNumber *> *)subscriptionIdentifiers {

    if (!data) {
        return YES;
    }

    NSError *err;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (![json isKindOfClass:[NSDictionary class]]) {
        return YES;
    }

    NSString *baseTopic = [TVFriendStore baseMQTTTopicFromMessageTopic:topic];
    if (![[TVFriendStore shared] isBaseTopicAllowed:baseTopic]) {
        return YES;
    }

    NSDictionary *dict = json;
    NSString *type = dict[@"_type"];
    DDLogInfo(@"[TVAppDelegate] MQTT message topic=%@ _type=%@", topic, type ?: @"(null)");

    if ([type isEqualToString:@"location"]) {
        NSNumber *lat = dict[@"lat"];
        NSNumber *lon = dict[@"lon"];
        if (![lat isKindOfClass:[NSNumber class]] || ![lon isKindOfClass:[NSNumber class]]) {
            return YES;
        }

        NSString *tid = dict[@"tid"];
        NSString *label = (tid && tid.length) ? tid : [baseTopic lastPathComponent];

        NSDictionary *info = @{
            @"topic": baseTopic,
            @"lat":   lat,
            @"lon":   lon,
            @"tst":   dict[@"tst"] ?: @(0),
            @"label": label,
        };

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"OTLiveFriendLocation"
                              object:nil
                            userInfo:info];
        });

        DDLogInfo(@"[TVAppDelegate] location %@ lat=%.5f lon=%.5f",
                  baseTopic, lat.doubleValue, lon.doubleValue);

    } else if ([type isEqualToString:@"card"]) {
        NSString *cardName = dict[@"name"];
        DDLogInfo(@"[TVAppDelegate] card received topic=%@ baseTopic=%@ name=%@",
                  topic, baseTopic, cardName ?: @"(none)");

        NSString *face    = dict[@"face"];
        NSData   *imgData = nil;
        if (face.length) {
            imgData = [[NSData alloc] initWithBase64EncodedString:face options:0];
            if (imgData) {
                self.cardImages[baseTopic] = imgData;
                DDLogInfo(@"[TVAppDelegate] card %@ decoded imageBytes=%lu",
                          baseTopic, (unsigned long)imgData.length);
            } else {
                DDLogInfo(@"[TVAppDelegate] card %@ face base64 decode failed", baseTopic);
            }
        }

        if (cardName.length || imgData) {
            NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithObject:baseTopic forKey:@"topic"];
            if (imgData) {
                payload[@"imageData"] = imgData;
            }
            if (cardName.length) {
                payload[@"name"] = cardName;
            }
            DDLogInfo(@"[TVAppDelegate] posting OTFriendCard for %@ name=%@ hasImage=%@",
                      baseTopic, cardName ?: @"-", imgData ? @"YES" : @"NO");
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:@"OTFriendCard"
                                  object:nil
                                userInfo:[payload copy]];
            });
        }
    } else {
        DDLogInfo(@"[TVAppDelegate] ignoring _type=%@ on %@", type ?: @"(null)", topic);
    }

    return YES;
}

- (void)applicationWillTerminate:(UIApplication *)application {
    self.intentionalDisconnect = YES;
    [self.mqttSession closeWithReturnCode:MQTTSuccess
                    sessionExpiryInterval:nil
                             reasonString:nil
                           userProperties:nil
                        disconnectHandler:nil];
}

@end