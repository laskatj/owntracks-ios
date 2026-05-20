//
//  ViewController.m
//  OwnTracks
//
//  Created by Christoph Krey on 17.08.13.
//  Copyright © 2013-2025  Christoph Krey. All rights reserved.
//

#import "ViewController.h"
#import "FriendMarkerAnimator.h"
#import "StatusTVC.h"
#import "FriendAnnotationV.h"
#import "PhotoAnnotationV.h"
#import "FriendsTVC.h"
#import "RegionsTVC.h"
#import "WaypointTVC.h"
#import <Sauron-Swift.h>
#import "CoreData.h"
#import "Friend+CoreDataClass.h"
#import "Region+CoreDataClass.h"
#import "Waypoint+CoreDataClass.h"
#import "LocationManager.h"
#import "OwnTracking.h"
#import "LocationAPISyncService.h"
#import "WebAppURLResolver.h"
#import "WebAppViewController.h"
#import "SettingsTVC.h"
#import "Settings.h"
#import "OTMapFollowHeading.h"
#import "OTSpeedometerView.h"
#import "OTAltimeterView.h"
#import <math.h>
#import "OTHeartRateMonitoring.h"
#import "BluetoothHeartRateManager.h"
#import "HealthKitHeartRateManager.h"

#import "OwnTracksChangeMonitoringIntent.h"

static NSString * const kMapRouteHistoryHoursKey = @"mapRouteHistoryHours";
static NSString * const kOTFriendPinTapGRName = @"org.owntracks.OTFriendPinTap";

static NSString * const kOTFollowUserPitchKey = @"OTFollowUserPitch";
static const NSUInteger kOTFollowInstrumentHistoryMax = 40;
static NSString * const kOTFollowUserDistanceKey = @"OTFollowUserDistance";
/// Default camera altitude (m) when starting follow — street-level; user can pinch after.
static const CLLocationDistance kFollowDefaultCameraDistanceM = 900.0;

static CGFloat OTClampedFollowUserPitch(double pitch) {
    if (!isfinite(pitch)) {
        return OTMaxFollowMapCameraPitch();
    }
    return (CGFloat)MIN(80.0, MAX(0.0, pitch));
}

static CLLocationDistance OTClampedFollowUserDistance(CLLocationDistance d) {
    if (!isfinite(d) || d <= 0.0) {
        return kFollowDefaultCameraDistanceM;
    }
    return MIN(1.5e6, MAX(80.0, d));
}

static CGFloat OTFollowUserPitch(void) {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    if ([defs objectForKey:kOTFollowUserPitchKey] == nil) {
        return OTMaxFollowMapCameraPitch();
    }
    return OTClampedFollowUserPitch([defs doubleForKey:kOTFollowUserPitchKey]);
}

static CLLocationDistance OTFollowUserDistance(void) {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    if ([defs objectForKey:kOTFollowUserDistanceKey] == nil) {
        return kFollowDefaultCameraDistanceM;
    }
    return OTClampedFollowUserDistance([defs doubleForKey:kOTFollowUserDistanceKey]);
}

static void OTPersistFollowUserCameraPitchAndDistance(double pitch, CLLocationDistance distance) {
    CGFloat p = OTClampedFollowUserPitch(pitch);
    CLLocationDistance d = OTClampedFollowUserDistance(distance);
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    [defs setDouble:p forKey:kOTFollowUserPitchKey];
    [defs setDouble:d forKey:kOTFollowUserDistanceKey];
}

/// US Pacific for route debug (`America/Los_Angeles` — PST or PDT by calendar).
static NSString *RouteDebugTimeStringPST(NSTimeInterval unix) {
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:unix];
    static NSDateFormatter *fmt;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.timeZone = [NSTimeZone timeZoneWithName:@"America/Los_Angeles"];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss zzz";
    });
    return [fmt stringFromDate:d];
}

static NSString *RouteDebugPSTOrUnknown(id unixObj) {
    if (!unixObj || unixObj == [NSNull null]) {
        return @"(time unknown)";
    }
    if ([unixObj isKindOfClass:[NSNumber class]]) {
        return RouteDebugTimeStringPST([(NSNumber *)unixObj doubleValue]);
    }
    return @"(time unknown)";
}

#import <CocoaLumberjack/CocoaLumberjack.h>

#define OSM TRUE

/// Shared active-state check for MapKit gesture recognizers we inspect below.
static BOOL OTGestureIsActive(UIGestureRecognizer *gr) {
    return gr.state == UIGestureRecognizerStateBegan ||
           gr.state == UIGestureRecognizerStateChanged;
}

/// Template clock: minute hand at 12; hour at 12 when `hours == 12`, at 6 when `hours == 6`.
static UIImage *OTRouteHistoryWindowClockImage(CGFloat side, NSInteger hours) {
    CGSize sz = CGSizeMake(side, side);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = [UIScreen mainScreen].scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt];
    UIImage *raw = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGPoint ctr = CGPointMake(side * 0.5, side * 0.5);
        CGFloat faceR = side * 0.42;
        [[UIColor blackColor] setStroke];
        UIBezierPath *circle = [UIBezierPath bezierPathWithArcCenter:ctr
                                                                radius:faceR
                                                            startAngle:0
                                                              endAngle:(CGFloat)(M_PI * 2.0)
                                                             clockwise:YES];
        circle.lineWidth = MAX(1.5, side * 0.08);
        [circle stroke];

        double minuteAngle = -M_PI_2;
        double hourAngle = (hours == 6) ? M_PI_2 : -M_PI_2;
        CGFloat minLen = faceR * 0.36;
        CGFloat hourLen = faceR * 0.52;

        CGContextRef c = ctx.CGContext;
        CGContextSetStrokeColorWithColor(c, [UIColor blackColor].CGColor);
        CGContextSetLineCap(c, kCGLineCapRound);

        CGContextSetLineWidth(c, MAX(1.0, side * 0.055));
        CGContextMoveToPoint(c, ctr.x, ctr.y);
        CGContextAddLineToPoint(c, ctr.x + cos(minuteAngle) * minLen, ctr.y + sin(minuteAngle) * minLen);
        CGContextStrokePath(c);

        CGContextSetLineWidth(c, MAX(1.5, side * 0.075));
        CGContextMoveToPoint(c, ctr.x, ctr.y);
        CGContextAddLineToPoint(c, ctr.x + cos(hourAngle) * hourLen, ctr.y + sin(hourAngle) * hourLen);
        CGContextStrokePath(c);
    }];
    return [raw imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

@interface ViewController ()
@property (weak, nonatomic) IBOutlet MKMapView *mapView;
@property (weak, nonatomic) IBOutlet UIBarButtonItem *accuracyButton;
@property (weak, nonatomic) IBOutlet UIBarButtonItem *actionButton;

@property (strong, nonatomic) NSFetchedResultsController *frcFriends;
@property (strong, nonatomic) NSFetchedResultsController *frcRegions;
@property (strong, nonatomic) NSFetchedResultsController *frcWaypoints;
@property (nonatomic) BOOL suspendAutomaticTrackingOfChangesInManagedObjectContext;
@property (strong, nonatomic) MKUserTrackingBarButtonItem *userTracker;

@property (nonatomic) BOOL initialCenter;
@property (strong, nonatomic) UISegmentedControl *modes;
@property (strong, nonatomic) UISegmentedControl *mapMode;
@property (strong, nonatomic) MKUserTrackingButton *trackingButton;
@property (strong, nonatomic) MKScaleView *scaleView;
@property (strong, nonatomic) MKCompassButton *compassButton;
@property (strong, nonatomic, nullable) NSLayoutConstraint *compassTopConstraint;
@property (strong, nonatomic, nullable) NSLayoutConstraint *compassBelowInstrumentationConstraint;
/// Speed + altitude HUD while following a device (altimeter left, speedometer right).
@property (strong, nonatomic) UIStackView *instrumentationStack;
@property (strong, nonatomic) OTSpeedometerView *speedometerView;
@property (strong, nonatomic) OTAltimeterView *altimeterView;
@property (strong, nonatomic) NSLayoutConstraint *altimeterWidthConstraint;
@property (strong, nonatomic) NSLayoutConstraint *altimeterHeightConstraint;
@property (strong, nonatomic) NSLayoutConstraint *speedometerWidthConstraint;
@property (strong, nonatomic) NSLayoutConstraint *speedometerHeightConstraint;
@property (strong, nonatomic, nullable) NSLayoutConstraint *instrumentationTopConstraint;
@property (strong, nonatomic) NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *followVelocityHistoryKmhByTopic;
@property (strong, nonatomic) NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *followAltitudeMetersByTopic;
@property (strong, nonatomic) UIControl *heartRateMapChip;
@property (strong, nonatomic) UIImageView *heartRateMapHeartImageView;
@property (strong, nonatomic) UILabel *heartRateMapBPMLabel;
@property (strong, nonatomic) UIImageView *heartRateMapSourceBadgeView;
/// Opaque tokens from `addObserverForName:object:queue:usingBlock:` — must be `strong`, not `copy` (tokens are not copyable).
@property (nonatomic, strong) id heartRateMapNotificationTokenHK;
@property (nonatomic, strong) id heartRateMapNotificationTokenBLE;
@property (nonatomic, strong) id heartRateMapNotificationTokenPref;
@property (weak, nonatomic) IBOutlet UIBarButtonItem *askForMapButton;
@property (strong, nonatomic) UIBarButtonItem *bellBarButton;
@property (strong, nonatomic) UIBarButtonItem *avatarBarButton;
@property (strong, nonatomic) UIBarButtonItem *rightControlsBarButton;
@property (strong, nonatomic) UIButton *bellButton;
@property (strong, nonatomic) UILabel *bellBadgeLabel;
@property (strong, nonatomic) UIButton *avatarButton;
@property (strong, nonatomic) NSArray<UIBarButtonItem *> *baseLeftBarItems;
@property (nonatomic) BOOL profileAvatarFetchInFlight;
@property (nonatomic) BOOL warning;
#if OSM
@property (strong, nonatomic) MKTileOverlayRenderer *osmRenderer;
@property (strong, nonatomic) UITextField *osmCopyright;
@property (strong, nonatomic) MKTileOverlay *osmOverlay;
#endif
/// Topics for which the historical route has been fetched and merged into liveTrackPoints this session.
@property (nonatomic, strong) NSMutableSet<NSString *> *routeFetchedTopics;
/// Topics with an in-flight route fetch; used to cancel/ignore stale responses on deselect.
@property (nonatomic, strong) NSMutableSet<NSString *> *pendingRouteTopics;
/// Per-topic `liveTrackPoints` count when a route GET was issued — only MQTT points appended after this are merged with the API response (avoids dragging old session points outside the requested window).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *routeFetchMQTTBaselineByTopic;
/// Live MQTT track points (session-only), keyed by friend.topic.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSValue *> *> *liveTrackPoints;
/// Parallel to `liveTrackPoints[topic]`: `NSNumber` unix seconds, or `NSNull` when unknown (for debug / PST labels).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *liveTrackPointUnixByTopic;
/// Live MQTT track polyline overlays currently on the map, keyed by friend.topic.
@property (nonatomic, strong) NSMutableDictionary<NSString *, MKPolyline *> *liveTrackPolylines;
/// Per-friend smooth marker animators, keyed by friend.topic.
@property (nonatomic, strong) NSMutableDictionary<NSString *, FriendMarkerAnimator *> *friendAnimators;
/// CADisplayLink: smooth camera center/heading toward the followed friend (`TVMapViewController` pattern).
@property (nonatomic, strong, nullable) CADisplayLink *followLink;
/// Latest finite course-up heading from `OTLiveFriendLocation` (nil = keep smoothing toward current render heading).
@property (strong, nonatomic, nullable) NSNumber *followHeadingTargetNumber;
/// Throttled / smoothed follow camera state (mirrors `TVMapViewController` follow tick).
@property (assign, nonatomic) CFAbsoluteTime followCameraLastTickTime;
@property (assign, nonatomic) CFAbsoluteTime followCameraLastApplyTime;
@property (assign, nonatomic) CLLocationCoordinate2D followCameraTargetCenterCoord;
@property (assign, nonatomic) CLLocationCoordinate2D followCameraRenderCenterCoord;
@property (assign, nonatomic) double followCameraRenderHeadingDeg;
@property (assign, nonatomic) BOOL followCameraHasSmootherState;
/// Direct reference to the friend currently selected on the map/list.
@property (nonatomic, weak, nullable) Friend *selectedFriend;
/// Direct reference to the friend currently being followed (weak — Friend is owned by Core Data).
@property (nonatomic, weak, nullable) Friend *followFriend;
/// Camera follow mode for selected friend.
@property (nonatomic, assign) BOOL followEnabled;
/// Toggles Recorder route history window between 6h and 12h (icon row beside user tracking).
@property (nonatomic, strong) UIButton *routeHistoryToggleButton;
/// Toggle for follow mode (bullseye icon beside route window control).
@property (nonatomic, strong) UIButton *followToggleButton;
/// Horizontal stack: route window clock, follow bullseye (to the right of `MKUserTrackingButton` when present).
@property (nonatomic, strong) UIStackView *mapRouteFollowStack;
/// Transient overlay/annotation for Locations tab selection.
@property (nonatomic, strong, nullable) MKCircle *selectedLocationZoneOverlay;
@property (nonatomic, strong, nullable) MKPointAnnotation *selectedLocationZoneAnnotation;
/// Active positional constraints for `mapRouteFollowStack` (rebuilt when `trackingButton` appears or is removed).
@property (nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *mapRouteFollowStackLayoutConstraints;
/// One-shot debug payload for the next `rebuildLiveTrackForTopic:` after a route GET merges (REST window vs API tst).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *routeLastFetchDebugByTopic;
/// Previous coordinate per MQTT topic for course-up / bearing fallback (`OTMapFollowHeading`).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *followMapPrevCoordByTopic;
/// User panned/rotated the map; skip heading lock until the next explicit follow selection.
@property (nonatomic, assign) BOOL followHeadingLockPausedByUserGesture;
/// Temporarily pause camera recenter while user pinch-zooms/pitches; resume on gesture end.
@property (nonatomic, assign) BOOL followTemporarilySuspendedByGesture;
/// User panned/zoomed, followed a device, or otherwise took map control before the first-location startup frame — skip auto local viewport.
@property (nonatomic, assign) BOOL skipInitialLocalMapViewport;
/// Suppress treating `regionWillChange` as user gesture while applying the one-shot launch viewport.
@property (nonatomic, assign) BOOL applyingInitialLocalViewport;
@end


@implementation ViewController
static const DDLogLevel ddLogLevel = DDLogLevelInfo;

static NSInteger const kInboxTabTag = 111;

static UIImage *OTImageFromDataURLString(NSString *candidate) {
    if (![candidate isKindOfClass:[NSString class]] || candidate.length == 0) {
        return nil;
    }
    if (![candidate hasPrefix:@"data:image"]) {
        return nil;
    }
    NSRange commaRange = [candidate rangeOfString:@","];
    if (commaRange.location == NSNotFound || commaRange.location + 1 >= candidate.length) {
        return nil;
    }
    NSString *payload = [candidate substringFromIndex:commaRange.location + 1];
    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:payload options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!decoded.length) {
        return nil;
    }
    return [UIImage imageWithData:decoded];
}

/// Local cluster radius for startup map framing (~metro area).
static const CLLocationDistance kOTInitialViewportLocalRadiusM = 80000.0;
static const NSUInteger kOTInitialViewportNearestFriendFallback = 6;
static const CLLocationDistance kOTInitialViewportMinRadiusM = 2000.0;
/// When no friends fall inside the local radius, include up to N nearest if within this cap.
static const CLLocationDistance kOTInitialViewportFallbackRemoteCapM = 400000.0;
/// Grow the tight bbox slightly so edge markers are not flush with the visible rect before padding.
static const double kOTInitialViewportMapRectOutsetFraction = 0.10;

static BOOL OTInitialViewportCoordinateUsable(CLLocationCoordinate2D c) {
    if (!CLLocationCoordinate2DIsValid(c)) {
        return NO;
    }
    if (fabs(c.latitude) < 1e-9 && fabs(c.longitude) < 1e-9) {
        return NO;
    }
    return YES;
}

static MKMapRect OTMapRectUnionCoordinate(MKMapRect rect, CLLocationCoordinate2D c) {
    if (!OTInitialViewportCoordinateUsable(c)) {
        return rect;
    }
    MKMapPoint pt = MKMapPointForCoordinate(c);
    MKMapRect one = MKMapRectMake(pt.x, pt.y, 1.0, 1.0);
    return MKMapRectIsNull(rect) ? one : MKMapRectUnion(rect, one);
}

static MKMapRect OTMapRectExpandedToMinRadiusAroundCenter(MKMapRect rect, CLLocationDistance minRadiusM) {
    if (MKMapRectIsNull(rect) || minRadiusM <= 0.0) {
        return rect;
    }
    MKMapPoint mid = MKMapPointMake(MKMapRectGetMidX(rect), MKMapRectGetMidY(rect));
    CLLocationCoordinate2D center = MKCoordinateForMapPoint(mid);
    double r = minRadiusM * MKMapPointsPerMeterAtLatitude(center.latitude);
    MKMapRect minAround = MKMapRectMake(mid.x - r, mid.y - r, 2.0 * r, 2.0 * r);
    return MKMapRectUnion(rect, minAround);
}

static MKMapRect OTMapRectOutsetFraction(MKMapRect rect, double fraction) {
    if (MKMapRectIsNull(rect) || fraction <= 0.0) {
        return rect;
    }
    double w = rect.size.width * (1.0 + fraction);
    double h = rect.size.height * (1.0 + fraction);
    double dx = (w - rect.size.width) * 0.5;
    double dy = (h - rect.size.height) * 0.5;
    return MKMapRectMake(rect.origin.x - dx, rect.origin.y - dy, w, h);
}

- (void)viewDidLoad {
    [super viewDidLoad];

    {
        NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
        if ([defs integerForKey:@"noMap"] == 0) {
            [defs setInteger:1 forKey:@"noMap"];
        }
        if ([defs integerForKey:@"noRevgeo"] == 0) {
            [defs setInteger:1 forKey:@"noRevgeo"];
        }
    }

    self.warning = FALSE;
    self.routeFetchedTopics = [NSMutableSet set];
    self.pendingRouteTopics = [NSMutableSet set];
    self.routeFetchMQTTBaselineByTopic = [NSMutableDictionary dictionary];
    self.liveTrackPoints = [NSMutableDictionary dictionary];
    self.liveTrackPointUnixByTopic = [NSMutableDictionary dictionary];
    self.liveTrackPolylines = [NSMutableDictionary dictionary];
    self.friendAnimators = [NSMutableDictionary dictionary];
    self.routeLastFetchDebugByTopic = [NSMutableDictionary dictionary];
    self.followMapPrevCoordByTopic = [NSMutableDictionary dictionary];
    self.followVelocityHistoryKmhByTopic = [NSMutableDictionary dictionary];
    self.followAltitudeMetersByTopic = [NSMutableDictionary dictionary];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(liveFriendLocationUpdate:)
                                                 name:@"OTLiveFriendLocation"
                                               object:nil];
    self.mapView.delegate = self;
    self.mapView.mapType = MKMapTypeStandard;
    
    self.mapView.showsScale = FALSE;
        
    DDLogInfo(@"[ViewController] viewDidLoad mapView region %g %g %g %g",
              self.mapView.region.center.latitude,
              self.mapView.region.center.longitude,
              self.mapView.region.span.latitudeDelta,
              self.mapView.region.span.longitudeDelta);
    
    [self setupModes];
    [self updateMoveButton];
    [self setupMapMode];
    [self setupScaleView];
    [self setupMapHeartRateIndicator];
    [self setupCompassButton];
    [self buildInstrumentationHUD];
    
    [[LocationManager sharedInstance] addObserver:self
                                       forKeyPath:@"monitoring"
                                          options:NSKeyValueObservingOptionNew
                                          context:nil];

    [self.mapView addObserver:self
                   forKeyPath:@"userLocation"
                      options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                      context:nil];
    [self.mapView addObserver:self
                   forKeyPath:@"userLocation.location"
                      options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                      context:nil];

    [[NSNotificationCenter defaultCenter]
     addObserverForName:@"reload"
     object:nil
     queue:[NSOperationQueue mainQueue]
     usingBlock:^(NSNotification *note){
         [self performSelectorOnMainThread:@selector(reloaded)
                                withObject:nil
                             waitUntilDone:NO];
     }];
    
    [self noMap];
    [self configureTopNavigationBar];
    [self refreshBellUnreadBadge];
    [self fetchCurrentUserProfileIfSignedIn];
    [self setupMapRouteFollowControlsRow];
    [self updateInstrumentationTopConstraint];
    self.followEnabled = YES;
    [self updateFollowToggleAppearance];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshBellUnreadBadge)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(currentUserProfileDidChangeForRouteHistory:)
                                                 name:OwnTracksCurrentUserProfileDidUpdateNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:OwnTracksCurrentUserProfileDidUpdateNotification object:nil];
    if (self.heartRateMapNotificationTokenHK) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.heartRateMapNotificationTokenHK];
        self.heartRateMapNotificationTokenHK = nil;
    }
    if (self.heartRateMapNotificationTokenBLE) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.heartRateMapNotificationTokenBLE];
        self.heartRateMapNotificationTokenBLE = nil;
    }
    if (self.heartRateMapNotificationTokenPref) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.heartRateMapNotificationTokenPref];
        self.heartRateMapNotificationTokenPref = nil;
    }
}

