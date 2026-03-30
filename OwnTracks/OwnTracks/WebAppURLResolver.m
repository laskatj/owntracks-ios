//
//  WebAppURLResolver.m
//  OwnTracks
//

#import "WebAppURLResolver.h"
#import "Settings.h"

@implementation WebAppURLResolver

+ (nullable NSURL *)webAppUserURLFromPreferenceInMOC:(NSManagedObjectContext *)moc {
    NSString *urlString = [Settings stringForKey:@"webappurl_preference" inMOC:moc];
    if (urlString.length == 0) {
        return nil;
    }
    return [NSURL URLWithString:urlString];
}

+ (nullable NSURL *)webAppOriginURLFromPreferenceInMOC:(NSManagedObjectContext *)moc {
    NSURL *url = [self webAppUserURLFromPreferenceInMOC:moc];
    if (!url) {
        return nil;
    }
    NSURLComponents *c = [NSURLComponents new];
    c.scheme = url.scheme;
    c.host = url.host;
    c.port = url.port;
    return c.URL;
}

+ (nullable NSURL *)webAppKeychainURLFromPreferenceInMOC:(NSManagedObjectContext *)moc {
    NSURL *url = [self webAppUserURLFromPreferenceInMOC:moc];
    if (!url) {
        return nil;
    }
    NSURLComponents *base = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    base.query = nil;
    base.fragment = nil;
    NSString *path = (base.path.length > 0 && ![base.path isEqualToString:@"/"]) ? base.path : @"";
    if (path.length > 0 && [path hasSuffix:@"/"]) {
        path = [path substringToIndex:path.length - 1];
    }
    base.path = path.length > 0 ? path : @"/";
    return base.URL ?: [self webAppOriginURLFromPreferenceInMOC:moc];
}

+ (NSArray<NSURL *> *)webAppKeychainURLCandidatesFromPreferenceInMOC:(NSManagedObjectContext *)moc {
    NSMutableOrderedSet<NSString *> *seen = [NSMutableOrderedSet orderedSet];
    NSMutableArray<NSURL *> *out = [NSMutableArray array];
    void (^add)(NSURL *) = ^(NSURL *u) {
        if (!u) {
            return;
        }
        NSString *s = u.absoluteString;
        if ([seen containsObject:s]) {
            return;
        }
        [seen addObject:s];
        [out addObject:u];
    };

    add([self webAppKeychainURLFromPreferenceInMOC:moc]);

    NSURL *origin = [self webAppOriginURLFromPreferenceInMOC:moc];
    if (!origin) {
        return out;
    }

    NSURLComponents *map = [NSURLComponents new];
    map.scheme = origin.scheme;
    map.host = origin.host;
    map.port = origin.port;
    map.path = @"/map";
    add(map.URL);

    NSURLComponents *root = [NSURLComponents new];
    root.scheme = origin.scheme;
    root.host = origin.host;
    root.port = origin.port;
    root.path = @"/";
    add(root.URL);

    return out;
}

+ (nullable NSURL *)locationAPIRequestURLFromPreferenceInMOC:(NSManagedObjectContext *)moc {
    NSURL *origin = [self webAppOriginURLFromPreferenceInMOC:moc];
    if (!origin) {
        return nil;
    }
    NSURLComponents *c = [NSURLComponents componentsWithURL:origin resolvingAgainstBaseURL:NO];
    c.path = @"/api/location";
    c.queryItems = @[ [NSURLQueryItem queryItemWithName:@"showTeslaBeacons" value:@"false"] ];
    return c.URL;
}

@end
