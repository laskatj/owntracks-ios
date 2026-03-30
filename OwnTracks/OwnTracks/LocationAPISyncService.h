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

@end

NS_ASSUME_NONNULL_END
