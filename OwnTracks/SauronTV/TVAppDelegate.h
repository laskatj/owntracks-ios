//
//  TVAppDelegate.h
//  SauronTV
//
//  tvOS app delegate. Subscribe-only MQTT client.
//  Parses incoming location messages and posts OTLiveFriendLocation notifications.
//

#import <UIKit/UIKit.h>
#import <mqttc/MQTTSession.h>

@interface TVAppDelegate : UIResponder <UIApplicationDelegate, MQTTSessionDelegate>

@property (strong, nonatomic) UIWindow *window;

@end
