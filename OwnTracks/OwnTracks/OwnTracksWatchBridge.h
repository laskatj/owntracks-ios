//
//  OwnTracksWatchBridge.h
//  OwnTracks
//
//  Pushes HTTP ingest settings to the watch via WatchConnectivity.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OwnTracksWatchBridge : NSObject

+ (instancetype)shared;

/// Call once at launch (activates WCSession).
- (void)activate;

/// Push current Core Data settings to the watch (HTTP URL, auth, headers).
- (void)pushConfigToWatchIfNeeded;

@end

NS_ASSUME_NONNULL_END
