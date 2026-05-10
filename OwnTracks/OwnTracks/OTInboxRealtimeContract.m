//
//  OTInboxRealtimeContract.m
//  OwnTracks
//

#import "OTInboxRealtimeContract.h"
#import "WebAppURLResolver.h"
#import <CoreData/CoreData.h>

NSURL *OTInboxRealtimeSignalRHubURL(NSManagedObjectContext *moc, NSString *accessToken) {
    return [WebAppURLResolver signalRHubURLFromPreferenceInMOC:moc accessToken:accessToken];
}

NSNotificationName const OTInboxShouldRefreshNotification = @"OTInboxShouldRefresh";
NSString * const OTInboxShouldRefreshReasonKey = @"reason";
NSString * const OTInboxShouldRefreshReasonSignalR = @"signalr";
NSString * const OTInboxShouldRefreshReasonAPNs = @"apns";

NSString * const OTInboxRealtimeHubPathComponent = @"/hubs/location";
NSString * const OTRealtimeInboxSignalREventName = @"InboxUpdated";
NSString * const OTRealtimeSignalRAccessTokenQueryName = @"access_token";

NSString * const OTInboxAPNsRegisterAPIPath = @"/api/push/devices/apns";
NSString * const OTInboxPushEnvelopeTypeKey = @"otinbox";
NSString * const OTInboxPushEnvelopeTypeValue = @"delta";