- (void)currentUserProfileDidChangeForRouteHistory:(NSNotification *)note {
    (void)note;
    [self OT_applyRouteHistoryPermissionIfNeeded];
}

/// When `canViewRouteHistory` becomes false, drop REST route merge state and redraw MQTT-only polylines.
- (void)OT_applyRouteHistoryPermissionIfNeeded {
    if ([[LocationAPISyncService sharedInstance] currentUserMayViewRouteHistory]) {
        [self updateRouteHistoryToggleVisibility];
        return;
    }
    if (![[LocationAPISyncService sharedInstance] hasAuthorizationUserProfilePayload]) {
        [self updateRouteHistoryToggleVisibility];
        return;
    }
    [self.routeFetchedTopics removeAllObjects];
    [self.pendingRouteTopics removeAllObjects];
    [self.routeFetchMQTTBaselineByTopic removeAllObjects];
    NSArray<NSString *> *polyTopics = [self.liveTrackPolylines.allKeys copy];
    for (NSString *topic in polyTopics) {
        MKPolyline *pl = self.liveTrackPolylines[topic];
        if (pl) {
            [self.mapView removeOverlay:pl];
        }
        [self.liveTrackPolylines removeObjectForKey:topic];
    }
    NSArray<NSString *> *pointTopics = [self.liveTrackPoints.allKeys copy];
    for (NSString *topic in pointTopics) {
        [self rebuildLiveTrackForTopic:topic];
    }
    [self updateRouteHistoryToggleVisibility];
}

- (void)configureTopNavigationBar {
    self.navigationItem.title = @"";
    self.navigationItem.titleView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];

    // Keep storyboard-provided Info button (drop the Map picker - settings now ON by default), then append accuracy/share.
    if (!self.baseLeftBarItems.count) {
        NSMutableArray<UIBarButtonItem *> *baseLeft = [NSMutableArray array];
        for (UIBarButtonItem *it in (self.navigationItem.leftBarButtonItems ?: @[])) {
            if (it != self.askForMapButton) {
                [baseLeft addObject:it];
            }
        }
        self.baseLeftBarItems = baseLeft;
    }
    NSMutableArray<UIBarButtonItem *> *leftItems = [NSMutableArray arrayWithArray:self.baseLeftBarItems ?: @[]];
    if (self.accuracyButton) {
        [leftItems addObject:self.accuracyButton];
    }
    if (self.actionButton) {
        [leftItems addObject:self.actionButton];
    }
    self.navigationItem.leftBarButtonItems = leftItems;

    static const CGFloat kBellSize = 24.0;
    static const CGFloat kAvatarSize = 30.0;
    static const CGFloat kBellAvatarSpacing = 14.0;

    UIButton *bell = [UIButton buttonWithType:UIButtonTypeCustom];
    bell.translatesAutoresizingMaskIntoConstraints = NO;
    [bell setImage:[UIImage systemImageNamed:@"bell"] forState:UIControlStateNormal];
    bell.tintColor = [UIColor labelColor];
    bell.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    bell.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    [bell addTarget:self action:@selector(bellTapped:) forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [bell.widthAnchor constraintEqualToConstant:kBellSize],
        [bell.heightAnchor constraintEqualToConstant:kBellSize],
    ]];
    UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(kBellSize - 8, -4, 14, 14)];
    badge.backgroundColor = [UIColor systemRedColor];
    badge.textColor = UIColor.whiteColor;
    badge.textAlignment = NSTextAlignmentCenter;
    badge.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
    badge.layer.cornerRadius = 7;
    badge.clipsToBounds = YES;
    badge.hidden = YES;
    [bell addSubview:badge];
    self.bellButton = bell;
    self.bellBadgeLabel = badge;
    self.bellBarButton = [[UIBarButtonItem alloc] initWithCustomView:bell];

    UIButton *avatar = [UIButton buttonWithType:UIButtonTypeCustom];
    avatar.translatesAutoresizingMaskIntoConstraints = NO;
    avatar.layer.cornerRadius = kAvatarSize / 2.0;
    avatar.clipsToBounds = YES;
    avatar.layer.borderWidth = 2.5;
    UIColor *meColor = [UIColor colorNamed:@"meColor"] ?: [UIColor systemGreenColor];
    avatar.layer.borderColor = meColor.CGColor;
    avatar.backgroundColor = [UIColor clearColor];
    avatar.tintColor = [UIColor labelColor];
    avatar.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
    avatar.contentVerticalAlignment = UIControlContentVerticalAlignmentFill;
    avatar.imageView.contentMode = UIViewContentModeScaleAspectFill;
    avatar.imageView.clipsToBounds = YES;
    avatar.adjustsImageWhenHighlighted = NO;
    [avatar addTarget:self action:@selector(profileTapped:) forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [avatar.widthAnchor constraintEqualToConstant:kAvatarSize],
        [avatar.heightAnchor constraintEqualToConstant:kAvatarSize],
    ]];
    self.avatarButton = avatar;
    [self refreshAvatarButtonImage];
    self.avatarBarButton = [[UIBarButtonItem alloc] initWithCustomView:avatar];

    UIStackView *rightStack = [[UIStackView alloc] initWithArrangedSubviews:@[bell, avatar]];
    rightStack.axis = UILayoutConstraintAxisHorizontal;
    rightStack.alignment = UIStackViewAlignmentCenter;
    rightStack.spacing = kBellAvatarSpacing;
    rightStack.translatesAutoresizingMaskIntoConstraints = NO;

    CGFloat containerWidth = kBellSize + kBellAvatarSpacing + kAvatarSize;
    UIView *rightContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, containerWidth, kAvatarSize)];
    [rightContainer addSubview:rightStack];
    [NSLayoutConstraint activateConstraints:@[
        [rightStack.leadingAnchor constraintEqualToAnchor:rightContainer.leadingAnchor],
        [rightStack.trailingAnchor constraintEqualToAnchor:rightContainer.trailingAnchor],
        [rightStack.centerYAnchor constraintEqualToAnchor:rightContainer.centerYAnchor],
    ]];

    self.rightControlsBarButton = [[UIBarButtonItem alloc] initWithCustomView:rightContainer];
    self.navigationItem.rightBarButtonItems = nil;
    self.navigationItem.rightBarButtonItem = self.rightControlsBarButton;
}

- (void)refreshAvatarButtonImage {
    NSManagedObjectContext *moc = CoreData.sharedInstance.mainMOC;
    NSString *topic = [Settings theGeneralTopicInMOC:moc];
    Friend *me = [Friend existsFriendWithTopic:topic inManagedObjectContext:moc];
    NSData *imageData = me.image ?: me.cardImage;
    UIImage *avatarImage = imageData.length > 0 ? [UIImage imageWithData:imageData] : nil;
    if (avatarImage) {
        [self.avatarButton setBackgroundImage:avatarImage forState:UIControlStateNormal];
        [self.avatarButton setImage:nil forState:UIControlStateNormal];
        self.avatarButton.imageView.contentMode = UIViewContentModeScaleAspectFill;
        self.avatarButton.backgroundColor = [UIColor clearColor];
    } else {
        [self.avatarButton setBackgroundImage:nil forState:UIControlStateNormal];
        [self.avatarButton setImage:[UIImage systemImageNamed:@"person.circle.fill"] forState:UIControlStateNormal];
        self.avatarButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
        self.avatarButton.backgroundColor = [UIColor clearColor];
    }
}

- (void)fetchCurrentUserProfileIfSignedIn {
    if (self.profileAvatarFetchInFlight) {
        return;
    }
    NSURL *origin = [WebAppURLResolver webAppOriginURLFromPreferenceInMOC:CoreData.sharedInstance.mainMOC];
    if (!origin) {
        return;
    }
    NSURLComponents *components = [NSURLComponents componentsWithURL:origin resolvingAgainstBaseURL:NO];
    components.path = @"/api/authorization/user";
    components.query = nil;
    components.fragment = nil;
    NSURL *userURL = components.URL;
    if (!userURL) {
        return;
    }
    self.profileAvatarFetchInFlight = YES;
    __weak typeof(self) weakSelf = self;
    [[LocationAPISyncService sharedInstance] performAuthenticatedGET:userURL completion:^(NSData * _Nullable data, NSError * _Nullable error) {
        __strong typeof(weakSelf) sself = weakSelf;
        if (!sself) {
            return;
        }
        if (error || data.length == 0) {
            sself.profileAvatarFetchInFlight = NO;
            return;
        }
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![obj isKindOfClass:[NSDictionary class]]) {
            sself.profileAvatarFetchInFlight = NO;
            return;
        }
        NSDictionary *user = (NSDictionary *)obj;
        [[LocationAPISyncService sharedInstance] updateFromAuthorizationUserAPIPayload:user];
        NSString *picture = [user[@"picture"] isKindOfClass:[NSString class]] ? user[@"picture"] : nil;
        UIImage *inlinePicture = OTImageFromDataURLString(picture);
        if (inlinePicture) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [sself.avatarButton setBackgroundImage:inlinePicture forState:UIControlStateNormal];
                [sself.avatarButton setImage:nil forState:UIControlStateNormal];
                sself.avatarButton.imageView.contentMode = UIViewContentModeScaleAspectFill;
                sself.profileAvatarFetchInFlight = NO;
            });
            return;
        }
        NSString *userImagePath = nil;
        NSArray<NSString *> *keys = @[ @"userImage", @"UserImage", @"profileImage", @"avatarUrl" ];
        for (NSString *key in keys) {
            id value = user[key];
            if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                userImagePath = (NSString *)value;
                break;
            }
        }
        if (userImagePath.length == 0) {
            sself.profileAvatarFetchInFlight = NO;
            return;
        }
        NSURL *imageURL = nil;
        if ([userImagePath hasPrefix:@"http://"] || [userImagePath hasPrefix:@"https://"]) {
            imageURL = [NSURL URLWithString:userImagePath];
        } else {
            NSURLComponents *imageComponents = [NSURLComponents componentsWithURL:origin resolvingAgainstBaseURL:NO];
            imageComponents.path = [userImagePath hasPrefix:@"/"] ? userImagePath : [@"/" stringByAppendingString:userImagePath];
            imageComponents.query = nil;
            imageComponents.fragment = nil;
            imageURL = imageComponents.URL;
        }
        if (!imageURL) {
            sself.profileAvatarFetchInFlight = NO;
            return;
        }
        [[LocationAPISyncService sharedInstance] performAuthenticatedGET:imageURL completion:^(NSData * _Nullable imageData, NSError * _Nullable imageError) {
            UIImage *image = (imageData.length > 0 && !imageError) ? [UIImage imageWithData:imageData] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (image) {
                    [sself.avatarButton setBackgroundImage:image forState:UIControlStateNormal];
                    [sself.avatarButton setImage:nil forState:UIControlStateNormal];
                    sself.avatarButton.imageView.contentMode = UIViewContentModeScaleAspectFill;
                }
                sself.profileAvatarFetchInFlight = NO;
            });
        }];
    }];
}

- (void)refreshBellUnreadBadge {
    [[LocationAPISyncService sharedInstance] fetchUnreadNotificationCountWithCompletion:^(NSInteger count, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                return;
            }
            if (count > 0) {
                self.bellBadgeLabel.hidden = NO;
                self.bellBadgeLabel.text = count > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)count];
            } else {
                self.bellBadgeLabel.hidden = YES;
                self.bellBadgeLabel.text = @"";
            }
        });
    }];
}

- (void)bellTapped:(id)sender {
    UITabBarController *tabs = self.tabBarController;
    for (NSUInteger i = 0; i < tabs.viewControllers.count; i++) {
        UIViewController *vc = tabs.viewControllers[i];
        if (vc.tabBarItem.tag == kInboxTabTag) {
            tabs.selectedIndex = i;
            return;
        }
    }
}

- (void)profileTapped:(id)sender {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Sign Out"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction * _Nonnull action) {
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Sign Out"
                                                                         message:@"This will run the full reset flow and clear settings to defaults."
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Sign Out"
                                                    style:UIAlertActionStyleDestructive
                                                  handler:^(UIAlertAction * _Nonnull action) {
            [SettingsTVC performFullResetToBundledDefaultsFromPresenter:self
                                                               animated:YES
                                                             completion:^{
                [self refreshBellUnreadBadge];
                [self refreshAvatarButtonImage];
            }];
        }]];
        [self presentViewController:confirm animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)setupModes {
    self.modes = [[UISegmentedControl alloc]
                  initWithItems:@[NSLocalizedString(@"Quiet", @"Quiet"),
                                  NSLocalizedString(@"Manual", @"Manual"),
                                  NSLocalizedString(@"Significant", @"Significant"),
                                  NSLocalizedString(@"Move", @"Move")
                                  ]];
    self.modes.apportionsSegmentWidthsByContent = YES;
    self.modes.translatesAutoresizingMaskIntoConstraints = false;
    self.modes.backgroundColor = [UIColor colorNamed:@"modesColor"];
    [self.modes addTarget:self
                   action:@selector(modesChanged:)
         forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.modes];

    NSLayoutConstraint *topModes = [NSLayoutConstraint
                               constraintWithItem:self.modes
                               attribute:NSLayoutAttributeTop
                               relatedBy:NSLayoutRelationEqual
                               toItem:self.mapView
                               attribute:NSLayoutAttributeTop
                               multiplier:1
                               constant:10];
    NSLayoutConstraint *leadingModes = [NSLayoutConstraint
                                   constraintWithItem:self.modes
                                   attribute:NSLayoutAttributeLeading
                                   relatedBy:NSLayoutRelationEqual
                                   toItem:self.mapView
                                   attribute:NSLayoutAttributeLeading
                                   multiplier:1
                                   constant:10];
    
    [NSLayoutConstraint activateConstraints:@[topModes, leadingModes]];
}

- (void)setupMapMode {
    self.mapMode = [[UISegmentedControl alloc]
                  initWithItems:@[NSLocalizedString(@"Std", @"Std"),
                                  NSLocalizedString(@"Sat", @"Sat"),
                                  NSLocalizedString(@"Hyb", @"Hyb"),
                                  NSLocalizedString(@"Fly", @"Fly"),
                                  NSLocalizedString(@"HybFly", @"HybFly"),
                                  NSLocalizedString(@"Mute", @"Mute")
#if OSM
                                  , NSLocalizedString(@"OSM", @"OSM")
#endif
                                  ]];
    self.mapMode.apportionsSegmentWidthsByContent = YES;
    self.mapMode.translatesAutoresizingMaskIntoConstraints = false;
    self.mapMode.backgroundColor = [UIColor colorNamed:@"modesColor"];
    [self.mapMode addTarget:self
                   action:@selector(mapModeChanged:)
         forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.mapMode];
    NSInteger selected = [[NSUserDefaults standardUserDefaults] integerForKey:@"mapMode"];
    self.mapMode.selectedSegmentIndex = (selected < self.mapMode.numberOfSegments) ? selected : 0;
    //[self mapModeChanged:self.mapMode];

    NSLayoutConstraint *bottomMapMode = [NSLayoutConstraint
                               constraintWithItem:self.mapMode
                               attribute:NSLayoutAttributeBottom
                               relatedBy:NSLayoutRelationEqual
                               toItem:self.mapView
                               attribute:NSLayoutAttributeBottomMargin
                               multiplier:1
                               constant:-10];
    NSLayoutConstraint *leadingMapMode = [NSLayoutConstraint
                                   constraintWithItem:self.mapMode
                                   attribute:NSLayoutAttributeLeading
                                   relatedBy:NSLayoutRelationEqual
                                   toItem:self.mapView
                                   attribute:NSLayoutAttributeLeading
                                   multiplier:1
                                   constant:10];

    [NSLayoutConstraint activateConstraints:@[bottomMapMode, leadingMapMode]];
}

- (void)setupScaleView {
    self.scaleView = [MKScaleView scaleViewWithMapView:self.mapView];
    self.scaleView.translatesAutoresizingMaskIntoConstraints = false;
    [self.view addSubview:self.scaleView];
    
    NSLayoutConstraint *bottomScale = [NSLayoutConstraint constraintWithItem:self.scaleView
                                                                   attribute:NSLayoutAttributeBottom
                                                                   relatedBy:NSLayoutRelationEqual
                                                                      toItem:self.mapView
                                                                   attribute:NSLayoutAttributeBottomMargin
                                                                  multiplier:1
                                                                    constant:-4];
    NSLayoutConstraint *leadingScale = [NSLayoutConstraint constraintWithItem:self.scaleView
                                                                    attribute:NSLayoutAttributeCenterXWithinMargins
                                                                    relatedBy:NSLayoutRelationEqual
                                                                       toItem:self.mapView
                                                                    attribute:NSLayoutAttributeCenterXWithinMargins
                                                                   multiplier:1
                                                                     constant:0];
    
    [NSLayoutConstraint activateConstraints:@[bottomScale, leadingScale]];
}

- (void)setupCompassButton {
    self.mapView.showsCompass = NO;
    MKCompassButton *compass = [MKCompassButton compassButtonWithMapView:self.mapView];
    compass.translatesAutoresizingMaskIntoConstraints = NO;
    compass.compassVisibility = MKFeatureVisibilityAdaptive;
    [self.view addSubview:compass];
    self.compassButton = compass;
    NSLayoutYAxisAnchor *compassTop = self.mapView.topAnchor;
    CGFloat compassTopConstant = 12.0;
    if (self.heartRateMapChip) {
        compassTop = self.heartRateMapChip.bottomAnchor;
        compassTopConstant = 8.0;
    }
    self.compassTopConstraint =
        [compass.topAnchor constraintEqualToAnchor:compassTop constant:compassTopConstant];
    [NSLayoutConstraint activateConstraints:@[
        [compass.trailingAnchor constraintEqualToAnchor:self.mapView.trailingAnchor constant:-12],
        self.compassTopConstraint,
    ]];
    [self.view bringSubviewToFront:compass];
    if (self.heartRateMapChip) {
        [self.view bringSubviewToFront:self.heartRateMapChip];
    }
}

#pragma mark - Instrumentation HUD

- (CGFloat)instrumentationTileSide {
    CGFloat side = self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad ? 160.0 : 96.0;
    if (self.traitCollection.userInterfaceIdiom != UIUserInterfaceIdiomPad
        && self.view.bounds.size.width > 0.0
        && self.view.bounds.size.width < 360.0) {
        side = 88.0;
    }
    return side;
}

- (void)updateInstrumentationTileSizes {
    CGFloat side = [self instrumentationTileSide];
    self.altimeterWidthConstraint.constant = side;
    self.altimeterHeightConstraint.constant = side;
    self.speedometerWidthConstraint.constant = side;
    self.speedometerHeightConstraint.constant = side;
}

- (void)buildInstrumentationHUD {
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentTop;
    stack.spacing = 10.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.userInteractionEnabled = NO;
    stack.alpha = 0.0;

    OTAltimeterView *altimeter = [[OTAltimeterView alloc] initWithFrame:CGRectZero];
    altimeter.translatesAutoresizingMaskIntoConstraints = NO;
    altimeter.usesImperial = YES;

    OTSpeedometerView *gauge = [[OTSpeedometerView alloc] initWithFrame:CGRectZero];
    gauge.translatesAutoresizingMaskIntoConstraints = NO;
    gauge.usesImperial = YES;
    gauge.maxSpeedKmh = 200.0;

    [stack addArrangedSubview:altimeter];
    [stack addArrangedSubview:gauge];
    [self.view addSubview:stack];

    self.instrumentationStack = stack;
    self.altimeterView = altimeter;
    self.speedometerView = gauge;

    CGFloat side = [self instrumentationTileSide];
    self.altimeterWidthConstraint = [altimeter.widthAnchor constraintEqualToConstant:side];
    self.altimeterHeightConstraint = [altimeter.heightAnchor constraintEqualToConstant:side];
    self.speedometerWidthConstraint = [gauge.widthAnchor constraintEqualToConstant:side];
    self.speedometerHeightConstraint = [gauge.heightAnchor constraintEqualToConstant:side];

    [NSLayoutConstraint activateConstraints:@[
        self.altimeterWidthConstraint,
        self.altimeterHeightConstraint,
        self.speedometerWidthConstraint,
        self.speedometerHeightConstraint,
        [stack.trailingAnchor constraintEqualToAnchor:self.heartRateMapChip.trailingAnchor],
    ]];

    [self updateInstrumentationTopConstraint];

    if (self.compassButton) {
        self.compassBelowInstrumentationConstraint =
            [self.compassButton.topAnchor constraintEqualToAnchor:stack.bottomAnchor constant:8.0];
    }
}

- (void)updateInstrumentationTopConstraint {
    if (!self.instrumentationStack) {
        return;
    }
    if (self.instrumentationTopConstraint) {
        self.instrumentationTopConstraint.active = NO;
    }
    NSLayoutYAxisAnchor *chromeTop;
    CGFloat topConstant = 0.0;
    if (self.trackingButton) {
        chromeTop = self.trackingButton.topAnchor;
    } else if (self.mapRouteFollowStack) {
        chromeTop = self.mapRouteFollowStack.topAnchor;
    } else {
        chromeTop = self.modes.bottomAnchor;
        topConstant = 8.0;
    }
    self.instrumentationTopConstraint =
        [self.instrumentationStack.topAnchor constraintEqualToAnchor:chromeTop constant:topConstant];
    self.instrumentationTopConstraint.active = YES;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection
        && self.traitCollection.userInterfaceIdiom != previousTraitCollection.userInterfaceIdiom) {
        [self updateInstrumentationTileSizes];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    static CGSize sLastInstrumentationLayoutSize;
    CGSize bounds = self.view.bounds.size;
    if (!CGSizeEqualToSize(bounds, sLastInstrumentationLayoutSize)) {
        sLastInstrumentationLayoutSize = bounds;
        [self updateInstrumentationTileSizes];
        [self updateInstrumentationTopConstraint];
    }
}

