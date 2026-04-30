//
//  WebAppURLResolver.h
//  OwnTracks
//
//  Resolves web app origin, Keychain base URL, and location API URL from webappurl_preference.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

NS_ASSUME_NONNULL_BEGIN

@interface WebAppURLResolver : NSObject

/// Raw user-configured URL (e.g. https://host/map), or nil if unset/invalid.
+ (nullable NSURL *)webAppUserURLFromPreferenceInMOC:(NSManagedObjectContext *)moc;

/// Scheme + host + port (no path). Used as API origin for /api/location.
+ (nullable NSURL *)webAppOriginURLFromPreferenceInMOC:(NSManagedObjectContext *)moc;

/// Normalized base URL with path; must match WebAppViewController / WebAppAuthHelper Keychain lookup.
+ (nullable NSURL *)webAppKeychainURLFromPreferenceInMOC:(NSManagedObjectContext *)moc;

/// All plausible Keychain base URLs to try (preference path, `/map`, and `/`). Tokens may be stored under any of these depending on Web App URL settings and login flow.
+ (NSArray<NSURL *> *)webAppKeychainURLCandidatesFromPreferenceInMOC:(NSManagedObjectContext *)moc;

/// Same candidate list as `webAppKeychainURLCandidatesFromPreferenceInMOC:` but derived from an explicit configured URL (e.g. captured before a settings reset).
+ (NSArray<NSURL *> *)webAppKeychainURLCandidatesForUserConfiguredURL:(NSURL *)userURL;

/// GET {origin}/api/location?showTeslaBeacons=false
+ (nullable NSURL *)locationAPIRequestURLFromPreferenceInMOC:(NSManagedObjectContext *)moc;

/// POST {origin}/api/config/provision (same origin as location API).
+ (nullable NSURL *)configProvisionAPIRequestURLFromPreferenceInMOC:(NSManagedObjectContext *)moc;

@end

NS_ASSUME_NONNULL_END
