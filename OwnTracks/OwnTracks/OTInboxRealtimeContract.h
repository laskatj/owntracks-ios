//
//  OTInboxRealtimeContract.h
//  OwnTracks
//
//  Client–server contract for real-time inbox (SignalR + APNs). The admin API repo
//  should implement matching endpoints and hub behaviour (ApnsSubscription model,
//  POST registration, ApnsNotificationSubscriber, LocationHub emitting InboxUpdated).
//

#import <Foundation/Foundation.h>

@class NSManagedObjectContext;

/// Convenience C-callable shim for Swift interop (`WebAppURLResolver` Objective-C selectors).
FOUNDATION_EXTERN NSURL * _Nullable OTInboxRealtimeSignalRHubURL(NSManagedObjectContext *moc, NSString *accessToken);

#pragma mark Notifications

/// Posted when the inbox list should reload from REST (debounced after SignalR or coalesced with push handling).
FOUNDATION_EXPORT NSNotificationName const OTInboxShouldRefreshNotification;

FOUNDATION_EXTERN NSString * const OTInboxShouldRefreshReasonKey;
FOUNDATION_EXTERN NSString * const OTInboxShouldRefreshReasonSignalR;
FOUNDATION_EXTERN NSString * const OTInboxShouldRefreshReasonAPNs;

#pragma mark SignalR hub (must match ASP.NET Core MapHub route)

FOUNDATION_EXTERN NSString * const OTInboxRealtimeHubPathComponent;

/// Server invokes `Clients.User(...).SendAsync(OTRealtimeInboxSignalREventName, ...)` — client listens for no-arg payloads.
FOUNDATION_EXTERN NSString * const OTRealtimeInboxSignalREventName;

/// JWT query-string parameter consumed by JwtBearer MessageReceived (ASP.NET SignalR websocket).
FOUNDATION_EXTERN NSString * const OTRealtimeSignalRAccessTokenQueryName;

#pragma mark REST — APNs device registration

/// POST JSON body `{ "deviceToken":"<hex>","sandbox":true|false }`; Bearer OAuth same as /api/notifications.
FOUNDATION_EXTERN NSString * const OTInboxAPNsRegisterAPIPath;

/// Optional: present in silent push payloads from your server to trigger inbox refresh paths.
FOUNDATION_EXTERN NSString * const OTInboxPushEnvelopeTypeKey;

/// Value for OTInboxPushEnvelopeTypeKey that indicates an inbox-change notification (client refetches unread + list refresh).
FOUNDATION_EXTERN NSString * const OTInboxPushEnvelopeTypeValue;