- (void)appendFollowVelocityKmh:(double)kmh forTopic:(NSString *)topic {
    if (!topic.length || kmh < 0.0) {
        return;
    }
    NSMutableArray<NSNumber *> *history = self.followVelocityHistoryKmhByTopic[topic];
    if (!history) {
        history = [NSMutableArray array];
        self.followVelocityHistoryKmhByTopic[topic] = history;
    }
    [history addObject:@(kmh)];
    while (history.count > kOTFollowInstrumentHistoryMax) {
        [history removeObjectAtIndex:0];
    }
}

- (void)appendFollowAltitudeMeters:(double)meters forTopic:(NSString *)topic {
    if (!topic.length || isnan(meters)) {
        return;
    }
    NSMutableArray<NSNumber *> *history = self.followAltitudeMetersByTopic[topic];
    if (!history) {
        history = [NSMutableArray array];
        self.followAltitudeMetersByTopic[topic] = history;
    }
    [history addObject:@(meters)];
    while (history.count > kOTFollowInstrumentHistoryMax) {
        [history removeObjectAtIndex:0];
    }
}

- (NSArray<NSNumber *> *)followVelocityHistoryForTopic:(NSString *)topic {
    return topic.length ? [self.followVelocityHistoryKmhByTopic[topic] copy] : @[];
}

- (NSArray<NSNumber *> *)followAltitudeHistoryForTopic:(NSString *)topic {
    return topic.length ? [self.followAltitudeMetersByTopic[topic] copy] : @[];
}

- (void)clearFollowInstrumentHistoryForTopic:(NSString *)topic {
    if (!topic.length) {
        return;
    }
    [self.followVelocityHistoryKmhByTopic removeObjectForKey:topic];
    [self.followAltitudeMetersByTopic removeObjectForKey:topic];
}

- (void)seedFollowInstrumentHistoryForFriend:(Friend *)friend {
    NSString *topic = friend.topic;
    if (!topic.length) {
        return;
    }
    [self clearFollowInstrumentHistoryForTopic:topic];
    Waypoint *wp = friend.newestWaypoint;
    if (wp.vel && wp.vel.doubleValue >= 0.0) {
        [self appendFollowVelocityKmh:wp.vel.doubleValue forTopic:topic];
    }
    if (wp.alt) {
        [self appendFollowAltitudeMeters:wp.alt.doubleValue forTopic:topic];
    }
}

- (void)setInstrumentationCompassBelowHUD:(BOOL)belowHUD {
    if (!self.compassButton || !self.compassTopConstraint || !self.compassBelowInstrumentationConstraint) {
        return;
    }
    if (belowHUD) {
        self.compassTopConstraint.active = NO;
        self.compassBelowInstrumentationConstraint.active = YES;
    } else {
        self.compassBelowInstrumentationConstraint.active = NO;
        self.compassTopConstraint.active = YES;
    }
}

- (void)refreshInstrumentationForFriend:(Friend *)friend {
    if (!friend) {
        return;
    }
    NSString *topic = friend.topic;
    Waypoint *wp = friend.newestWaypoint;
    double kmh = -1.0;
    if (wp.vel && wp.vel.doubleValue >= 0.0) {
        kmh = wp.vel.doubleValue;
    }
    double altM = NAN;
    if (wp.alt) {
        altM = wp.alt.doubleValue;
    }
    self.speedometerView.speedKmh = kmh;
    self.speedometerView.speedHistoryKmh = [self followVelocityHistoryForTopic:topic];
    self.altimeterView.altitudeMeters = altM;
    self.altimeterView.altitudeHistoryMeters = [self followAltitudeHistoryForTopic:topic];
}

- (void)showInstrumentationHUDForFriend:(Friend *)friend {
    if (!friend || !self.followEnabled) {
        return;
    }
    [self seedFollowInstrumentHistoryForFriend:friend];
    [self refreshInstrumentationForFriend:friend];
    [self updateInstrumentationTopConstraint];
    [self setInstrumentationCompassBelowHUD:YES];
    [self.view bringSubviewToFront:self.instrumentationStack];
    if (self.heartRateMapChip) {
        [self.view bringSubviewToFront:self.heartRateMapChip];
    }
    if (self.compassButton) {
        [self.view bringSubviewToFront:self.compassButton];
    }
    [UIView animateWithDuration:0.3
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ self.instrumentationStack.alpha = 1.0; }
                     completion:nil];
}

- (void)hideInstrumentationHUD {
    [UIView animateWithDuration:0.2
                          delay:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{ self.instrumentationStack.alpha = 0.0; }
                     completion:^(BOOL finished) {
        if (finished) {
            [self setInstrumentationCompassBelowHUD:NO];
        }
    }];
}

- (void)updateInstrumentationFromUserInfo:(NSDictionary *)info topic:(NSString *)topic {
    if (!topic.length) {
        return;
    }
    id velObj = info[@"vel"];
    if ([velObj isKindOfClass:[NSNumber class]]) {
        double kmh = [(NSNumber *)velObj doubleValue];
        if (kmh >= 0.0) {
            [self appendFollowVelocityKmh:kmh forTopic:topic];
        }
    }
    id altObj = info[@"alt"];
    if ([altObj isKindOfClass:[NSNumber class]]) {
        [self appendFollowAltitudeMeters:[(NSNumber *)altObj doubleValue] forTopic:topic];
    }
    Friend *friend = self.followFriend;
    if (friend && [friend.topic isEqualToString:topic]) {
        [self refreshInstrumentationForFriend:friend];
    }
}

#pragma mark - Map heart rate indicator

/// Self-contained colored badge: a filled circular plate with a white source glyph.
/// SF Symbols ships no `bluetooth` glyph, so the runic mark is rendered from a path.
+ (UIImage *)OT_hrSourceBadgeImageForSource:(OTHeartRateSource)source {
    const CGFloat side = 22.0;
    CGSize size = CGSizeMake(side, side);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIColor *plate = (source == OTHeartRateSourceBluetooth)
        ? [UIColor colorWithRed:0.18 green:0.49 blue:0.96 alpha:1.0]   // Bluetooth blue
        : [UIColor colorWithRed:0.98 green:0.07 blue:0.31 alpha:1.0];  // Apple Health red
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        [plate setFill];
        CGContextFillEllipseInRect(c, CGRectMake(0, 0, side, side));

        if (source == OTHeartRateSourceBluetooth) {
            // Runic glyph as a self-intersecting closed hexagon, even-odd filled.
            // Vertex coords are normalized then mapped into a centered box of ~52% of the plate.
            const CGFloat glyphSide = side * 0.52;
            const CGFloat ox = (side - glyphSide) / 2.0;
            const CGFloat oy = (side - glyphSide) / 2.0;
            CGPoint v[6] = {
                { 0.50, 0.00 }, { 0.78, 0.28 }, { 0.22, 0.72 },
                { 0.50, 1.00 }, { 0.78, 0.72 }, { 0.22, 0.28 },
            };
            UIBezierPath *path = [UIBezierPath bezierPath];
            path.usesEvenOddFillRule = YES;
            path.lineJoinStyle = kCGLineJoinRound;
            [path moveToPoint:CGPointMake(ox + v[0].x * glyphSide, oy + v[0].y * glyphSide)];
            for (int i = 1; i < 6; i++) {
                [path addLineToPoint:CGPointMake(ox + v[i].x * glyphSide, oy + v[i].y * glyphSide)];
            }
            [path closePath];
            [[UIColor whiteColor] setFill];
            [path fill];
        } else {
            // HealthKit: white heart.fill glyph centered on the red plate.
            UIImageSymbolConfiguration *cfg =
                [UIImageSymbolConfiguration configurationWithPointSize:side * 0.55
                                                                weight:UIImageSymbolWeightBold];
            UIImage *heart = [[UIImage systemImageNamed:@"heart.fill" withConfiguration:cfg]
                imageWithTintColor:[UIColor whiteColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
            CGSize hs = heart.size;
            // Optical centering: shift up ~5% — heart's mass sits below its bounding-box center.
            CGRect r = CGRectMake((side - hs.width) / 2.0,
                                  (side - hs.height) / 2.0 - side * 0.05,
                                  hs.width, hs.height);
            [heart drawInRect:r];
        }
    }];
}

- (void)setupMapHeartRateIndicator {
    UIControl *chip = [[UIControl alloc] init];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    chip.backgroundColor = [[UIColor secondarySystemGroupedBackgroundColor] colorWithAlphaComponent:0.92];
    chip.layer.cornerRadius = 8.0;
    chip.layer.masksToBounds = YES;
    chip.accessibilityTraits = UIAccessibilityTraitButton;
    [chip addTarget:self action:@selector(heartRateMapChipTapped) forControlEvents:UIControlEventTouchUpInside];
    chip.isAccessibilityElement = YES;
    self.heartRateMapChip = chip;

    UIImageSymbolConfiguration *heartCfg =
        [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
    UIImageView *heart = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"heart.fill" withConfiguration:heartCfg]];
    heart.translatesAutoresizingMaskIntoConstraints = NO;
    heart.tintColor = [UIColor secondaryLabelColor];
    heart.contentMode = UIViewContentModeCenter;
    heart.clipsToBounds = NO;
    self.heartRateMapHeartImageView = heart;

    UILabel *bpm = [[UILabel alloc] init];
    bpm.translatesAutoresizingMaskIntoConstraints = NO;
    bpm.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
    bpm.textColor = [UIColor secondaryLabelColor];
    bpm.text = NSLocalizedString(@"Map heart rate off", @"Map chip: monitoring disabled");
    bpm.textAlignment = NSTextAlignmentCenter;
    bpm.adjustsFontSizeToFitWidth = YES;
    bpm.minimumScaleFactor = 0.8;
    self.heartRateMapBPMLabel = bpm;

    UIImageView *badge = [[UIImageView alloc] init];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.contentMode = UIViewContentModeScaleAspectFit;
    badge.hidden = YES;
    self.heartRateMapSourceBadgeView = badge;

    [chip addSubview:heart];
    [chip addSubview:bpm];
    [chip addSubview:badge];

    [self.view addSubview:chip];
    [chip bringSubviewToFront:badge];

    [NSLayoutConstraint activateConstraints:@[
        [chip.trailingAnchor constraintEqualToAnchor:self.mapView.trailingAnchor constant:-12],
        [chip.topAnchor constraintEqualToAnchor:self.mapView.topAnchor constant:12],
        [chip.heightAnchor constraintEqualToConstant:32],
        [chip.widthAnchor constraintGreaterThanOrEqualToConstant:64],

        [heart.leadingAnchor constraintEqualToAnchor:chip.leadingAnchor constant:8],
        [heart.centerYAnchor constraintEqualToAnchor:chip.centerYAnchor],
        [heart.widthAnchor constraintEqualToConstant:18],
        [heart.heightAnchor constraintEqualToConstant:18],

        [bpm.leadingAnchor constraintEqualToAnchor:heart.trailingAnchor constant:5],
        [bpm.trailingAnchor constraintEqualToAnchor:chip.trailingAnchor constant:-8],
        [bpm.centerYAnchor constraintEqualToAnchor:chip.centerYAnchor],

        [badge.widthAnchor constraintEqualToConstant:11],
        [badge.heightAnchor constraintEqualToConstant:11],
        [badge.trailingAnchor constraintEqualToAnchor:heart.trailingAnchor constant:3],
        [badge.bottomAnchor constraintEqualToAnchor:heart.bottomAnchor constant:3],
    ]];

    __weak typeof(self) weakSelf = self;
    self.heartRateMapNotificationTokenHK =
        [[NSNotificationCenter defaultCenter] addObserverForName:OTHealthKitHeartRateDidUpdateNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
        [weakSelf updateMapHeartRateIndicatorAppearance];
    }];
    self.heartRateMapNotificationTokenBLE =
        [[NSNotificationCenter defaultCenter] addObserverForName:OTBluetoothHeartRateDidUpdateNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
        [weakSelf updateMapHeartRateIndicatorAppearance];
    }];
    self.heartRateMapNotificationTokenPref =
        [[NSNotificationCenter defaultCenter] addObserverForName:OTHeartRateMonitoringEnabledDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
        [weakSelf updateMapHeartRateIndicatorAppearance];
    }];

    [self updateMapHeartRateIndicatorAppearance];
}

- (void)heartRateMapChipTapped {
    BOOL on = ![OTHeartRateMonitoring isMonitoringEnabled];
    [OTHeartRateMonitoring setMonitoringEnabled:on];
}

- (void)updateMapHeartRateIndicatorAppearance {
    if (!self.heartRateMapChip) {
        return;
    }
    const NSTimeInterval kMaxAge = 15 * 60;
    BOOL monitoring = [OTHeartRateMonitoring isMonitoringEnabled];
    OTHeartRateSource src = OTHeartRateSourceNone;
    NSNumber *bpmValue = nil;
    if (monitoring) {
        bpmValue = [OTHeartRateMonitoring resolvedHeartRateBPMWithMaxSampleAge:kMaxAge outSource:&src];
    }

    if (!monitoring) {
        self.heartRateMapHeartImageView.tintColor = [UIColor tertiaryLabelColor];
        self.heartRateMapBPMLabel.textColor = [UIColor tertiaryLabelColor];
        self.heartRateMapBPMLabel.text = NSLocalizedString(@"Map heart rate off", @"Map chip: monitoring disabled");
        self.heartRateMapSourceBadgeView.hidden = YES;
        self.heartRateMapChip.accessibilityLabel = NSLocalizedString(@"Heart rate monitoring", @"Accessibility label map HR chip");
        self.heartRateMapChip.accessibilityValue = NSLocalizedString(@"Off", @"Accessibility value HR monitoring off");
        self.heartRateMapChip.accessibilityHint = NSLocalizedString(@"Map heart rate hint off", @"VoiceOver hint to turn HR monitoring on");
        return;
    }

    self.heartRateMapHeartImageView.tintColor = [UIColor systemPinkColor];
    self.heartRateMapBPMLabel.textColor = [UIColor labelColor];
    BOOL hasBpm = (bpmValue != nil && bpmValue.intValue > 0);
    if (hasBpm) {
        self.heartRateMapBPMLabel.text = [NSString stringWithFormat:NSLocalizedString(@"%d bpm", @"Beats per minute integer on map chip"),
                                                                   bpmValue.intValue];
    } else {
        self.heartRateMapBPMLabel.text = NSLocalizedString(@"Map heart rate em dash", @"Map chip: monitoring on but no sample");
    }

    NSString *bleHint = [[BluetoothHeartRateManager sharedInstance] connectionTroubleHint];
    BOOL showBleHint = (bleHint.length > 0);

    UIImage *btIcon = [ViewController OT_hrSourceBadgeImageForSource:OTHeartRateSourceBluetooth];
    UIImage *hkIcon = [ViewController OT_hrSourceBadgeImageForSource:OTHeartRateSourceHealthKit];

    BOOL bleConnected = [[BluetoothHeartRateManager sharedInstance] isHeartRatePeripheralConnected];
    NSNumber *hkStale = [[HealthKitHeartRateManager sharedInstance] heartRateIfSampleWithin:kMaxAge];

    self.heartRateMapSourceBadgeView.alpha = 1.0;
    // Prefer the heart-corner Bluetooth glyph whenever a BLE GATT session is active, even if the
    // numeric BPM is currently resolved from Apple Health (strap quiet / BLE sample stale window).
    if (bleConnected) {
        self.heartRateMapSourceBadgeView.image = btIcon;
        self.heartRateMapSourceBadgeView.hidden = NO;
        if (hasBpm && src == OTHeartRateSourceBluetooth) {
            self.heartRateMapSourceBadgeView.alpha = 1.0;
        } else if (hasBpm) {
            self.heartRateMapSourceBadgeView.alpha = 0.88;
        } else {
            self.heartRateMapSourceBadgeView.alpha = 0.55;
        }
        if (hasBpm && src == OTHeartRateSourceBluetooth) {
            if (showBleHint) {
                self.heartRateMapChip.accessibilityValue =
                    [NSString stringWithFormat:@"%@. %@",
                                              [NSString stringWithFormat:NSLocalizedString(@"%d bpm from Bluetooth", @"A11y map HR Bluetooth"),
                                                                         bpmValue.intValue],
                                              bleHint];
            } else {
                self.heartRateMapChip.accessibilityValue =
                    [NSString stringWithFormat:NSLocalizedString(@"%d bpm from Bluetooth", @"A11y map HR Bluetooth"), bpmValue.intValue];
            }
        } else if (hasBpm && src == OTHeartRateSourceHealthKit) {
            self.heartRateMapChip.accessibilityValue =
                [NSString stringWithFormat:NSLocalizedString(@"Map heart rate a11y BPM Health BLE linked",
                                                             @"VoiceOver: BPM from Health while Bluetooth strap is connected"),
                                         bpmValue.intValue];
        } else if (showBleHint) {
            self.heartRateMapChip.accessibilityValue =
                [NSString stringWithFormat:@"%@ %@",
                                          NSLocalizedString(@"Map heart rate a11y BLE connected", @"VoiceOver: BLE HR monitor connected, no BPM yet"),
                                          bleHint];
        } else {
            self.heartRateMapChip.accessibilityValue =
                NSLocalizedString(@"Map heart rate a11y BLE connected", @"VoiceOver: BLE HR monitor connected, no BPM yet");
        }
    } else if (hasBpm && src == OTHeartRateSourceBluetooth) {
        self.heartRateMapSourceBadgeView.image = btIcon;
        self.heartRateMapSourceBadgeView.hidden = NO;
        self.heartRateMapSourceBadgeView.alpha = 1.0;
        if (showBleHint) {
            self.heartRateMapChip.accessibilityValue =
                [NSString stringWithFormat:@"%@. %@",
                                          [NSString stringWithFormat:NSLocalizedString(@"%d bpm from Bluetooth", @"A11y map HR Bluetooth"),
                                                                     bpmValue.intValue],
                                          bleHint];
        } else {
            self.heartRateMapChip.accessibilityValue =
                [NSString stringWithFormat:NSLocalizedString(@"%d bpm from Bluetooth", @"A11y map HR Bluetooth"), bpmValue.intValue];
        }
    } else if (hasBpm && src == OTHeartRateSourceHealthKit) {
        self.heartRateMapSourceBadgeView.image = hkIcon;
        self.heartRateMapSourceBadgeView.hidden = NO;
        self.heartRateMapSourceBadgeView.alpha = 1.0;
        self.heartRateMapChip.accessibilityValue = [NSString stringWithFormat:NSLocalizedString(@"%d bpm from Apple Health", @"A11y map HR HealthKit"),
                                                                                     bpmValue.intValue];
    } else if (!hasBpm && hkStale != nil && hkStale.intValue > 0) {
        // No live BLE session; Health still has a recent sample (e.g. Polar → Health, or Watch).
        self.heartRateMapSourceBadgeView.image = hkIcon;
        self.heartRateMapSourceBadgeView.hidden = NO;
        self.heartRateMapSourceBadgeView.alpha = 0.55;
        self.heartRateMapChip.accessibilityValue =
            NSLocalizedString(@"Map heart rate a11y Health recent", @"VoiceOver: recent HR from Apple Health only");
    } else if (showBleHint) {
        self.heartRateMapSourceBadgeView.image = btIcon;
        self.heartRateMapSourceBadgeView.hidden = NO;
        self.heartRateMapSourceBadgeView.alpha = 0.45;
        self.heartRateMapChip.accessibilityValue =
            [NSString stringWithFormat:@"%@ %@", NSLocalizedString(@"No recent heart rate", @"A11y map HR no sample"), bleHint];
    } else {
        self.heartRateMapSourceBadgeView.hidden = YES;
        self.heartRateMapChip.accessibilityValue = NSLocalizedString(@"No recent heart rate", @"A11y map HR no sample");
    }
    self.heartRateMapChip.accessibilityLabel = NSLocalizedString(@"Heart rate monitoring", @"Accessibility label map HR chip");
    self.heartRateMapChip.accessibilityHint = NSLocalizedString(@"Map heart rate hint on", @"VoiceOver hint to turn HR monitoring off");
}

#pragma mark - Route history (Recorder window + UI)

/// Matches `MKUserTrackingButton` / `MKMapView` tint (falls back to system blue).
- (UIColor *)OT_mapControlActiveTint {
    if (self.trackingButton.tintColor) {
        return self.trackingButton.tintColor;
    }
    if (self.mapView.tintColor) {
        return self.mapView.tintColor;
    }
    return [UIColor systemBlueColor];
}

- (UIColor *)OT_mapControlInactiveTint {
    return [UIColor secondaryLabelColor];
}

- (NSInteger)routeHistoryHours {
    NSInteger h = [[NSUserDefaults standardUserDefaults] integerForKey:kMapRouteHistoryHoursKey];
    return (h == 6) ? 6 : 12;
}

- (void)setRouteHistoryHours:(NSInteger)hours {
    NSInteger h = (hours == 6) ? 6 : 12;
    [[NSUserDefaults standardUserDefaults] setInteger:h forKey:kMapRouteHistoryHoursKey];
}

