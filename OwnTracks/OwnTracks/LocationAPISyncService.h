//
//  LocationAPISyncService.h
//  OwnTracks
//
//  Fetches GET {origin}/api/location with Web App OAuth and applies positions via OwnTracking (API-authoritative).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LocationAPISyncService : NSObject

+ (instancetype)sharedInstance;

/// Registers for foreground/background notifications. Safe to call once from application:didFinishLaunchingWithOptions:.
- (void)start;

/// Triggers GET /api/location when not already in flight and the last successful fetch is older than a short debounce (e.g. Friends tab pull-to-refresh on appear).
- (void)requestLocationRefreshIfAppropriate;

/// Makes an authenticated GET to `url`, obtaining and refreshing the OAuth token as needed.
/// Completion is called on an arbitrary background thread with the raw response data or an error.
- (void)performAuthenticatedGET:(NSURL *)url
                     completion:(void (^)(NSData * _Nullable data, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
