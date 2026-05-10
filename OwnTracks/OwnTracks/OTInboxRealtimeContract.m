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

/// Must match `app.MapHub<LocationHub>("/locationHub")` on the API host (not `/hubs/...`).
NSString * const OTInboxRealtimeHubPathComponent = @"/locationHub";
/// LocationHub generic server push; see API `SendAsync("Notification", ...)`.
NSString * const OTRealtimeInboxSignalREventName = @"Notification";
/// Admin-facing notifications on the same hub (optional second subscription).
NSString * const OTRealtimeLocationHubAdminNotificationEventName = @"AdminNotification";
NSString * const OTRealtimeSignalRAccessTokenQueryName = @"access_token";

NSString * const OTInboxAPNsRegisterAPIPath = @"/api/push/devices/apns";
NSString * const OTInboxPushEnvelopeTypeKey = @"otinbox";
NSString * const OTInboxPushEnvelopeTypeValue = @"delta";