- (void)setupMapRouteFollowControlsRow {
    const CGFloat kHit = 44.0;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 10.0;
    self.mapRouteFollowStack = stack;
    self.mapRouteFollowStackLayoutConstraints = [NSMutableArray array];

    UIButton *routeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    routeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    routeBtn.hidden = YES;
    [routeBtn addTarget:self action:@selector(routeHistoryToggleTapped:) forControlEvents:UIControlEventTouchUpInside];
    self.routeHistoryToggleButton = routeBtn;

    UIButton *followBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    followBtn.translatesAutoresizingMaskIntoConstraints = NO;
    followBtn.hidden = YES;
    [followBtn addTarget:self action:@selector(followToggleTapped:) forControlEvents:UIControlEventTouchUpInside];
    self.followToggleButton = followBtn;

    [stack addArrangedSubview:routeBtn];
    [stack addArrangedSubview:followBtn];
    [self.view addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [routeBtn.widthAnchor constraintEqualToConstant:kHit],
        [routeBtn.heightAnchor constraintEqualToConstant:kHit],
        [followBtn.widthAnchor constraintEqualToConstant:kHit],
        [followBtn.heightAnchor constraintEqualToConstant:kHit],
    ]];

    [self updateRouteHistoryToggleAppearance];
    [self updateFollowToggleAppearance];
    [self updateMapRouteFollowStackLayoutConstraints];
    [self.view bringSubviewToFront:stack];
}

/// Positions `mapRouteFollowStack` to the right of `MKUserTrackingButton`, or under `modes` when tracking is absent.
- (void)updateMapRouteFollowStackLayoutConstraints {
    if (!self.mapRouteFollowStack) {
        return;
    }
    [NSLayoutConstraint deactivateConstraints:self.mapRouteFollowStackLayoutConstraints];
    [self.mapRouteFollowStackLayoutConstraints removeAllObjects];

    if (self.trackingButton) {
        [self.mapRouteFollowStackLayoutConstraints addObjectsFromArray:@[
            [self.mapRouteFollowStack.leadingAnchor constraintEqualToAnchor:self.trackingButton.trailingAnchor constant:12.0],
            [self.mapRouteFollowStack.centerYAnchor constraintEqualToAnchor:self.trackingButton.centerYAnchor],
        ]];
    } else {
        [self.mapRouteFollowStackLayoutConstraints addObjectsFromArray:@[
            [self.mapRouteFollowStack.leadingAnchor constraintEqualToAnchor:self.mapView.leadingAnchor constant:10.0],
            [self.mapRouteFollowStack.topAnchor constraintEqualToAnchor:self.modes.bottomAnchor constant:8.0],
        ]];
    }
    [NSLayoutConstraint activateConstraints:self.mapRouteFollowStackLayoutConstraints];
    [self updateInstrumentationTopConstraint];
}

- (void)updateFollowToggleAppearance {
    if (!self.followToggleButton) {
        return;
    }
    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    cfg.background.backgroundColor = [UIColor clearColor];
    UIImage *sym = [UIImage systemImageNamed:@"dot.scope"];
    cfg.image = sym;
    cfg.preferredSymbolConfigurationForImage =
        [UIImageSymbolConfiguration configurationWithPointSize:18.0 weight:UIImageSymbolWeightSemibold];
    cfg.baseForegroundColor = self.followEnabled ? [self OT_mapControlActiveTint] : [self OT_mapControlInactiveTint];
    self.followToggleButton.configuration = cfg;

    self.followToggleButton.accessibilityLabel = NSLocalizedString(@"Follow camera", @"Accessibility: follow map camera");
    self.followToggleButton.accessibilityValue = self.followEnabled
        ? NSLocalizedString(@"On", @"Accessibility: toggle on")
        : NSLocalizedString(@"Off", @"Accessibility: toggle off");
    self.followToggleButton.accessibilityHint =
        NSLocalizedString(@"Double tap to turn map camera follow on or off.", @"Accessibility: follow toggle hint");
}

- (void)updateFollowToggleVisibility {
    if (!self.followToggleButton) {
        return;
    }
    self.followToggleButton.hidden = (self.selectedFriend == nil);
    if (!self.followToggleButton.hidden) {
        [self.view bringSubviewToFront:self.mapRouteFollowStack];
    }
    if (self.compassButton) {
        [self.view bringSubviewToFront:self.compassButton];
    }
}

- (void)updateRouteHistoryToggleAppearance {
    if (!self.routeHistoryToggleButton) {
        return;
    }
    NSInteger h = [self routeHistoryHours];
    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    cfg.background.backgroundColor = [UIColor clearColor];
    cfg.image = OTRouteHistoryWindowClockImage(20.0, h);
    cfg.baseForegroundColor = [self OT_mapControlActiveTint];
    self.routeHistoryToggleButton.configuration = cfg;

    NSString *windowLabel = (h == 12)
        ? NSLocalizedString(@"12 hours", @"Accessibility: route history 12 hour window")
        : NSLocalizedString(@"6 hours", @"Accessibility: route history 6 hour window");
    self.routeHistoryToggleButton.accessibilityLabel =
        NSLocalizedString(@"Route history window", @"Accessibility: route history window control");
    self.routeHistoryToggleButton.accessibilityValue = windowLabel;
    self.routeHistoryToggleButton.accessibilityHint =
        NSLocalizedString(@"Double tap to switch between 6 and 12 hours of route history.", @"Accessibility: route window hint");
}

- (void)updateRouteHistoryToggleVisibility {
    if (!self.routeHistoryToggleButton) {
        return;
    }
    Friend *f = self.selectedFriend;
    if (!f) {
        self.routeHistoryToggleButton.hidden = YES;
        return;
    }
    if ([[LocationAPISyncService sharedInstance] hasAuthorizationUserProfilePayload] &&
        ![[LocationAPISyncService sharedInstance] currentUserMayViewRouteHistory]) {
        self.routeHistoryToggleButton.hidden = YES;
        return;
    }
    NSString *t = f.topic;
    BOOL show = (self.liveTrackPolylines[t] != nil)
        || [self.pendingRouteTopics containsObject:t]
        || (self.liveTrackPoints[t].count >= 2);
    self.routeHistoryToggleButton.hidden = !show;
    if (show) {
        [self updateRouteHistoryToggleAppearance];
        [self.view bringSubviewToFront:self.mapRouteFollowStack];
    }
    if (self.compassButton) {
        [self.view bringSubviewToFront:self.compassButton];
    }
}

- (void)routeHistoryToggleTapped:(UIButton *)sender {
    NSInteger next = ([self routeHistoryHours] == 12) ? 6 : 12;
    [self setRouteHistoryHours:next];
    [self updateRouteHistoryToggleAppearance];

    Friend *f = self.selectedFriend;
    if (f) {
        NSString *t = f.topic;
        MKPolyline *pl = self.liveTrackPolylines[t];
        if (pl) {
            [self.mapView removeOverlay:pl];
            [self.liveTrackPolylines removeObjectForKey:t];
        }
        [self.routeFetchedTopics removeObject:t];
        [self.pendingRouteTopics removeObject:t];
        CLLocationCoordinate2D c = f.coordinate;
        if (CLLocationCoordinate2DIsValid(c)) {
            self.liveTrackPoints[t] = [NSMutableArray arrayWithObject:[NSValue valueWithMKCoordinate:c]];
            NSTimeInterval seedUnix = [[NSDate date] timeIntervalSince1970];
            Waypoint *nw = f.newestWaypoint;
            if (nw.tst) {
                seedUnix = [nw.tst timeIntervalSince1970];
            }
            self.liveTrackPointUnixByTopic[t] = [NSMutableArray arrayWithObject:@(seedUnix)];
        } else {
            self.liveTrackPoints[t] = [NSMutableArray array];
            self.liveTrackPointUnixByTopic[t] = [NSMutableArray array];
        }
        [self fetchRouteForFriend:f mapView:self.mapView historyHours:next];
    }
    [self updateRouteHistoryToggleVisibility];
}

- (void)followToggleTapped:(UIButton *)sender {
    self.followEnabled = !self.followEnabled;
    [self updateFollowToggleAppearance];
    Friend *f = self.selectedFriend;
    if (!f) {
        return;
    }
    if (!self.followEnabled) {
        self.followFriend = nil;
        self.followHeadingTargetNumber = nil;
        [self stopFollowLink];
        [self hideInstrumentationHUD];
        return;
    }
    self.followFriend = f;
    self.followHeadingLockPausedByUserGesture = NO;
    Waypoint *wpHeading = f.newestWaypoint;
    double initialHeading = NAN;
    if (wpHeading.cog && OTHeadingDegreesValid(wpHeading.cog.doubleValue)) {
        initialHeading = OTNormalizeHeadingDegrees(wpHeading.cog.doubleValue);
    }
    if (initialHeading == initialHeading) {
        self.followHeadingTargetNumber = @(initialHeading);
    } else {
        self.followHeadingTargetNumber = nil;
    }
    [self applyFollow3DCameraToCoordinate:f.coordinate
                                  heading:initialHeading
                       preserveUserAltitude:YES];
    [self startFollowLink];
    [self showInstrumentationHUDForFriend:f];
}

/// Removes live-track `MKPolyline` overlays for all topics except `topic` (nil = remove all).
- (void)removeFriendLiveTrackOverlaysExceptTopic:(NSString *)topic {
    NSArray<NSString *> *keys = [self.liveTrackPolylines.allKeys copy];
    NSUInteger removed = 0;
    for (NSString *k in keys) {
        if (topic.length && [k isEqualToString:topic]) {
            continue;
        }
        MKPolyline *pl = self.liveTrackPolylines[k];
        if (pl) {
            [self.mapView removeOverlay:pl];
            [self.liveTrackPolylines removeObjectForKey:k];
            removed++;
            DDLogInfo(@"[RouteDebug] remove liveTrack MKPolyline topic=%@ (keeping %@)",
                      k, topic.length ? topic : @"(none)");
        }
    }
    if (removed || keys.count) {
        DDLogInfo(@"[RouteDebug] liveTrackPolylines keys now %lu (removed %lu), followFriend=%@",
                  (unsigned long)self.liveTrackPolylines.count, (unsigned long)removed,
                  self.followFriend.topic ?: @"(nil)");
    }
}

/// Core Data waypoint trails: `Friend` used as `MKOverlay` (renderer uses `friend.polyLine`).
/// Only the followed friend should show this breadcrumb; others must be removed or the map shows every trail at once.
- (void)removeFriendBreadcrumbOverlaysExceptFriend:(Friend *)friendOrNil {
    NSArray<id<MKOverlay>> *overlays = [self.mapView.overlays copy];
    NSUInteger removed = 0;
    for (id<MKOverlay> ov in overlays) {
        if (![ov isKindOfClass:[Friend class]]) {
            continue;
        }
        Friend *f = (Friend *)ov;
        if (friendOrNil && f == friendOrNil) {
            continue;
        }
        [self.mapView removeOverlay:f];
        removed++;
        DDLogInfo(@"[RouteDebug] remove Friend breadcrumb overlay topic=%@", f.topic);
    }
    DDLogInfo(@"[RouteDebug] Friend breadcrumb overlays removed=%lu keep=%@ mapOverlays=%lu",
              (unsigned long)removed,
              friendOrNil.topic ?: @"(nil)",
              (unsigned long)self.mapView.overlays.count);
}

/// `Friend.polyLine` pulls up to 1000 Core Data waypoints (weeks/months). When a Recorder/MQTT `MKPolyline`
/// is already shown for the same topic, drawing both yields duplicate red lines and jagged jumps to old fixes.
- (BOOL)liveTrackPolylineSupersedesBreadcrumbForTopic:(NSString *)topic {
    return topic.length && self.liveTrackPolylines[topic] != nil;
}

/// Ensures only `followed` has a waypoint-breadcrumb overlay; adds/refreshes theirs, strips all others.
- (void)syncFollowedFriendBreadcrumbOverlay:(Friend *)followed {
    if (followed && [self liveTrackPolylineSupersedesBreadcrumbForTopic:followed.topic]) {
        [self removeFriendBreadcrumbOverlaysExceptFriend:nil];
        DDLogInfo(@"[RouteDebug] breadcrumb suppressed; liveTrack MKPolyline already shows topic=%@",
                  followed.topic);
        return;
    }
    [self removeFriendBreadcrumbOverlaysExceptFriend:followed];
    if (!followed) {
        return;
    }
    Waypoint *wp = followed.newestWaypoint;
    BOOL hadWaypoint = wp && (wp.lat).doubleValue != 0.0 && (wp.lon).doubleValue != 0.0;
    if (!hadWaypoint) {
        DDLogInfo(@"[RouteDebug] sync breadcrumb: no waypoint for %@", followed.topic);
        return;
    }
    if (![self.mapView.overlays containsObject:followed]) {
        [self.mapView addOverlay:followed];
        DDLogInfo(@"[RouteDebug] add Friend breadcrumb overlay topic=%@", followed.topic);
    } else {
        [self.mapView removeOverlay:followed];
        [self.mapView addOverlay:followed];
        DDLogInfo(@"[RouteDebug] refresh Friend breadcrumb overlay topic=%@", followed.topic);
    }
}

- (void)refreshFriendAnnotationViewForFriend:(Friend *)friend {
    MKAnnotationView *v = [self.mapView viewForAnnotation:friend];
    if (![v isKindOfClass:[FriendAnnotationV class]]) {
        return;
    }
    FriendAnnotationV *friendAnnotationV = (FriendAnnotationV *)v;
    Waypoint *waypoint = friend.newestWaypoint;
    NSData *data = friend.image;
    UIImage *image = [UIImage imageWithData:data];
    friendAnnotationV.personImage = image;
    friendAnnotationV.tid = friend.effectiveTid;
    friendAnnotationV.speed = (waypoint.vel).doubleValue;
    friendAnnotationV.course = (waypoint.cog).doubleValue;
    friendAnnotationV.me = [friend.topic isEqualToString:[Settings theGeneralTopicInMOC:CoreData.sharedInstance.mainMOC]];
    [friendAnnotationV setNeedsDisplay];
    if (self.followFriend && [self.followFriend.topic isEqualToString:friend.topic] && self.followEnabled) {
        if (waypoint.vel && waypoint.vel.doubleValue >= 0.0) {
            [self appendFollowVelocityKmh:waypoint.vel.doubleValue forTopic:friend.topic];
        }
        if (waypoint.alt) {
            [self appendFollowAltitudeMeters:waypoint.alt.doubleValue forTopic:friend.topic];
        }
        [self refreshInstrumentationForFriend:friend];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    if ([keyPath isEqualToString:@"monitoring"]) {
        [self updateMoveButton];
    }
    if ([keyPath isEqualToString:@"userLocation"] ||
        [keyPath isEqualToString:@"userLocation.location"]) {
        [self updateAccuracyButton];
    }
}

- (IBAction)modesChanged:(UISegmentedControl *)segmentedControl {
    int monitoring;
    switch (segmentedControl.selectedSegmentIndex) {
        case 3:
            monitoring = LocationMonitoringMove;
            break;
        case 2:
            monitoring = LocationMonitoringSignificant;
            break;
        case 1:
            monitoring = LocationMonitoringManual;
            break;
        case 0:
        default:
            monitoring = LocationMonitoringQuiet;
            break;
    }
    if (monitoring != [LocationManager sharedInstance].monitoring) {
        [LocationManager sharedInstance].monitoring = monitoring;
        [[NSUserDefaults standardUserDefaults] setBool:FALSE forKey:@"downgraded"];
        [[NSUserDefaults standardUserDefaults] setBool:FALSE forKey:@"adapted"];
        [Settings setInt:(int)[LocationManager sharedInstance].monitoring forKey:@"monitoring_preference"
                   inMOC:CoreData.sharedInstance.mainMOC];
        [CoreData.sharedInstance sync:CoreData.sharedInstance.mainMOC];
        [self updateMoveButton];
    }
}

- (void)updateMoveButton {
    BOOL locked = [Settings theLockedInMOC:CoreData.sharedInstance.mainMOC];
    self.modes.enabled = !locked;

    switch ([LocationManager sharedInstance].monitoring) {
        case LocationMonitoringMove:
            self.modes.selectedSegmentIndex = 3;
            break;
        case LocationMonitoringSignificant:
            self.modes.selectedSegmentIndex = 2;
            break;
        case LocationMonitoringManual:
            self.modes.selectedSegmentIndex = 1;
            break;
        case LocationMonitoringQuiet:
        default:
            self.modes.selectedSegmentIndex = 0;
            break;
    }

    for (NSInteger index = 0; index < self.modes.numberOfSegments; index++) {
        NSString *title = [self.modes titleForSegmentAtIndex:index];
        if ([title hasSuffix:@"#"]) {
            title = [title substringToIndex:title.length-1];
        }
        if ([title hasSuffix:@"!"]) {
            title = [title substringToIndex:title.length-1];
        }
        [self.modes setTitle:title forSegmentAtIndex:index];

    }
    
    NSInteger index = self.modes.selectedSegmentIndex;
    NSString *title = [self.modes titleForSegmentAtIndex:index];
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"downgraded"]) {
        if (![title hasSuffix:@"!"]) {
            title = [title stringByAppendingString:@"!"];
        }
    }
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"adapted"]) {
        if (![title hasSuffix:@"#"]) {
            title = [title stringByAppendingString:@"#"];
        }
    }
    [self.modes setTitle:title forSegmentAtIndex:index];

}

- (void)updateAccuracyButton {
    CLLocation *location = self.mapView.userLocation.location;    
    self.accuracyButton.title = [Waypoint CLLocationAccuracyText:location];
    self.actionButton.enabled = ![self.accuracyButton.title isEqualToString:@"-"];
}

- (void)reloaded {
    self.frcFriends = nil;
    self.frcRegions = nil;
    self.frcWaypoints = nil;
    [self updateMoveButton];
    [self setMapMode:self.mapMode];
}

- (NSInteger)noMap {
    BOOL locked = [Settings theLockedInMOC:CoreData.sharedInstance.mainMOC];
    self.askForMapButton.enabled = !locked;


    NSInteger noMap =
    [[NSUserDefaults standardUserDefaults] integerForKey:@"noMap"];
    
    if (noMap > 0) {
        self.mapView.showsUserLocation = TRUE;
        self.mapView.zoomEnabled = TRUE;
        self.mapView.scrollEnabled = TRUE;
        self.mapView.pitchEnabled = TRUE;
        self.mapView.rotateEnabled = TRUE;
        self.compassButton.hidden = NO;

        if (!self.trackingButton) {
            self.trackingButton = [MKUserTrackingButton userTrackingButtonWithMapView:self.mapView];
            self.trackingButton.translatesAutoresizingMaskIntoConstraints = false;
            [self.view addSubview:self.trackingButton];
            
            NSLayoutConstraint *topTracking = [NSLayoutConstraint
                                                  constraintWithItem:self.trackingButton
                                                  attribute:NSLayoutAttributeTop
                                                  relatedBy:NSLayoutRelationEqual
                                                  toItem:self.modes
                                                  attribute:NSLayoutAttributeBottom
                                                  multiplier:1
                                                  constant:8];
            NSLayoutConstraint *leadingTracking = [NSLayoutConstraint
                                                   constraintWithItem:self.trackingButton
                                                   attribute:NSLayoutAttributeLeading
                                                   relatedBy:NSLayoutRelationEqual
                                                   toItem:self.mapView
                                                   attribute:NSLayoutAttributeLeading
                                                   multiplier:1
                                                   constant:10];
            
            [NSLayoutConstraint activateConstraints:@[topTracking, leadingTracking]];
        }
    } else {
        self.mapView.showsUserLocation = TRUE;
        self.mapView.zoomEnabled = FALSE;
        self.mapView.scrollEnabled = FALSE;
        self.mapView.pitchEnabled = FALSE;
        self.mapView.rotateEnabled = FALSE;
        self.compassButton.hidden = YES;

        if (self.trackingButton) {
            [self.trackingButton removeFromSuperview];
            self.trackingButton = nil;
        }
    }

    [self updateMapRouteFollowStackLayoutConstraints];
    [self updateInstrumentationTopConstraint];
    [self updateFollowToggleAppearance];
    if (self.routeHistoryToggleButton && !self.routeHistoryToggleButton.hidden) {
        [self updateRouteHistoryToggleAppearance];
    }

    return noMap;
}

- (IBAction)askForMap:(UIBarButtonItem *)sender {
    UIAlertController *ac =
    [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Map Interaction",
                                                                  @"Title map interaction")
                                        message:NSLocalizedString(@"Do you want the map to allow interaction? If you choose yes, the map provider may analyze your tile requests",
                                                                  @"Message map interaction")
                                 preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *yes = [UIAlertAction
                          actionWithTitle:NSLocalizedString(@"Yes",
                                                            @"Yes button title")
                          
                          style:UIAlertActionStyleDefault
                          handler:^(UIAlertAction * action) {
        [[NSUserDefaults standardUserDefaults] setInteger:1 forKey:@"noMap"];
        [self noMap];
        [self askForRevgeo:nil];
    }];
    UIAlertAction *no = [UIAlertAction
                         actionWithTitle:NSLocalizedString(@"No",
                                                           @"No button title")
                         
                         style:UIAlertActionStyleDestructive
                         handler:^(UIAlertAction * action) {
        [[NSUserDefaults standardUserDefaults] setInteger:-1 forKey:@"noMap"];
        [self noMap];
        [self askForRevgeo:nil];
    }];
    
    [ac addAction:yes];
    [ac addAction:no];
    if (self.presentedViewController) {
        [self performSelector:@selector(askForMap:) withObject:sender afterDelay:1];
    } else {
        [self presentViewController:ac animated:TRUE completion:nil];
    }
}

- (IBAction)askForRevgeo:(UIBarButtonItem *)sender {
    UIAlertController *ac =
    [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Reverse Geocoding Address Resolution",
                                                                  @"Title Revgeo")
                                        message:NSLocalizedString(@"Do you want to resolve adresses? If you choose yes, the geocoding provider may analyze your requests",
                                                                  @"Message Revgeo")
                                 preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *yes = [UIAlertAction
                          actionWithTitle:NSLocalizedString(@"Yes",
                                                            @"Yes button title")
                          
                          style:UIAlertActionStyleDefault
                          handler:^(UIAlertAction * action) {
        [[NSUserDefaults standardUserDefaults] setInteger:1 forKey:@"noRevgeo"];
    }];
    UIAlertAction *no = [UIAlertAction
                         actionWithTitle:NSLocalizedString(@"No",
                                                           @"No button title")
                         
                         style:UIAlertActionStyleDestructive
                         handler:^(UIAlertAction * action) {
        [[NSUserDefaults standardUserDefaults] setInteger:-1 forKey:@"noRevgeo"];
    }];
    
    [ac addAction:yes];
    [ac addAction:no];
    if (self.presentedViewController) {
        [self performSelector:@selector(askForMap:) withObject:sender afterDelay:1];
    } else {
        [self presentViewController:ac animated:TRUE completion:nil];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    id<UIApplicationDelegate> del = [UIApplication sharedApplication].delegate;
    if ([del isKindOfClass:[OwnTracksAppDelegate class]]) {
        [(OwnTracksAppDelegate *)del requestHUDAwakeWhileChargingWithReason:OTHUDIdleTimerReasonMap];
    }
    [self configureTopNavigationBar];
    [self refreshBellUnreadBadge];
    [self fetchCurrentUserProfileIfSignedIn];

    while (!self.frcFriends) {
        //
    }
    while (!self.frcRegions) {
        //
    }
    while (!self.frcWaypoints) {
        //
    }
    
    [self mapModeChanged:self.mapMode];
    
    if (!self.warning &&
        ![Setting existsSettingWithKey:@"mode" inMOC:CoreData.sharedInstance.mainMOC]) {
        self.warning = TRUE;
        [NavigationController alert:
             NSLocalizedString(@"Setup",
                               @"Header of an alert message regarding missing setup")
                            message:
             NSLocalizedString(@"You need to setup your own OwnTracks server and edit your configuration for full privacy protection. Detailed info on https://owntracks.org/booklet",
                               @"Text explaining the Setup")
        ];
    }
    
    // Map interaction and reverse geocoding are now ON by default; no prompt.

    // Only one Friend may show the Core Data waypoint breadcrumb; clear leftovers when not following.
    if (!self.selectedFriend) {
        [self removeFriendBreadcrumbOverlaysExceptFriend:nil];
    } else {
        [self syncFollowedFriendBreadcrumbOverlay:self.selectedFriend];
    }
    if (self.mapRouteFollowStack) {
        [self.view bringSubviewToFront:self.mapRouteFollowStack];
    }
    if (self.trackingButton) {
        [self.view bringSubviewToFront:self.trackingButton];
    }
    if (self.compassButton) {
        [self.view bringSubviewToFront:self.compassButton];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    id<UIApplicationDelegate> del = [UIApplication sharedApplication].delegate;
    if ([del isKindOfClass:[OwnTracksAppDelegate class]]) {
        [(OwnTracksAppDelegate *)del releaseHUDAwakeWhileChargingWithReason:OTHUDIdleTimerReasonMap];
    }
    [super viewWillDisappear:animated];
}

- (void)setCenter:(id<MKAnnotation>)annotation {
    if (!self.initialCenter) {
        [self OT_noteUserMapControlDuringInitialViewportWindow];
    }
    if (self.noMap > 0) {
        CLLocationCoordinate2D coordinate = annotation.coordinate;
        if (CLLocationCoordinate2DIsValid(coordinate)) {
            [self.mapView setVisibleMapRect:[self centeredRect:coordinate] animated:YES];
            self.mapView.userTrackingMode = MKUserTrackingModeNone;
        }
    }
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue.identifier isEqualToString:@"showWaypointFromMap"]) {
        if ([segue.destinationViewController respondsToSelector:@selector(setWaypoint:)]) {
            MKAnnotationView *view = (MKAnnotationView *)sender;
            if ([view.annotation isKindOfClass:[Friend class]]) {
                Friend *friend  = (Friend *)view.annotation;
                Waypoint *waypoint = friend.newestWaypoint;
                if (waypoint) {
                    [segue.destinationViewController performSelector:@selector(setWaypoint:) withObject:waypoint];
                }
            } else if ([view.annotation isKindOfClass:[Waypoint class]]) {
                Waypoint *waypoint  = (Waypoint *)view.annotation;
                [segue.destinationViewController performSelector:@selector(setWaypoint:) withObject:waypoint];
            }
        }
    } else if ([segue.identifier isEqualToString:@"showRegionFromMap"]) {
        if ([segue.destinationViewController respondsToSelector:@selector(setRegion:)]) {
            MKAnnotationView *view = (MKAnnotationView *)sender;
            if ([view.annotation isKindOfClass:[Region class]]) {
                Region *region  = (Region *)view.annotation;
                [segue.destinationViewController performSelector:@selector(setRegion:) withObject:region];
            }
        }
        if ([segue.destinationViewController respondsToSelector:@selector(setEditing:)]) {
            [segue.destinationViewController performSelector:@selector(setEditing:) withObject:@(FALSE)];
        }
    }
}

#pragma centeredRect

#define INITIAL_RADIUS 600.0

- (MKMapRect)centeredRect:(CLLocationCoordinate2D)center {
    MKMapRect rect;
    
    double r = INITIAL_RADIUS * MKMapPointsPerMeterAtLatitude(center.latitude);
    
    rect.origin = MKMapPointForCoordinate(center);
    rect.origin.x -= r;
    rect.origin.y -= r;
    rect.size.width = 2*r;
    rect.size.height = 2*r;
    
    return rect;
}

- (UIEdgeInsets)OT_initialLocalViewportEdgeInsets {
    return UIEdgeInsetsMake(104.0, 22.0, 36.0, 22.0);
}

- (void)OT_noteUserMapControlDuringInitialViewportWindow {
    if (self.initialCenter) {
        return;
    }
    self.skipInitialLocalMapViewport = YES;
    DDLogInfo(@"[ViewController] initial local viewport: suppressed (user map control before first GPS frame)");
}

- (void)OT_applyInitialLocalMapViewportForUserLocation:(CLLocation *)userLocation {
    (void)[self frcFriends];

    CLLocationCoordinate2D userCoord = userLocation.coordinate;
    MKMapRect rect = MKMapRectNull;
    rect = OTMapRectUnionCoordinate(rect, userCoord);

    NSUInteger localFriendCount = 0;
    for (Friend *f in self.frcFriends.fetchedObjects) {
        if (![f isKindOfClass:[Friend class]]) {
            continue;
        }
        CLLocationCoordinate2D fc = f.coordinate;
        if (!OTInitialViewportCoordinateUsable(fc)) {
            continue;
        }
        CLLocation *fl = [[CLLocation alloc] initWithLatitude:fc.latitude longitude:fc.longitude];
        if ([userLocation distanceFromLocation:fl] <= kOTInitialViewportLocalRadiusM) {
            localFriendCount++;
            rect = OTMapRectUnionCoordinate(rect, fc);
        }
    }

    NSUInteger remoteFallbackCount = 0;
    if (localFriendCount == 0) {
        NSMutableArray<Friend *> *candidates = [NSMutableArray array];
        for (Friend *f in self.frcFriends.fetchedObjects) {
            if (![f isKindOfClass:[Friend class]]) {
                continue;
            }
            CLLocationCoordinate2D fc = f.coordinate;
            if (!OTInitialViewportCoordinateUsable(fc)) {
                continue;
            }
            [candidates addObject:f];
        }
        [candidates sortUsingComparator:^NSComparisonResult(Friend *a, Friend *b) {
            CLLocationCoordinate2D ca = a.coordinate;
            CLLocationCoordinate2D cb = b.coordinate;
            CLLocation *la = [[CLLocation alloc] initWithLatitude:ca.latitude longitude:ca.longitude];
            CLLocation *lb = [[CLLocation alloc] initWithLatitude:cb.latitude longitude:cb.longitude];
            CLLocationDistance da = [userLocation distanceFromLocation:la];
            CLLocationDistance db = [userLocation distanceFromLocation:lb];
            if (da < db) {
                return NSOrderedAscending;
            }
            if (da > db) {
                return NSOrderedDescending;
            }
            return NSOrderedSame;
        }];
        NSUInteger n = MIN((NSUInteger)kOTInitialViewportNearestFriendFallback, (NSUInteger)candidates.count);
        for (NSUInteger i = 0; i < n; i++) {
            Friend *f = candidates[i];
            CLLocationCoordinate2D fc = f.coordinate;
            CLLocation *fl = [[CLLocation alloc] initWithLatitude:fc.latitude longitude:fc.longitude];
            CLLocationDistance d = [userLocation distanceFromLocation:fl];
            if (d > kOTInitialViewportFallbackRemoteCapM) {
                break;
            }
            rect = OTMapRectUnionCoordinate(rect, fc);
            remoteFallbackCount++;
        }
    }

    rect = OTMapRectExpandedToMinRadiusAroundCenter(rect, kOTInitialViewportMinRadiusM);
    if (MKMapRectIsNull(rect)) {
        rect = [self centeredRect:userCoord];
    }
    rect = OTMapRectOutsetFraction(rect, kOTInitialViewportMapRectOutsetFraction);

    UIEdgeInsets pad = [self OT_initialLocalViewportEdgeInsets];
    MKMapRect fit = [self.mapView mapRectThatFits:rect edgePadding:pad];
    self.applyingInitialLocalViewport = YES;
    @try {
        [self.mapView setVisibleMapRect:fit animated:YES];
    } @finally {
        self.applyingInitialLocalViewport = NO;
    }
    self.mapView.userTrackingMode = MKUserTrackingModeNone;

    DDLogInfo(@"[ViewController] initial local viewport: localFriends=%lu remoteFallback=%lu fitRect=(%.0f %.0f %.0f %.0f)",
              (unsigned long)localFriendCount,
              (unsigned long)remoteFallbackCount,
              fit.origin.x,
              fit.origin.y,
              fit.size.width,
              fit.size.height);
}

- (IBAction)mapModeChanged:(UISegmentedControl *)sender {
#if OSM
    if (self.osmOverlay) {
        [self.mapView removeOverlay:self.osmOverlay];
        self.osmOverlay = nil;
    }
    if (self.osmCopyright) {
        [self.osmCopyright removeFromSuperview];
        self.osmCopyright = nil;
    }
    for (UIView *view in self.mapView.subviews) {
        if ([NSStringFromClass(view.class) isEqualToString:@"MKAttributionLabel"]) {
            view.hidden = FALSE; // the standard attribution view
        }
    }
#endif
    switch (sender.selectedSegmentIndex) {
#if OSM
        case 6: {
            self.mapView.mapType = MKMapTypeStandard;
            
            NSString *osmTemplateString = [Settings stringForKey:@"osmtemplate_preference"
                                                           inMOC:CoreData.sharedInstance.mainMOC];
            if (!osmTemplateString || osmTemplateString.length == 0) {
                osmTemplateString = @"https://tile.openstreetmap.org/{z}/{x}/{y}.png";
            }
            
            NSString *osmCopyrightString = [Settings stringForKey:@"osmcopyright_preference"
                                                            inMOC:CoreData.sharedInstance.mainMOC];
            if (!osmCopyrightString || osmCopyrightString.length == 0) {
                osmCopyrightString = @"© OpenStreetMap contributors";
            }

            self.osmOverlay = [[MKTileOverlay alloc] initWithURLTemplate:osmTemplateString];
            self.osmOverlay.canReplaceMapContent = YES;
            self.osmRenderer = [[MKTileOverlayRenderer alloc] initWithTileOverlay:self.osmOverlay];

            [self.mapView insertOverlay:self.osmOverlay atIndex:0];
            for (UIView *view in self.mapView.subviews) {
                if ([NSStringFromClass(view.class) isEqualToString:@"MKAttributionLabel"]) {
                    view.hidden = TRUE; // the standard attribution view
                }
            }
            self.osmCopyright = [[UITextField alloc] init];
            self.osmCopyright.text = osmCopyrightString;
            self.osmCopyright.font = [UIFont systemFontOfSize:UIFont.smallSystemFontSize];
            self.osmCopyright.enabled = false;
            self.osmCopyright.translatesAutoresizingMaskIntoConstraints = false;
            [self.view addSubview:self.osmCopyright];
            
            NSLayoutConstraint *bottomCopyright = [NSLayoutConstraint
                                                   constraintWithItem:self.osmCopyright
                                                   attribute:NSLayoutAttributeBottom
                                                   relatedBy:NSLayoutRelationEqual
                                                   toItem:self.mapView
                                                   attribute:NSLayoutAttributeBottomMargin
                                                   multiplier:1
                                                   constant:0];
            NSLayoutConstraint *trailingCopyright = [NSLayoutConstraint
                                                     constraintWithItem:self.osmCopyright
                                                     attribute:NSLayoutAttributeTrailing
                                                     relatedBy:NSLayoutRelationEqual
                                                     toItem:self.mapView
                                                     attribute:NSLayoutAttributeTrailingMargin
                                                     multiplier:1
                                                     constant:0];
            
            [NSLayoutConstraint activateConstraints:@[bottomCopyright,
                                                      trailingCopyright]];
            

            break;
        }
#endif
        case 5:
            self.mapView.mapType = MKMapTypeMutedStandard;
            break;
        case 4:
            self.mapView.mapType = MKMapTypeHybridFlyover;
            break;
        case 3:
            self.mapView.mapType = MKMapTypeSatelliteFlyover;
            break;
        case 2:
            self.mapView.mapType = MKMapTypeHybrid;
            break;
        case 1:
            self.mapView.mapType = MKMapTypeSatellite;
            break;
        case 0:
        default:
            self.mapView.mapType = MKMapTypeStandard;
            break;
    }
    [self.mapView setNeedsLayout];
    [self.mapView setNeedsDisplay];

    [[NSUserDefaults standardUserDefaults] setInteger:sender.selectedSegmentIndex
                                               forKey:@"mapMode"];

}

#pragma MKMapViewDelegate

#define REUSE_ID_BEACON @"Annotation_beacon"
#define REUSE_ID_PICTURE @"Annotation_picture"
#define REUSE_ID_POI @"Annotation_poi"
#define REUSE_ID_IMAGE @"Annotation_image"
#define REUSE_ID_OTHER @"Annotation_other"

// This is a hack because the FriendAnnotationView did not erase it's callout after being dragged
- (void)mapView:(MKMapView *)mapView
 annotationView:(MKAnnotationView *)view
didChangeDragState:(MKAnnotationViewDragState)newState
   fromOldState:(MKAnnotationViewDragState)oldState {
    DDLogVerbose(@"didChangeDragState %lu", (unsigned long)newState);
    if (newState == MKAnnotationViewDragStateNone) {
        NSArray *annotations = mapView.annotations;
        [mapView removeAnnotations:annotations];
        [mapView addAnnotations:annotations];
    }
}

- (void)mapView:(MKMapView *)mapView didUpdateUserLocation:(MKUserLocation *)userLocation {
    if (self.initialCenter) {
        return;
    }
    CLLocation *loc = userLocation.location;
    if (!loc || !OTInitialViewportCoordinateUsable(loc.coordinate)) {
        return;
    }
    if (self.skipInitialLocalMapViewport
        || mapView.userTrackingMode != MKUserTrackingModeNone
        || self.selectedFriend != nil
        || self.followFriend != nil)
    {
        self.initialCenter = TRUE;
        DDLogInfo(@"[ViewController] initial local viewport: skipped (user control / follow / tracking); skip=%d mode=%ld",
                  self.skipInitialLocalMapViewport,
                  (long)mapView.userTrackingMode);
        return;
    }
    if (self.noMap <= 0) {
        [self.mapView setCenterCoordinate:loc.coordinate animated:YES];
        self.initialCenter = TRUE;
        return;
    }
    [self OT_applyInitialLocalMapViewportForUserLocation:loc];
    self.initialCenter = TRUE;
}

- (MKAnnotationView *)mapView:(MKMapView *)mapView
            viewForAnnotation:(id<MKAnnotation>)annotation {
    if ([annotation isKindOfClass:[MKUserLocation class]]) {
        return nil;
    } else if ([annotation isKindOfClass:[Friend class]]) {
        Friend *friend = (Friend *)annotation;
        Waypoint *waypoint = friend.newestWaypoint;

        MKAnnotationView *annotationView = [mapView dequeueReusableAnnotationViewWithIdentifier:REUSE_ID_PICTURE];
        FriendAnnotationV *friendAnnotationV;
        if (annotationView) {
            friendAnnotationV = (FriendAnnotationV *)annotationView;
            friendAnnotationV.annotation = friend;
        } else {
            friendAnnotationV = [[FriendAnnotationV alloc] initWithAnnotation:friend reuseIdentifier:REUSE_ID_PICTURE];
        }
        friendAnnotationV.displayPriority = MKFeatureDisplayPriorityRequired;
        friendAnnotationV.zPriority = MKFeatureDisplayPriorityDefaultHigh;
        friendAnnotationV.canShowCallout = NO;
        friendAnnotationV.rightCalloutAccessoryView = nil;
        friendAnnotationV.accessibilityLabel = friend.nameOrTopic;

        for (UIGestureRecognizer *gr in [friendAnnotationV.gestureRecognizers copy]) {
            if ([gr.name isEqualToString:kOTFriendPinTapGRName]) {
                [friendAnnotationV removeGestureRecognizer:gr];
            }
        }
        UITapGestureRecognizer *pinTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                                  action:@selector(OT_friendPinTapWhileSelected:)];
        pinTap.name = kOTFriendPinTapGRName;
        pinTap.delegate = self;
        [friendAnnotationV addGestureRecognizer:pinTap];

        NSData *data = friend.image;
        UIImage *image = [UIImage imageWithData:data];
        friendAnnotationV.personImage = image;
        friendAnnotationV.tid = friend.effectiveTid;
        friendAnnotationV.speed = (waypoint.vel).doubleValue;
        friendAnnotationV.course = (waypoint.cog).doubleValue;
        friendAnnotationV.me = [friend.topic isEqualToString:[Settings theGeneralTopicInMOC:CoreData.sharedInstance.mainMOC]];
        [friendAnnotationV setNeedsDisplay];

        return friendAnnotationV;

    } else if ([annotation isKindOfClass:[Waypoint class]]) {
        Waypoint *waypoint = (Waypoint *)annotation;
        MKAnnotationView *annotationView;
        if (waypoint.image) {
            annotationView = [mapView dequeueReusableAnnotationViewWithIdentifier:REUSE_ID_IMAGE];
            PhotoAnnotationV *pAV;
            if (!annotationView) {
                pAV = [[PhotoAnnotationV alloc] initWithAnnotation:waypoint reuseIdentifier:REUSE_ID_IMAGE];
            } else {
                pAV = (PhotoAnnotationV *)annotationView;
                pAV.annotation = waypoint;
            }
            pAV.displayPriority = MKFeatureDisplayPriorityRequired;
            pAV.poiImage = [UIImage imageWithData:waypoint.image];
            pAV.canShowCallout = YES;
            pAV.rightCalloutAccessoryView = [UIButton buttonWithType:UIButtonTypeDetailDisclosure];
            annotationView = pAV;
        } else {
            annotationView = [mapView dequeueReusableAnnotationViewWithIdentifier:REUSE_ID_POI];
            MKMarkerAnnotationView *mAV;
            if (!annotationView) {
                mAV = [[MKMarkerAnnotationView alloc] initWithAnnotation:waypoint reuseIdentifier:REUSE_ID_POI];
            } else {
                mAV = (MKMarkerAnnotationView *)annotationView;
                mAV.annotation = waypoint;
            }
            mAV.displayPriority = MKFeatureDisplayPriorityRequired;
            mAV.canShowCallout = YES;
            mAV.rightCalloutAccessoryView = [UIButton buttonWithType:UIButtonTypeDetailDisclosure];
            annotationView = mAV;
        }
        [annotationView setNeedsDisplay];
        return annotationView;
    } else if ([annotation isKindOfClass:[Region class]]) {
        Region *region = (Region *)annotation;
        if ([region.CLregion isKindOfClass:[CLBeaconRegion class]]) {
            MKAnnotationView *annotationView = [mapView dequeueReusableAnnotationViewWithIdentifier:REUSE_ID_BEACON];
            MKMarkerAnnotationView *mAV;
            if (!annotationView) {
                mAV = [[MKMarkerAnnotationView alloc] initWithAnnotation:region reuseIdentifier:REUSE_ID_BEACON];
            } else {
                mAV = (MKMarkerAnnotationView *)annotationView;
                mAV.annotation = region;
            }
            mAV.displayPriority = MKFeatureDisplayPriorityRequired;
            if ([[LocationManager sharedInstance] insideBeaconRegion:region.name]) {
                mAV.markerTintColor = [UIColor colorNamed:@"beaconHotColor"];
                mAV.glyphImage = [UIImage imageNamed:@"iBeaconHot"];
            } else {
                mAV.markerTintColor = [UIColor colorNamed:@"beaconColdColor"];
                mAV.glyphImage = [UIImage imageNamed:@"iBeaconCold"];
            }
            annotationView = mAV;
            annotationView.draggable = true;
            annotationView.canShowCallout = YES;
            annotationView.rightCalloutAccessoryView = [UIButton buttonWithType:UIButtonTypeDetailDisclosure];

            [annotationView setNeedsDisplay];
            return annotationView;
        } else {
            if (region.CLregion.isFollow) {
                return nil;
            }
            MKAnnotationView *annotationView = [mapView dequeueReusableAnnotationViewWithIdentifier:REUSE_ID_OTHER];
            MKMarkerAnnotationView *mAV;
            if (!annotationView) {
                mAV = [[MKMarkerAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:REUSE_ID_OTHER];
            } else {
                mAV = (MKMarkerAnnotationView *)annotationView;
                mAV.annotation = annotation;
            }
            mAV.displayPriority = MKFeatureDisplayPriorityRequired;
            mAV.markerTintColor = [UIColor colorNamed:@"pinColor"];
            annotationView = mAV;
            annotationView.draggable = true;
            annotationView.canShowCallout = YES;
            annotationView.rightCalloutAccessoryView = [UIButton buttonWithType:UIButtonTypeDetailDisclosure];
            [annotationView setNeedsDisplay];
            return annotationView;
        }
    }
    return nil;
}

- (MKOverlayRenderer *)mapView:(MKMapView *)mapView rendererForOverlay:(id<MKOverlay>)overlay {
    if ([overlay isKindOfClass:[MKPolyline class]]) {
        MKPolylineRenderer *renderer = [[MKPolylineRenderer alloc] initWithPolyline:(MKPolyline *)overlay];
        renderer.lineWidth = 3;
        renderer.strokeColor = [UIColor colorNamed:@"trackColor"];
        return renderer;
    } else if ([overlay isKindOfClass:[Friend class]]) {
        Friend *friend = (Friend *)overlay;
        MKPolylineRenderer *renderer = [[MKPolylineRenderer alloc] initWithPolyline:friend.polyLine];
        renderer.lineWidth = 3;
        renderer.strokeColor = [UIColor colorNamed:@"trackColor"];
        return renderer;
        
    } else if ([overlay isKindOfClass:[Region class]]) {
        Region *region = (Region *)overlay;
        if (region.CLregion && [region.CLregion isKindOfClass:[CLCircularRegion class]]) {
            MKCircleRenderer *renderer = [[MKCircleRenderer alloc] initWithCircle:region.circle];
            if (region.CLregion.isFollow) {
                renderer.fillColor = [UIColor colorNamed:@"followColor"];
            } else {
                if ([[LocationManager sharedInstance] insideCircularRegion:region.name]) {
                    renderer.fillColor = [UIColor colorNamed:@"insideColor"];
                } else {
                    renderer.fillColor = [UIColor colorNamed:@"outsideColor"];
                }
            }
            return renderer;
        } else {
            return nil;
        }
        
    } else if ([overlay isKindOfClass:[MKCircle class]]) {
        MKCircleRenderer *renderer = [[MKCircleRenderer alloc] initWithCircle:(MKCircle *)overlay];
        renderer.fillColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.15];
        renderer.strokeColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.9];
        renderer.lineWidth = 2.0;
        return renderer;

    } else if ([overlay isKindOfClass:[MKTileOverlay class]]) {
        return self.osmRenderer;

    } else {
        return nil;
    }
}

- (void)showLocationZoneWithName:(NSString *)name
                      coordinate:(CLLocationCoordinate2D)coordinate
                          radius:(CLLocationDistance)radius {
    if (!CLLocationCoordinate2DIsValid(coordinate)) {
        return;
    }
    if (!self.initialCenter) {
        [self OT_noteUserMapControlDuringInitialViewportWindow];
    }
    CLLocationDistance effectiveRadius = radius > 0.0 ? radius : 35.0;

    if (self.selectedLocationZoneOverlay) {
        [self.mapView removeOverlay:self.selectedLocationZoneOverlay];
        self.selectedLocationZoneOverlay = nil;
    }
    if (self.selectedLocationZoneAnnotation) {
        [self.mapView removeAnnotation:self.selectedLocationZoneAnnotation];
        self.selectedLocationZoneAnnotation = nil;
    }

    MKPointAnnotation *annotation = [[MKPointAnnotation alloc] init];
    annotation.coordinate = coordinate;
    annotation.title = name.length > 0 ? name : @"Location";
    annotation.subtitle = [NSString stringWithFormat:@"Radius %.0fm", effectiveRadius];
    [self.mapView addAnnotation:annotation];
    self.selectedLocationZoneAnnotation = annotation;

    MKCircle *zoneCircle = [MKCircle circleWithCenterCoordinate:coordinate radius:effectiveRadius];
    [self.mapView addOverlay:zoneCircle];
    self.selectedLocationZoneOverlay = zoneCircle;

    CLLocationDistance distance = MAX(effectiveRadius * 4.0, 250.0);
    MKMapCamera *camera = [MKMapCamera cameraLookingAtCenterCoordinate:coordinate
                                                          fromDistance:distance
                                                                 pitch:0
                                                               heading:0];
    [self.mapView setCamera:camera animated:YES];
    [self.mapView selectAnnotation:annotation animated:YES];
}

- (void)mapView:(MKMapView *)mapView
 annotationView:(MKAnnotationView *)view
calloutAccessoryControlTapped:(UIControl *)control {
    if (control == view.rightCalloutAccessoryView) {
        if ([view.annotation isKindOfClass:[Region class]]) {
            [self performSegueWithIdentifier:@"showRegionFromMap" sender:view];
        } else if ([view.annotation isKindOfClass:[Waypoint class]]) {
            Waypoint *wp = (Waypoint *)view.annotation;
            DeviceDetailHostingController *vc =
                [[DeviceDetailHostingController alloc] initWithWaypoint:wp];
            [self.navigationController pushViewController:vc animated:YES];
        }
    }
}

- (void)OT_pushDeviceDetailForFriendIfPossible:(Friend *)friend {
    Waypoint *wp = friend.newestWaypoint;
    if (!wp || !self.navigationController) {
        return;
    }
    DeviceDetailHostingController *vc = [[DeviceDetailHostingController alloc] initWithWaypoint:wp];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)OT_friendPinTapWhileSelected:(UITapGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateEnded) {
        return;
    }
    if (![gr.view isKindOfClass:[FriendAnnotationV class]]) {
        return;
    }
    FriendAnnotationV *fv = (FriendAnnotationV *)gr.view;
    if (!fv.selected || ![fv.annotation isKindOfClass:[Friend class]]) {
        return;
    }
    [self OT_pushDeviceDetailForFriendIfPossible:(Friend *)fv.annotation];
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    UIView *v = gestureRecognizer.view;
    if (![v isKindOfClass:[FriendAnnotationV class]]) {
        return YES;
    }
    FriendAnnotationV *fv = (FriendAnnotationV *)v;
    return fv.selected && [fv.annotation isKindOfClass:[Friend class]];
}

- (void)mapView:(MKMapView *)mapView didSelectAnnotationView:(MKAnnotationView *)view {
    if ([view.annotation isKindOfClass:[Friend class]]) {
        if (!self.initialCenter) {
            [self OT_noteUserMapControlDuringInitialViewportWindow];
        }
        Friend *friend = (Friend *)view.annotation;
        DDLogInfo(@"[Follow] didSelectAnnotationView: topic=%@ coord=(%g,%g)",
                  friend.topic, friend.coordinate.latitude, friend.coordinate.longitude);
        self.followHeadingLockPausedByUserGesture = NO;
        self.followTemporarilySuspendedByGesture = NO;
        [self applyFollowSelectionForMapFriend:friend mapView:mapView];
    }
}

- (void)mapView:(MKMapView *)mapView regionWillChangeAnimated:(BOOL)animated {
    // Pan/zoom must NOT clear the selected friend or their route — selection is tied to the
    // annotation (see didDeselectAnnotationView). Pause follow while any user gesture is active.
    UIView *mapContentView = mapView.subviews.firstObject;
    if (!mapContentView) {
        return;
    }
    BOOL anyActiveGesture = NO;
    for (UIGestureRecognizer *gr in mapContentView.gestureRecognizers) {
        if (OTGestureIsActive(gr)) {
            anyActiveGesture = YES;
            break;
        }
    }
    if (anyActiveGesture && !self.initialCenter && !self.applyingInitialLocalViewport) {
        [self OT_noteUserMapControlDuringInitialViewportWindow];
    }
    if (!anyActiveGesture) {
        return;
    }
    if (self.followEnabled && self.followFriend) {
        DDLogInfo(@"[Follow] user gesture — suspend follow recenter; keep selection + route (heading unchanged for pinch/tilt)");
        [self stopFollowLink];
        self.followTemporarilySuspendedByGesture = YES;
    }
}

- (void)mapView:(MKMapView *)mapView regionDidChangeAnimated:(BOOL)animated {
    if (!self.followTemporarilySuspendedByGesture || !self.followEnabled || !self.followFriend) {
        return;
    }
    MKMapCamera *camSnapshot = [mapView.camera copy];
    OTPersistFollowUserCameraPitchAndDistance(camSnapshot.pitch, camSnapshot.centerCoordinateDistance);
    self.followTemporarilySuspendedByGesture = NO;
    CLLocationCoordinate2D coord = self.followFriend.coordinate;
    if (!CLLocationCoordinate2DIsValid(coord)) {
        return;
    }
    [self applyFollow3DCameraToCoordinate:coord
                                  heading:NAN
                       preserveUserAltitude:YES];
    DDLogInfo(@"[Follow] gesture ended — persisted follow zoom/pitch; resumed follow");
    [self startFollowLink];
}

- (void)mapView:(MKMapView *)mapView didDeselectAnnotationView:(MKAnnotationView *)view {
    if ([view.annotation isKindOfClass:[Friend class]]) {
        Friend *friend = (Friend *)view.annotation;
        NSString *topic = friend.topic;
        DDLogInfo(@"[Follow] didDeselectAnnotationView: topic=%@, stopping follow", friend.topic);
        [self hideInstrumentationHUD];
        if (topic.length) {
            [self clearFollowInstrumentHistoryForTopic:topic];
        }
        [self stopFollowLink];
        self.followHeadingTargetNumber = nil;
        self.selectedFriend = nil;
        self.followFriend = nil;
        self.followEnabled = YES;
        [self updateFollowToggleAppearance];
        [self updateFollowToggleVisibility];
        self.followHeadingLockPausedByUserGesture = NO;
        [self.followMapPrevCoordByTopic removeAllObjects];
        MKMapCamera *northCam = [self.mapView.camera copy];
        northCam.heading = 0.0;
        northCam.pitch = 0.0;
        [self.mapView setCamera:northCam animated:YES];
        [mapView removeOverlay:friend];
        // Hide the live track while deselected; keep liveTrackPoints cached for instant re-show.
        MKPolyline *liveTrack = topic.length ? self.liveTrackPolylines[topic] : nil;
        if (liveTrack) {
            [mapView removeOverlay:liveTrack];
            [self.liveTrackPolylines removeObjectForKey:topic];
        }
        if (topic.length) {
            [self.pendingRouteTopics removeObject:topic];
            [self.routeFetchMQTTBaselineByTopic removeObjectForKey:topic];
            [self.routeLastFetchDebugByTopic removeObjectForKey:topic];
        }
        [self removeFriendLiveTrackOverlaysExceptTopic:nil];
        [self removeFriendBreadcrumbOverlaysExceptFriend:nil];
        DDLogInfo(@"[RouteDebug] didDeselectAnnotationView done topic=%@", friend.topic);
        [self updateRouteHistoryToggleVisibility];
    }
}

#pragma mark - Smooth follow

/// MapKit only reliably selects the exact `Friend` instance that was `addAnnotation:`'d. The Friends
/// list may hand us another `Friend` fault for the same topic; `selectAnnotation:` is a no-op then,
/// which used to leave follow/route state wrong until the user tapped the pin on the map.
- (Friend *)friendAnnotationOnMapForTopic:(NSString *)topic {
    if (!topic.length) {
        return nil;
    }
    for (id<MKAnnotation> ann in self.mapView.annotations) {
        if ([ann isKindOfClass:[Friend class]]) {
            Friend *f = (Friend *)ann;
            if ([f.topic isEqualToString:topic]) {
                return f;
            }
        }
    }
    return nil;
}

- (void)applyFollowSelectionForMapFriend:(Friend *)friend mapView:(MKMapView *)mapView {
    self.selectedFriend = friend;
    self.followEnabled = YES;
    self.followFriend = friend;
    [self updateFollowToggleAppearance];
    [self updateFollowToggleVisibility];
    self.followHeadingLockPausedByUserGesture = NO;
    if (friend.topic.length) {
        [self.followMapPrevCoordByTopic removeObjectForKey:friend.topic];
    }
    [self removeFriendLiveTrackOverlaysExceptTopic:friend.topic];
    [self syncFollowedFriendBreadcrumbOverlay:friend];
    if (self.noMap > 0) {
        self.mapView.userTrackingMode = MKUserTrackingModeNone;
    }
    Waypoint *wpHeading = friend.newestWaypoint;
    double initialHeading = NAN;
    if (wpHeading.cog && OTHeadingDegreesValid(wpHeading.cog.doubleValue)) {
        initialHeading = OTNormalizeHeadingDegrees(wpHeading.cog.doubleValue);
    }
    if (self.followEnabled) {
        if (initialHeading == initialHeading) {
            self.followHeadingTargetNumber = @(initialHeading);
        } else {
            self.followHeadingTargetNumber = nil;
        }
        [self applyFollow3DCameraToCoordinate:friend.coordinate
                                      heading:initialHeading
                           preserveUserAltitude:NO];
        [self startFollowLink];
    }
    if ([self.routeFetchedTopics containsObject:friend.topic]
            && self.liveTrackPoints[friend.topic].count >= 2) {
        [self rebuildLiveTrackForTopic:friend.topic];
    } else {
        [self fetchRouteForFriend:friend mapView:mapView];
    }
    [self updateRouteHistoryToggleVisibility];
    if (self.followEnabled) {
        [self showInstrumentationHUDForFriend:friend];
    } else {
        [self hideInstrumentationHUD];
    }
}

- (void)resetFollowCameraSmootherState {
    self.followCameraLastTickTime = 0;
    self.followCameraLastApplyTime = 0;
    self.followCameraTargetCenterCoord = kCLLocationCoordinate2DInvalid;
    self.followCameraRenderCenterCoord = kCLLocationCoordinate2DInvalid;
    self.followCameraRenderHeadingDeg = 0.0;
    self.followCameraHasSmootherState = NO;
}

- (void)followFriendFromList:(Friend *)friend {
    if (!friend.topic.length) {
        DDLogWarn(@"[Follow] followFriendFromList: missing topic");
        return;
    }
    if (!self.initialCenter) {
        [self OT_noteUserMapControlDuringInitialViewportWindow];
    }
    Friend *mapFriend = [self friendAnnotationOnMapForTopic:friend.topic] ?: friend;
    DDLogInfo(@"[Follow] followFriendFromList: topic=%@ mapFriend==argFriend %d",
              friend.topic, (mapFriend == friend));
    // Drive selection through MapKit so tapping empty map deselects the pin and clears the route
    // (didSelectAnnotationView / didDeselectAnnotationView). Avoid manual deselect loop — it fires
    // didDeselect and would clear state before the new friend is selected.
    id<MKAnnotation> current = self.mapView.selectedAnnotations.firstObject;
    NSString *currentTopic = nil;
    if ([current isKindOfClass:[Friend class]]) {
        currentTopic = ((Friend *)current).topic;
    }
    BOOL alreadyThisTopic = [currentTopic isEqualToString:friend.topic];

    if (!alreadyThisTopic) {
        [self.mapView selectAnnotation:mapFriend animated:YES];
        id<MKAnnotation> sel = self.mapView.selectedAnnotations.firstObject;
        NSString *selTopic = nil;
        if ([sel isKindOfClass:[Friend class]]) {
            selTopic = ((Friend *)sel).topic;
        }
        if (![selTopic isEqualToString:friend.topic]) {
            DDLogInfo(@"[Follow] followFriendFromList: selectAnnotation did not select topic %@ — applying follow directly",
                      friend.topic);
            [self applyFollowSelectionForMapFriend:mapFriend mapView:self.mapView];
        }
        return;
    }
    // Same topic already selected on the map — refresh route UI without relying on didSelect re-entry.
    [self applyFollowSelectionForMapFriend:mapFriend mapView:self.mapView];
}

- (void)startFollowLink {
    [self stopFollowLink];
    if (!self.followEnabled || !self.followFriend) {
        return;
    }
    DDLogInfo(@"[Follow] startFollowLink for topic=%@", self.followFriend.topic);
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self
                                                      selector:@selector(followTick:)];
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    self.followLink = link;
}

- (void)stopFollowLink {
    if (self.followLink) {
        DDLogInfo(@"[Follow] stopFollowLink");
    }
    [self.followLink invalidate];
    self.followLink = nil;
    [self resetFollowCameraSmootherState];
}

- (void)followTick:(CADisplayLink *)link {
    Friend *f = self.followEnabled ? self.followFriend : nil;
    if (!f) {
        [self stopFollowLink];
        return;
    }
    if (self.followTemporarilySuspendedByGesture) {
        return;
    }
    CLLocationCoordinate2D coord = f.coordinate;
    if (!CLLocationCoordinate2DIsValid(coord)) {
        return;
    }

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    CFTimeInterval dt = (self.followCameraLastTickTime > 0) ? (now - self.followCameraLastTickTime) : 0.0;
    self.followCameraLastTickTime = now;
    dt = OTClampDouble(dt, 1.0 / 120.0, 0.5);

    const CFTimeInterval kCameraApplyMinInterval = 0.12;
    const CLLocationDistance kCenterApplyMinDriftM = 2.0;
    const double kHeadingApplyMinDeltaDeg = 2.0;
    const double kCenterSmoothingTauSec = 0.30;
    const double kHeadingSmoothingTauSec = 0.22;
    const double kHeadingMaxStepDegPerSec = 120.0;

    MKMapCamera *currentCam = self.mapView.camera;
    if (!self.followCameraHasSmootherState) {
        CLLocationCoordinate2D center = currentCam.centerCoordinate;
        if (!CLLocationCoordinate2DIsValid(center)) {
            center = coord;
        }
        self.followCameraRenderCenterCoord = center;
        self.followCameraTargetCenterCoord = coord;
        self.followCameraRenderHeadingDeg = OTNormalizeHeadingDegrees(currentCam.heading);
        self.followCameraHasSmootherState = YES;
    } else {
        self.followCameraTargetCenterCoord = coord;
    }

    double targetHeadingDeg = self.followCameraRenderHeadingDeg;
    if (self.followHeadingLockPausedByUserGesture) {
        targetHeadingDeg = 0.0;
    } else if (self.followHeadingTargetNumber && isfinite(self.followHeadingTargetNumber.doubleValue)) {
        targetHeadingDeg = OTNormalizeHeadingDegrees(self.followHeadingTargetNumber.doubleValue);
    }

    double centerAlpha = 1.0 - exp(-dt / kCenterSmoothingTauSec);
    double headingAlpha = 1.0 - exp(-dt / kHeadingSmoothingTauSec);
    centerAlpha = OTClampDouble(centerAlpha, 0.0, 1.0);
    headingAlpha = OTClampDouble(headingAlpha, 0.0, 1.0);

    double latDelta = self.followCameraTargetCenterCoord.latitude - self.followCameraRenderCenterCoord.latitude;
    double lonDelta = self.followCameraTargetCenterCoord.longitude - self.followCameraRenderCenterCoord.longitude;
    self.followCameraRenderCenterCoord = CLLocationCoordinate2DMake(
        self.followCameraRenderCenterCoord.latitude + latDelta * centerAlpha,
        self.followCameraRenderCenterCoord.longitude + lonDelta * centerAlpha);

    double headingDelta = OTSignedHeadingDeltaDegrees(self.followCameraRenderHeadingDeg, targetHeadingDeg);
    double desiredHeadingStep = headingDelta * headingAlpha;
    double maxHeadingStep = kHeadingMaxStepDegPerSec * dt;
    desiredHeadingStep = OTClampDouble(desiredHeadingStep, -maxHeadingStep, maxHeadingStep);
    self.followCameraRenderHeadingDeg =
        OTNormalizeHeadingDegrees(self.followCameraRenderHeadingDeg + desiredHeadingStep);

    if ((now - self.followCameraLastApplyTime) < kCameraApplyMinInterval) {
        return;
    }

    CLLocationCoordinate2D camCenter = currentCam.centerCoordinate;
    CLLocationDistance centerDrift = 0.0;
    if (CLLocationCoordinate2DIsValid(camCenter) && CLLocationCoordinate2DIsValid(self.followCameraRenderCenterCoord)) {
        CLLocation *from = [[CLLocation alloc] initWithLatitude:camCenter.latitude longitude:camCenter.longitude];
        CLLocation *to = [[CLLocation alloc] initWithLatitude:self.followCameraRenderCenterCoord.latitude
                                                    longitude:self.followCameraRenderCenterCoord.longitude];
        centerDrift = [from distanceFromLocation:to];
    }
    double headingDrift = fabs(OTSignedHeadingDeltaDegrees(currentCam.heading, self.followCameraRenderHeadingDeg));
    if (centerDrift < kCenterApplyMinDriftM && headingDrift < kHeadingApplyMinDeltaDeg) {
        return;
    }

    self.followCameraLastApplyTime = now;
    MKMapCamera *cam = [currentCam copy];
    cam.centerCoordinate = self.followCameraRenderCenterCoord;
    cam.pitch = OTFollowUserPitch();
    double d = cam.centerCoordinateDistance;
    if (!isfinite(d) || d <= 0.0) {
        cam.centerCoordinateDistance = OTFollowUserDistance();
    }
    cam.heading = OTNormalizeHeadingDegrees(self.followCameraRenderHeadingDeg);
    [self.mapView setCamera:cam animated:NO];

    static NSUInteger sFollowTickCount = 0;
    if (++sFollowTickCount % 60 == 0) {
        DDLogInfo(@"[Follow] tick#%lu friend=(%g,%g) centerDrift=%.2fm headingDrift=%.2fdeg",
                  (unsigned long)sFollowTickCount,
                  coord.latitude, coord.longitude,
                  centerDrift, headingDrift);
    }
}

/// `historyHoursOverride`: pass 6 or 12 to force that window (e.g. toggle); pass -1 to use `NSUserDefaults` via `routeHistoryHours`.
- (void)fetchRouteForFriend:(Friend *)friend mapView:(MKMapView *)mapView {
    [self fetchRouteForFriend:friend mapView:mapView historyHours:-1];
}

- (void)fetchRouteForFriend:(Friend *)friend mapView:(MKMapView *)mapView historyHours:(NSInteger)historyHoursOverride {
    NSString *topic = friend.topic;
    if ([[LocationAPISyncService sharedInstance] hasAuthorizationUserProfilePayload] &&
        ![[LocationAPISyncService sharedInstance] currentUserMayViewRouteHistory]) {
        DDLogInfo(@"[ViewController] route fetch: skipped (canViewRouteHistory is false for signed-in user profile)");
        [self rebuildLiveTrackForTopic:topic];
        return;
    }

    NSString *routeUser = friend.routeAPIUser;
    NSString *routeDevice = friend.tid;

    DDLogInfo(@"[ViewController] route fetch: tapped topic=%@ routeAPIUser=%@ tid=%@ historyHoursOverride=%ld defaultsHours=%ld",
              topic, routeUser ?: @"(nil)", routeDevice ?: @"(nil)",
              (long)historyHoursOverride, (long)[self routeHistoryHours]);

    // If the REST API poll hasn't run yet, derive user/device directly from the
    // MQTT topic (format: owntracks/{user}/{device}).
    if (!routeUser.length || !routeDevice.length) {
        NSArray<NSString *> *parts = [topic componentsSeparatedByString:@"/"];
        if (parts.count >= 3) {
            routeUser = parts[1];
            // Join remaining components in case device contains a slash
            routeDevice = [[parts subarrayWithRange:NSMakeRange(2, parts.count - 2)]
                           componentsJoinedByString:@"/"];
            DDLogInfo(@"[ViewController] route fetch: derived from topic — user=%@ device=%@", routeUser, routeDevice);
        }
    }

    if (!routeUser.length || !routeDevice.length) {
        // Cannot determine user/device — show any cached live track and bail.
        DDLogInfo(@"[ViewController] route fetch: cannot determine user/device for %@, showing cached track", topic);
        [self rebuildLiveTrackForTopic:topic];
        return;
    }

    if ([self.pendingRouteTopics containsObject:topic]) {
        return;
    }
    [self.pendingRouteTopics addObject:topic];
    [self updateRouteHistoryToggleVisibility];

    NSManagedObjectContext *mainMOC = CoreData.sharedInstance.mainMOC;

    NSInteger endTs = (NSInteger)[[NSDate date] timeIntervalSince1970];
    NSInteger hours = (historyHoursOverride == 6 || historyHoursOverride == 12)
        ? historyHoursOverride
        : [self routeHistoryHours];
    NSInteger startTs = endTs - hours * 60 * 60;

    DDLogInfo(@"[ViewController] route fetch: windowHours=%ld spanSec=%ld start=%ld end=%ld",
              (long)hours, (long)(endTs - startTs), (long)startTs, (long)endTs);

    NSUInteger mqttBaseline = [self.liveTrackPoints[topic] count];
    self.routeFetchMQTTBaselineByTopic[topic] = @(mqttBaseline);
    DDLogInfo(@"[ViewController] route fetch: MQTT baseline count=%lu for topic=%@ (only points added after this merge with API)",
              (unsigned long)mqttBaseline, topic);

    __weak typeof(self) wself = self;
    [[LocationAPISyncService sharedInstance] fetchRouteHistoryPointsForRouteUser:routeUser
                                                                     routeDevice:routeDevice
                                                                      startUnix:startTs
                                                                        endUnix:endTs
                                                           managedObjectContext:mainMOC
                                                                     completion:^(NSArray<NSDictionary *> * _Nullable points,
                                                                                  NSError * _Nullable error) {
            __strong typeof(wself) sself = wself;
            if (!sself) return;

            if (![sself.pendingRouteTopics containsObject:topic]) {
                // Friend was deselected while the request was in flight — discard.
                [sself.routeFetchMQTTBaselineByTopic removeObjectForKey:topic];
                [sself updateRouteHistoryToggleVisibility];
                return;
            }
            [sself.pendingRouteTopics removeObject:topic];

            DDLogInfo(@"[ViewController] route fetch: response for %@ — points=%lu error=%@",
                      topic, (unsigned long)points.count, error.localizedDescription ?: @"none");

            if (error || points.count == 0) {
                DDLogInfo(@"[ViewController] route fetch failed or empty for %@: %@, showing cached track", topic, error.localizedDescription);
                [sself.routeFetchMQTTBaselineByTopic removeObjectForKey:topic];
                [sself rebuildLiveTrackForTopic:topic];
                return;
            }

            NSMutableArray<NSValue *> *historical = [NSMutableArray array];
            NSMutableArray *apiUnix = [NSMutableArray array];
            BOOL haveAnyTs = NO;
            NSTimeInterval apiMinTs = 0;
            NSTimeInterval apiMaxTs = 0;
            NSUInteger pointsWithTst = 0;
            NSUInteger tsOutsideLow = 0;
            NSUInteger tsOutsideHigh = 0;
            for (NSDictionary *d in points) {
                if (![d isKindOfClass:[NSDictionary class]]) {
                    continue;
                }
                id latObj = d[@"latitude"] ?: d[@"lat"];
                id lonObj = d[@"longitude"] ?: d[@"lon"];
                if (![latObj isKindOfClass:[NSNumber class]] || ![lonObj isKindOfClass:[NSNumber class]]) {
                    continue;
                }
                double lat = [(NSNumber *)latObj doubleValue];
                double lon = [(NSNumber *)lonObj doubleValue];
                if (lat == 0.0 && lon == 0.0) {
                    continue;
                }
                NSTimeInterval unix = OTRouteHistoryPointUnixTime(d);
                if (!isnan(unix)) {
                    pointsWithTst++;
                    if (!haveAnyTs) {
                        haveAnyTs = YES;
                        apiMinTs = apiMaxTs = unix;
                    } else {
                        apiMinTs = MIN(apiMinTs, unix);
                        apiMaxTs = MAX(apiMaxTs, unix);
                    }
                    if (unix < (NSTimeInterval)startTs) {
                        tsOutsideLow++;
                    }
                    if (unix > (NSTimeInterval)endTs) {
                        tsOutsideHigh++;
                    }
                }
                [historical addObject:[NSValue valueWithMKCoordinate:CLLocationCoordinate2DMake(lat, lon)]];
                [apiUnix addObject:(!isnan(unix) ? @(unix) : [NSNull null])];
            }

            if (historical.count == 0) {
                DDLogInfo(@"[ViewController] route fetch: no valid coords for %@, showing cached track", topic);
                [sself.routeFetchMQTTBaselineByTopic removeObjectForKey:topic];
                [sself rebuildLiveTrackForTopic:topic];
                return;
            }

            NSUInteger count = historical.count;

            // API points define the requested time window. Only append MQTT fixes that arrived *after* this GET
            // started (see mqttBaseline above) — older session points have no timestamps here and would extend
            // the polyline outside [start,end] and confuse the 6h/12h window.
            NSMutableArray<NSValue *> *existing = sself.liveTrackPoints[topic] ?: [NSMutableArray array];
            NSMutableArray *existingUnix = sself.liveTrackPointUnixByTopic[topic] ?: [NSMutableArray array];
            NSNumber *baselineObj = sself.routeFetchMQTTBaselineByTopic[topic];
            NSUInteger baseline = baselineObj ? baselineObj.unsignedIntegerValue : existing.count;
            [sself.routeFetchMQTTBaselineByTopic removeObjectForKey:topic];

            NSMutableArray *mergedUnix = [apiUnix mutableCopy];
            NSMutableArray<NSValue *> *mqttDuringFetch = [NSMutableArray array];
            if (existing.count > baseline) {
                [mqttDuringFetch addObjectsFromArray:[existing subarrayWithRange:NSMakeRange(baseline,
                                                                                            existing.count - baseline)]];
                for (NSUInteger i = baseline; i < existing.count; i++) {
                    id u = (i < existingUnix.count) ? existingUnix[i] : [NSNull null];
                    [mergedUnix addObject:u];
                }
            }
            [historical addObjectsFromArray:mqttDuringFetch];
            sself.liveTrackPoints[topic] = historical;
            sself.liveTrackPointUnixByTopic[topic] = mergedUnix;
            [sself.routeFetchedTopics addObject:topic];
            NSMutableDictionary *fetchDbg = [@{
                @"reqStart" : @(startTs),
                @"reqEnd" : @(endTs),
                @"windowHours" : @(hours),
                @"apiPoints" : @(count),
                @"apiPointsWithTst" : @(pointsWithTst),
                @"mqttDuringFetch" : @(mqttDuringFetch.count),
                @"apiTsBeforeStart" : @(tsOutsideLow),
                @"apiTsAfterEnd" : @(tsOutsideHigh),
            } mutableCopy];
            if (haveAnyTs) {
                fetchDbg[@"apiMinTs"] = @(apiMinTs);
                fetchDbg[@"apiMaxTs"] = @(apiMaxTs);
            }
            sself.routeLastFetchDebugByTopic[topic] = [fetchDbg copy];
            [sself rebuildLiveTrackForTopic:topic];
            [sself updateRouteHistoryToggleVisibility];
            DDLogInfo(@"[ViewController] route fetch: seeded %lu API + %lu MQTT(during-fetch) points for %@",
                      (unsigned long)count, (unsigned long)mqttDuringFetch.count, topic);
    }];
}

#pragma mark - NSFetchedResultsControllerDelegate

- (void)performFetch:(NSFetchedResultsController *)frc {
    if (frc) {
        NSError *error;
        [frc performFetch:&error];
        if (error) DDLogError(@"[%@ %@] %@ (%@)", NSStringFromClass([self class]), NSStringFromSelector(_cmd), [error localizedDescription], [error localizedFailureReason]);
    }
}

/// After a polyline is drawn: total points, geographic first/last, and (when present) REST window vs API tst span.
- (void)logRoutePolylineDrawnForTopic:(NSString *)topic
                               points:(NSArray<NSValue *> *)points
                            unixTimes:(NSArray *)unixTimes
                           fetchDebug:(NSDictionary *)fetchDebug {
    if (!topic.length || points.count < 2) {
        return;
    }
    CLLocationCoordinate2D c0 = [points.firstObject MKCoordinateValue];
    CLLocationCoordinate2D c1 = [points.lastObject MKCoordinateValue];
    BOOL unixAligned = (unixTimes.count == points.count);
    NSString *firstPST = unixAligned ? RouteDebugPSTOrUnknown(unixTimes.firstObject)
                                     : [NSString stringWithFormat:@"(PST n/a — unix count %lu vs points %lu)",
                                        (unsigned long)unixTimes.count, (unsigned long)points.count];
    NSString *lastPST = unixAligned ? RouteDebugPSTOrUnknown(unixTimes.lastObject)
                                    : @"(PST n/a)";
    DDLogInfo(@"[RouteDebug] drawn topic=%@ totalPoints=%lu polylineOrder first=(%.5f,%.5f) %@ polylineOrder last=(%.5f,%.5f) %@ (America/Los_Angeles)",
              topic, (unsigned long)points.count,
              c0.latitude, c0.longitude, firstPST,
              c1.latitude, c1.longitude, lastPST);
    if (!fetchDebug.count) {
        DDLogInfo(@"[RouteDebug] drawn topic=%@ — no REST merge context (cached/MQTT-only redraw)",
                  topic);
        return;
    }
    NSInteger rs = [fetchDebug[@"reqStart"] longValue];
    NSInteger re = [fetchDebug[@"reqEnd"] longValue];
    NSInteger wh = [fetchDebug[@"windowHours"] longValue];
    NSUInteger apiN = [fetchDebug[@"apiPoints"] unsignedIntegerValue];
    NSUInteger mqttN = [fetchDebug[@"mqttDuringFetch"] unsignedIntegerValue];
    NSUInteger withTst = [fetchDebug[@"apiPointsWithTst"] unsignedIntegerValue];
    NSUInteger outLo = [fetchDebug[@"apiTsBeforeStart"] unsignedIntegerValue];
    NSUInteger outHi = [fetchDebug[@"apiTsAfterEnd"] unsignedIntegerValue];
    NSDate *drs = [NSDate dateWithTimeIntervalSince1970:rs];
    NSDate *dre = [NSDate dateWithTimeIntervalSince1970:re];
    NSString *rsStr = [NSDateFormatter localizedStringFromDate:drs dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle];
    NSString *reStr = [NSDateFormatter localizedStringFromDate:dre dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle];
    DDLogInfo(@"[RouteDebug] drawn topic=%@ REST client window %ldh requestedUnix [%ld … %ld] (%@ — %@) merged apiPoints=%lu mqttDuringFetch=%lu apiPointsWithParsableTst=%lu",
              topic, (long)wh, (long)rs, (long)re, rsStr, reStr,
              (unsigned long)apiN, (unsigned long)mqttN, (unsigned long)withTst);
    NSNumber *minTs = fetchDebug[@"apiMinTs"];
    NSNumber *maxTs = fetchDebug[@"apiMaxTs"];
    if (minTs && maxTs) {
        NSDate *dmin = [NSDate dateWithTimeIntervalSince1970:minTs.doubleValue];
        NSDate *dmax = [NSDate dateWithTimeIntervalSince1970:maxTs.doubleValue];
        NSString *smin = [NSDateFormatter localizedStringFromDate:dmin dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle];
        NSString *smax = [NSDateFormatter localizedStringFromDate:dmax dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle];
        NSTimeInterval skewStart = minTs.doubleValue - (double)rs;
        NSTimeInterval skewEnd = maxTs.doubleValue - (double)re;
        BOOL misaligned = (skewStart < -5.0 || skewEnd > 5.0);
        DDLogInfo(@"[RouteDebug] drawn topic=%@ API tst earliest=%@ (unix=%.0f) latest=%@ (unix=%.0f) apiPointsWithTstBeforeWindow=%lu afterWindow=%lu skewVsRequestStartSec=%.0f skewVsRequestEndSec=%.0f possiblyOutside6or12hWindow=%d",
                  topic, smin, minTs.doubleValue, smax, maxTs.doubleValue,
                  (unsigned long)outLo, (unsigned long)outHi, skewStart, skewEnd, misaligned);
    } else {
        DDLogInfo(@"[RouteDebug] drawn topic=%@ no parsable tst on API points — cannot compare to %ldh window; extend OTRouteHistoryPointUnixTime if server uses another field",
                  topic, (long)wh);
    }
    if (mqttN > 0) {
        DDLogInfo(@"[RouteDebug] drawn topic=%@ note: %lu trailing points are MQTT during fetch (no per-point tst in client; polyline last coord may be newer than API latest tst)",
                  topic, (unsigned long)mqttN);
    }
}

/// Rebuilds liveTrackPolylines[topic] from liveTrackPoints[topic] and adds it to the map.
/// No-op if fewer than 2 points are available. Safe to call from the main thread only.
- (void)rebuildLiveTrackForTopic:(NSString *)topic {
    NSArray<NSValue *> *points = self.liveTrackPoints[topic];
    if (!points || points.count < 2) {
        DDLogInfo(@"[RouteDebug] rebuildLiveTrack skip topic=%@ points=%lu", topic, (unsigned long)points.count);
        if (topic.length) {
            [self.routeLastFetchDebugByTopic removeObjectForKey:topic];
        }
        [self updateRouteHistoryToggleVisibility];
        return;
    }
    DDLogInfo(@"[RouteDebug] rebuildLiveTrack topic=%@ points=%lu followFriend=%@",
              topic, (unsigned long)points.count, self.followFriend.topic ?: @"(nil)");
    [self removeFriendLiveTrackOverlaysExceptTopic:topic];
    CLLocationCoordinate2D *coords = malloc(points.count * sizeof(CLLocationCoordinate2D));
    if (!coords) return;
    for (NSUInteger i = 0; i < points.count; i++) {
        coords[i] = [points[i] MKCoordinateValue];
    }
    MKPolyline *old = self.liveTrackPolylines[topic];
    if (old) [self.mapView removeOverlay:old];
    MKPolyline *updated = [MKPolyline polylineWithCoordinates:coords count:points.count];
    free(coords);
    self.liveTrackPolylines[topic] = updated;
    [self.mapView addOverlay:updated];
    NSDictionary *fetchDbg = self.routeLastFetchDebugByTopic[topic];
    [self logRoutePolylineDrawnForTopic:topic points:points unixTimes:self.liveTrackPointUnixByTopic[topic] fetchDebug:fetchDbg];
    if (fetchDbg) {
        [self.routeLastFetchDebugByTopic removeObjectForKey:topic];
    }
    Friend *followed = self.selectedFriend;
    if (followed && [followed.topic isEqualToString:topic]) {
        [self syncFollowedFriendBreadcrumbOverlay:followed];
    }
    [self updateRouteHistoryToggleVisibility];
}

/// Course-up / north-up + user pitch while `followFriend` is set.
/// `preserveUserAltitude:YES` keeps `centerCoordinateDistance` after pinch-zoom (live updates).
/// `NO` resets to persisted `OTFollowUserDistance` when the user first selects a device.
- (void)applyFollow3DCameraToCoordinate:(CLLocationCoordinate2D)coord
                                heading:(double)headingOrNAN
                     preserveUserAltitude:(BOOL)preserveUserAltitude {
    if (!self.followEnabled || !self.followFriend ||
        self.followTemporarilySuspendedByGesture ||
        !CLLocationCoordinate2DIsValid(coord)) {
        return;
    }
    MKMapCamera *cam = [self.mapView.camera copy];
    cam.centerCoordinate = coord;
    cam.pitch = OTFollowUserPitch();
    if (preserveUserAltitude) {
        double d = cam.centerCoordinateDistance;
        if (!isfinite(d) || d <= 0.0) {
            cam.centerCoordinateDistance = OTFollowUserDistance();
        }
    } else {
        cam.centerCoordinateDistance = OTFollowUserDistance();
    }
    if (self.followHeadingLockPausedByUserGesture) {
        cam.heading = 0.0;
    } else if (headingOrNAN == headingOrNAN) {
        cam.heading = OTNormalizeHeadingDegrees(headingOrNAN);
    }
    // else: NAN (stationary / no new heading) — keep `cam.heading` from the camera copy.
    [self.mapView setCamera:cam animated:NO];
}

- (void)liveFriendLocationUpdate:(NSNotification *)note {
    NSString *topic = note.userInfo[@"topic"];
    double lat = [note.userInfo[@"lat"] doubleValue];
    double lon = [note.userInfo[@"lon"] doubleValue];
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(lat, lon);
    if (!CLLocationCoordinate2DIsValid(coord) || (lat == 0.0 && lon == 0.0)) return;

    NSTimeInterval tst = [note.userInfo[@"tst"] doubleValue];
    NSTimeInterval tstSec = tst;
    if (tstSec <= 0.0) {
        tstSec = [[NSDate date] timeIntervalSince1970];
    }

    // Smooth-animate the marker via CADisplayLink; no remove/readd, live track polyline is unaffected.
    for (id<MKAnnotation> ann in self.mapView.annotations) {
        if ([ann isKindOfClass:[Friend class]]) {
            Friend *friend = (Friend *)ann;
            if ([friend.topic isEqualToString:topic]) {
                FriendMarkerAnimator *animator = self.friendAnimators[topic];
                if (!animator) {
                    animator = [[FriendMarkerAnimator alloc] initWithFriend:friend];
                    self.friendAnimators[topic] = animator;
                }
                [animator startOrUpdateWithLatitude:lat longitude:lon timestamp:tst];
                MKAnnotationView *pinView = [self.mapView viewForAnnotation:friend];
                if ([pinView isKindOfClass:[FriendAnnotationV class]]) {
                    FriendAnnotationV *fv = (FriendAnnotationV *)pinView;
                    id c = note.userInfo[@"cog"];
                    if ([c isKindOfClass:[NSNumber class]] && OTHeadingDegreesValid([(NSNumber *)c doubleValue])) {
                        fv.course = [(NSNumber *)c doubleValue];
                    }
                    id v = note.userInfo[@"vel"];
                    NSNumber *velNum = nil;
                    if ([v isKindOfClass:[NSNumber class]]) {
                        velNum = (NSNumber *)v;
                        fv.speed = velNum.doubleValue;
                    }
                    [fv setNeedsDisplay];
                }
                break;
            }
        }
    }

    // Accumulate points for all friends (builds the cache regardless of selection state).
    if (!self.liveTrackPoints[topic]) {
        self.liveTrackPoints[topic] = [NSMutableArray array];
    }
    if (!self.liveTrackPointUnixByTopic[topic]) {
        self.liveTrackPointUnixByTopic[topic] = [NSMutableArray array];
    }
    while (self.liveTrackPointUnixByTopic[topic].count < self.liveTrackPoints[topic].count) {
        [self.liveTrackPointUnixByTopic[topic] addObject:[NSNull null]];
    }
    [self.liveTrackPoints[topic] addObject:[NSValue valueWithMKCoordinate:coord]];
    [self.liveTrackPointUnixByTopic[topic] addObject:@(tstSec)];

    DDLogVerbose(@"[ViewController] live track for %@ now has %lu points", topic, (unsigned long)self.liveTrackPoints[topic].count);

    // Only update the visible overlay for the currently selected/followed friend.
    Friend *selected = self.selectedFriend;
    if (!selected) {
        return;
    }
    if (![selected.topic isEqualToString:topic]) {
        return;
    }
    [self rebuildLiveTrackForTopic:topic];
    if (CLLocationCoordinate2DIsValid(coord)) {
        NSValue *prevBox = self.followMapPrevCoordByTopic[topic];
        CLLocationCoordinate2D prev = kCLLocationCoordinate2DInvalid;
        if (prevBox) {
            prev = [prevBox MKCoordinateValue];
        }
        double heading = OTEffectiveFollowMapHeading(note.userInfo, coord, &prev);
        [self.followMapPrevCoordByTopic setObject:[NSValue valueWithMKCoordinate:prev] forKey:topic];

        BOOL topicMatchesFollow = self.followFriend && [self.followFriend.topic isEqualToString:topic];
        if (self.followEnabled && topicMatchesFollow && !self.followTemporarilySuspendedByGesture) {
            if (heading == heading) {
                self.followHeadingTargetNumber = @(OTNormalizeHeadingDegrees(heading));
            }
        }
    }
    if (self.followEnabled && self.followFriend && [self.followFriend.topic isEqualToString:topic]) {
        [self updateInstrumentationFromUserInfo:note.userInfo topic:topic];
    }
    [self updateRouteHistoryToggleVisibility];
}

- (NSFetchedResultsController *)frcFriends {
    if (!_frcFriends) {
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Friend"];

        double ignoreStaleLocations = [Settings doubleForKey:@"ignorestalelocations_preference"
                                                       inMOC:CoreData.sharedInstance.mainMOC];
        if (ignoreStaleLocations) {
            NSTimeInterval stale = -ignoreStaleLocations * 24.0 * 3600.0;
            request.predicate = [NSPredicate predicateWithFormat:@"lastLocation > %@",
                                 [NSDate dateWithTimeIntervalSinceNow:stale]];
        }

        request.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"topic" ascending:TRUE]];
        _frcFriends = [[NSFetchedResultsController alloc] initWithFetchRequest:request
                                                          managedObjectContext:CoreData.sharedInstance.mainMOC
                                                            sectionNameKeyPath:nil
                                                                     cacheName:nil];
        _frcFriends.delegate = self;
        [self performFetch:_frcFriends];
        [self.mapView addAnnotations:_frcFriends.fetchedObjects];
    }
    return _frcFriends;
}

- (NSFetchedResultsController *)frcRegions {
    if (!_frcRegions) {
        [[LocationManager sharedInstance] resetRegions];
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Region"];
        request.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:TRUE]];
        _frcRegions = [[NSFetchedResultsController alloc] initWithFetchRequest:request
                                                          managedObjectContext:CoreData.sharedInstance.mainMOC
                                                            sectionNameKeyPath:nil
                                                                     cacheName:nil];
        _frcRegions.delegate = self;
        [self performFetch:_frcRegions];
        Friend *friend = [Friend friendWithTopic:[Settings theGeneralTopicInMOC:CoreData.sharedInstance.mainMOC]
                          inManagedObjectContext:CoreData.sharedInstance.mainMOC];
        [self.mapView addOverlays:[friend.hasRegions
                                   sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name"
                                                                                               ascending:YES]]]];
        for (Region *region in friend.hasRegions) {
            if (region.CLregion) {
                [[LocationManager sharedInstance] startRegion:region.CLregion];
            }
        }
        [self.mapView addAnnotations:[friend.hasRegions sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name"
                                                                                                                    ascending:YES]]]];
    }
    return _frcRegions;
}

- (NSFetchedResultsController *)frcWaypoints {
    if (!_frcWaypoints) {
        NSFetchRequest<Waypoint *> *request = Waypoint.fetchRequest;
        request.predicate = [NSPredicate predicateWithFormat:@"poi <> NULL"];

        request.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"tst" ascending:TRUE]];
        _frcWaypoints = [[NSFetchedResultsController alloc] initWithFetchRequest:request
                                                            managedObjectContext:CoreData.sharedInstance.mainMOC
                                                              sectionNameKeyPath:nil
                                                                       cacheName:nil];
        _frcWaypoints.delegate = self;
        [self performFetch:_frcWaypoints];
        [self.mapView addAnnotations:_frcWaypoints.fetchedObjects];
    }
    return _frcWaypoints;
}

- (void)controllerWillChangeContent:(NSFetchedResultsController *)controller
{
    //
}

- (void)controller:(NSFetchedResultsController *)controller
  didChangeSection:(id <NSFetchedResultsSectionInfo>)sectionInfo
           atIndex:(NSUInteger)sectionIndex
     forChangeType:(NSFetchedResultsChangeType)type {
    if (!self.suspendAutomaticTrackingOfChangesInManagedObjectContext)
    {
        switch(type)
        {
            case NSFetchedResultsChangeInsert:
            case NSFetchedResultsChangeDelete:
            case NSFetchedResultsChangeUpdate:
            default:
                break;
        }
    }
}

- (void)controller:(NSFetchedResultsController *)controller
   didChangeObject:(id)anObject
       atIndexPath:(NSIndexPath *)indexPath
     forChangeType:(NSFetchedResultsChangeType)type
      newIndexPath:(NSIndexPath *)newIndexPath {
    if (!self.suspendAutomaticTrackingOfChangesInManagedObjectContext) {
        NSDictionary *d = @{@"object": anObject, @"type": @(type)};
        [self performSelectorOnMainThread:@selector(p:) withObject:d waitUntilDone:FALSE];
    }
}

- (void)p:(NSDictionary *)d {
    id anObject = d[@"object"];
    NSNumber *type = d[@"type"];
    if ([anObject isKindOfClass:[Friend class]]) {
        Friend *friend = (Friend *)anObject;
        Waypoint *waypoint = friend.newestWaypoint;
        switch(type.intValue) {
            case NSFetchedResultsChangeInsert:
                if (waypoint && (waypoint.lat).doubleValue != 0.0 && (waypoint.lon).doubleValue != 0.0) {
                    [self.mapView addAnnotation:friend];
                    // Seed the live track with the initial API position so the polyline has a start point.
                    if (!self.liveTrackPoints[friend.topic]) {
                        CLLocationCoordinate2D seed = friend.coordinate;
                        if (CLLocationCoordinate2DIsValid(seed)) {
                            self.liveTrackPoints[friend.topic] =
                                [NSMutableArray arrayWithObject:[NSValue valueWithMKCoordinate:seed]];
                            NSTimeInterval seedUnix = [[NSDate date] timeIntervalSince1970];
                            if (waypoint.tst) {
                                seedUnix = [waypoint.tst timeIntervalSince1970];
                            }
                            self.liveTrackPointUnixByTopic[friend.topic] =
                                [NSMutableArray arrayWithObject:@(seedUnix)];
                        }
                    }
                }
                break;

            case NSFetchedResultsChangeDelete: {
                NSString *topic = friend.topic;
                [self.mapView removeOverlay:friend];
                [self.mapView removeAnnotation:friend];
                MKPolyline *liveTrack = topic.length ? self.liveTrackPolylines[topic] : nil;
                if (liveTrack) {
                    [self.mapView removeOverlay:liveTrack];
                    [self.liveTrackPolylines removeObjectForKey:topic];
                }
                if (topic.length) {
                    [self.liveTrackPoints removeObjectForKey:topic];
                    [self.liveTrackPointUnixByTopic removeObjectForKey:topic];
                    [self.routeFetchedTopics removeObject:topic];
                    [self.routeFetchMQTTBaselineByTopic removeObjectForKey:topic];
                    [self.friendAnimators[topic] cancel];
                    [self.friendAnimators removeObjectForKey:topic];
                }
                if (self.selectedFriend == friend || self.followFriend == friend) {
                    [self stopFollowLink];
                    self.selectedFriend = nil;
                    self.followFriend = nil;
                    self.followEnabled = YES;
                    [self updateFollowToggleAppearance];
                    [self updateFollowToggleVisibility];
                }
                break;
            }

            case NSFetchedResultsChangeUpdate:
            case NSFetchedResultsChangeMove: {
                BOOL hadWaypoint = waypoint && (waypoint.lat).doubleValue != 0.0 && (waypoint.lon).doubleValue != 0.0;
                BOOL onMap = [self.mapView.annotations containsObject:friend];
                Friend *followed = self.selectedFriend;
                BOOL isFollowed = (followed != nil && friend == followed);

                [self.mapView removeOverlay:friend];
                if (hadWaypoint) {
                    if (onMap) {
                        if (isFollowed) {
                            if (![self liveTrackPolylineSupersedesBreadcrumbForTopic:friend.topic]) {
                                [self.mapView addOverlay:friend];
                                DDLogInfo(@"[RouteDebug] FRC Friend update: refresh breadcrumb topic=%@", friend.topic);
                            } else {
                                DDLogVerbose(@"[RouteDebug] FRC Friend update: skip breadcrumb refresh; liveTrack polyline topic=%@",
                                             friend.topic);
                            }
                        } else {
                            DDLogInfo(@"[RouteDebug] FRC Friend update: strip breadcrumb (not followed) topic=%@",
                                      friend.topic);
                        }
                        [self refreshFriendAnnotationViewForFriend:friend];
                    } else {
                        [self.mapView addAnnotation:friend];
                        if (isFollowed && ![self liveTrackPolylineSupersedesBreadcrumbForTopic:friend.topic]) {
                            [self.mapView addOverlay:friend];
                            DDLogInfo(@"[RouteDebug] FRC Friend update: add pin+breadcrumb topic=%@", friend.topic);
                        } else if (isFollowed) {
                            DDLogVerbose(@"[RouteDebug] FRC Friend update: skip add breadcrumb; liveTrack polyline topic=%@",
                                         friend.topic);
                        }
                    }
                } else {
                    if (onMap) {
                        [self.mapView removeAnnotation:friend];
                    }
                }
                break;
            }
        }

    } else if ([anObject isKindOfClass:[Region class]]) {
        Region *region = (Region *)anObject;
        switch(type.intValue) {
            case NSFetchedResultsChangeInsert:
                [self.mapView addAnnotation:region];
                [self.mapView addOverlay:region];
                break;

            case NSFetchedResultsChangeDelete:
                [self.mapView removeOverlay:region];
                [self.mapView removeAnnotation:region];
                break;

            case NSFetchedResultsChangeUpdate:
            case NSFetchedResultsChangeMove:
                [self.mapView removeOverlay:region];
                [self.mapView removeAnnotation:region];
                [self.mapView addAnnotation:region];
                [self.mapView addOverlay:region];

                break;
        }
    } else if ([anObject isKindOfClass:[Waypoint class]]) {
        Waypoint *waypoint = (Waypoint *)anObject;
        switch(type.intValue) {
            case NSFetchedResultsChangeInsert:
                [self.mapView addAnnotation:waypoint];
                break;

            case NSFetchedResultsChangeDelete:
                [self.mapView removeAnnotation:waypoint];
                break;

            case NSFetchedResultsChangeUpdate:
            case NSFetchedResultsChangeMove:
                [self.mapView removeAnnotation:waypoint];
                [self.mapView addAnnotation:waypoint];
                {
                    Friend *owner = waypoint.belongsTo;
                    if (owner && self.selectedFriend == owner) {
                        [self syncFollowedFriendBreadcrumbOverlay:owner];
                    }
                }
                break;
        }
    }
}

- (void)controllerDidChangeContent:(NSFetchedResultsController *)controller
{
    //
}

- (void)endSuspensionOfUpdatesDueToContextChanges
{
    self.suspendAutomaticTrackingOfChangesInManagedObjectContext = NO;
}

- (void)setSuspendAutomaticTrackingOfChangesInManagedObjectContext:(BOOL)suspend
{
    if (suspend) {
        _suspendAutomaticTrackingOfChangesInManagedObjectContext = YES;
    } else {
        [self endSuspensionOfUpdatesDueToContextChanges];
    }
}

- (IBAction)actionPressed:(UIBarButtonItem *)sender {
    UIAlertController *ac = [UIAlertController
                             alertControllerWithTitle:NSLocalizedString(@"Choose action", @"Choose action title")
                             message:nil
                             preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *sendNow = [UIAlertAction actionWithTitle:NSLocalizedString(@"Send location now",
                                                                              @"Send location now")
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction * _Nonnull action) {
        [self sendNow:nil withImage:nil withImageName:nil];
    }];
    UIAlertAction *setPoi = [UIAlertAction actionWithTitle:NSLocalizedString(@"Set POI",
                                                                             @"Set POI button")
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction * _Nonnull action) {
        [self setPOI:nil];

    }];
    UIAlertAction *setPoiWithImage = [UIAlertAction actionWithTitle:NSLocalizedString(@"Set POI with image",
                                                                                      @"Set POI with image button")
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(UIAlertAction * _Nonnull action) {
        [self setPOIWithImage:nil];
        
    }];
    UIAlertAction *setTag = [UIAlertAction actionWithTitle:NSLocalizedString(@"Set tag",
                                                                             @"Set tag button")
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction * _Nonnull action) {
        [self setTag:nil];
        
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel",
                                                                             @"Cancel button title")
                                                     style:UIAlertActionStyleCancel
                                                   handler:^(UIAlertAction * _Nonnull action) {
        //
    }];
    [ac addAction:sendNow];
    [ac addAction:setPoi];
    [ac addAction:setPoiWithImage];
    [ac addAction:setTag];
    [ac addAction:cancel];
    [self presentViewController:ac
                       animated:TRUE
                     completion:^{
        //
    }];
}

- (void)sendNow:(nullable NSString *)poi
      withImage:(nullable NSData *)image
  withImageName:(nullable NSString *)imageName {
    BOOL validIds = [Settings validIdsInMOC:CoreData.sharedInstance.mainMOC];
    int ignoreInaccurateLocations = [Settings intForKey:@"ignoreinaccuratelocations_preference"
                                                      inMOC:CoreData.sharedInstance.mainMOC];
    CLLocation *location = self.mapView.userLocation.location;
    if (!location) {
        location = [LocationManager sharedInstance].location;
    }

    DDLogVerbose(@"[ViewController] sendNow %dm %d %@ %@ %@ %@",
                 ignoreInaccurateLocations, validIds, location, poi, image, imageName);

    if (!validIds) {
        NSString *message = NSLocalizedString(@"To publish your location userID and deviceID must be set",
                                              @"Warning displayed if necessary settings are missing");

        [NavigationController alert:@"Settings" message:message];
        return;
    }

    if (!location ||
        !CLLocationCoordinate2DIsValid(location.coordinate) ||
        (location.coordinate.latitude == 0.0 &&
         location.coordinate.longitude == 0.0)
        ) {
        [NavigationController alert:
             NSLocalizedString(@"Location",
                               @"Header of an alert message regarding a location")
                            message:
             NSLocalizedString(@"No location available",
                               @"Warning displayed if not location available")
        ];
        return;
    }

    if (ignoreInaccurateLocations != 0 && location.horizontalAccuracy > ignoreInaccurateLocations) {
        [NavigationController alert:
             NSLocalizedString(@"Location",
                               @"Header of an alert message regarding a location")
                            message:
             NSLocalizedString(@"Inaccurate or old location information",
                               @"Warning displayed if location is inaccurate or old")
        ];
        return;
    }

    OwnTracksAppDelegate *ad = (OwnTracksAppDelegate *)[UIApplication sharedApplication].delegate;
    if ([ad sendNow:location withPOI:poi withImage:image withImageName:imageName]) {
        [NavigationController alert:
             NSLocalizedString(@"Location",
                               @"Header of an alert message regarding a location")
                            message:
             NSLocalizedString(@"publish queued on user request",
                               @"content of an alert message regarding user publish")
                       dismissAfter:1
        ];
    } else {
        [NavigationController alert:
         NSLocalizedString(@"Location",
                           @"Header of an alert message regarding a location")
                            message:
         NSLocalizedString(@"publish queued on user request",
                           @"content of an alert message regarding user publish")];
    }
}

- (IBAction)longPress:(UILongPressGestureRecognizer *)sender {
    if ([Settings theLockedInMOC:CoreData.sharedInstance.mainMOC]) {
        return;
    }

    if (sender.state == UIGestureRecognizerStateBegan) {
        Friend *friend = [Friend friendWithTopic:[Settings theGeneralTopicInMOC:CoreData.sharedInstance.mainMOC] inManagedObjectContext:CoreData.sharedInstance.mainMOC];
        NSString *rid = Region.newRid;
        [[OwnTracking sharedInstance] addRegionFor:rid
                                            friend:friend
                                              name:[NSString stringWithFormat:@"Center-%@",
                                                    rid]
                                               tst:[NSDate date]
                                              uuid:nil
                                             major:0
                                             minor:0
                                            radius:0
                                               lat:self.mapView.centerCoordinate.latitude
                                               lon:self.mapView.centerCoordinate.longitude];

        [NavigationController alert:
             NSLocalizedString(@"Region",
                               @"Header of an alert message regarding circular region")
                            message:
             NSLocalizedString(@"created at center of map",
                               @"content of an alert message regarding circular region")
                       dismissAfter:1
        ];
    }
}

- (IBAction)setPOI:(UIBarButtonItem *)sender {
    UIAlertController *ac = [UIAlertController
                             alertControllerWithTitle:NSLocalizedString(@"Set POI", @"Set POI title")
                             message:nil
                             preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *send = [UIAlertAction actionWithTitle:NSLocalizedString(@"Send",
                                                                           @"Send button title")
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction * _Nonnull action) {
        [self sendNow:ac.textFields[0].text withImage:nil withImageName:nil];
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel",
                                                                             @"Cancel button title")
                                                     style:UIAlertActionStyleCancel
                                                   handler:^(UIAlertAction * _Nonnull action) {
        //
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.text = nil;
    }];
    [ac addAction:send];
    [ac addAction:cancel];
    [self presentViewController:ac
                       animated:TRUE
                     completion:^{
        //
    }];
}

- (IBAction)setPOIWithImage:(id)sender {
    [self performSegueWithIdentifier:@"AttachPhotoSegue" sender:sender];
}

- (IBAction)setTag:(UIBarButtonItem *)sender {
    UIAlertController *ac = [UIAlertController
                             alertControllerWithTitle:NSLocalizedString(@"Set Tag", @"Set Tag title")
                             message:nil
                             preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *send = [UIAlertAction actionWithTitle:NSLocalizedString(@"Send",
                                                                           @"Send button title")
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction * _Nonnull action) {
        if (!ac.textFields[0].text.length) {
            [[NSUserDefaults standardUserDefaults] setObject:nil forKey:@"tag"];
        } else {
            [[NSUserDefaults standardUserDefaults] setObject:ac.textFields[0].text forKey:@"tag"];
        }
        [self sendNow:nil withImage:nil withImageName:nil];
    }];
    UIAlertAction *remove = [UIAlertAction actionWithTitle:NSLocalizedString(@"Remove",
                                                                             @"Remove button title")
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction * _Nonnull action) {
        [[NSUserDefaults standardUserDefaults] setObject:nil forKey:@"tag"];

    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel",
                                                                             @"Cancel button title")
                                                     style:UIAlertActionStyleCancel
                                                   handler:^(UIAlertAction * _Nonnull action) {
        //
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.text = [[NSUserDefaults standardUserDefaults] stringForKey:@"tag"];
    }];
    [ac addAction:send];
    [ac addAction:remove];
    [ac addAction:cancel];
    [self presentViewController:ac
                       animated:TRUE
                     completion:^{
        //
    }];

}

- (IBAction)attachPhoto:(UIStoryboardSegue *)segue {
    if ([segue.sourceViewController respondsToSelector:@selector(photo)] &&
        [segue.sourceViewController respondsToSelector:@selector(poi)] &&
        [segue.sourceViewController respondsToSelector:@selector(data)] &&
        [segue.sourceViewController respondsToSelector:@selector(imageName)]) {
        UITextField *poi = [segue.sourceViewController performSelector:@selector(poi)];
        UIImageView *photo = [segue.sourceViewController performSelector:@selector(photo)];
        NSString *imageName = [segue.sourceViewController performSelector:@selector(imageName)];
        //we don't use the raw photo data currently
        //NSData *data = [segue.sourceViewController performSelector:@selector(data)];
        
        NSData *jpg = UIImageJPEGRepresentation(photo.image, 0.9);
        [self sendNow:poi.text withImage:jpg withImageName:imageName];
    }
}

@end
