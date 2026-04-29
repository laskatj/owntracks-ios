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
#import "FriendCalloutSpeedView.h"
#import "PhotoAnnotationV.h"
#import "FriendsTVC.h"
#import "RegionsTVC.h"
#import "WaypointTVC.h"
#import "CoreData.h"
#import "Friend+CoreDataClass.h"
#import "Region+CoreDataClass.h"
#import "Waypoint+CoreDataClass.h"
#import "LocationManager.h"
#import "OwnTracking.h"
#import "LocationAPISyncService.h"
#import "WebAppURLResolver.h"
#import "Settings.h"
#import "OTMapFollowHeading.h"

#import "OwnTracksChangeMonitoringIntent.h"

static NSString * const kMapRouteHistoryHoursKey = @"mapRouteHistoryHours";

/// Best-effort unix seconds from a Recorder route point dict (for 6h/12h alignment debug).
static NSTimeInterval RouteHistoryPointUnixTime(NSDictionary *pt) {
    if (![pt isKindOfClass:[NSDictionary class]]) {
        return NAN;
    }
    NSArray<NSString *> *keys = @[ @"tst", @"timestamp", @"time", @"createdAt", @"created_at" ];
    for (NSString *key in keys) {
        id v = pt[key];
        if ([v isKindOfClass:[NSNumber class]]) {
            double t = [(NSNumber *)v doubleValue];
            if (t > 1e12) {
                t /= 1000.0;
            }
            if (t > 946684800 && t < 4102444800) {
                return t;
            }
        } else if ([v isKindOfClass:[NSString class]]) {
            NSString *s = (NSString *)v;
            double t = [s doubleValue];
            if (t > 1e12) {
                t /= 1000.0;
            }
            if (t > 946684800 && t < 4102444800) {
                return t;
            }
            static NSISO8601DateFormatter *isoFmt;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                isoFmt = [[NSISO8601DateFormatter alloc] init];
            });
            NSDate *d = [isoFmt dateFromString:s];
            if (d) {
                return [d timeIntervalSince1970];
            }
        }
    }
    return NAN;
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

/// Pinch-zoom should not pause course-up follow; other gestures (pan, rotate) still do.
static BOOL OTViewControllerRegionChangeIsPinchZoomOnly(MKMapView *mapView) {
    UIView *content = mapView.subviews.firstObject;
    if (!content) {
        return NO;
    }
    BOOL anyActive = NO;
    for (UIGestureRecognizer *gr in content.gestureRecognizers) {
        if (gr.state != UIGestureRecognizerStateBegan && gr.state != UIGestureRecognizerStateChanged) {
            continue;
        }
        anyActive = YES;
        if (![gr isKindOfClass:[UIPinchGestureRecognizer class]]) {
            return NO;
        }
    }
    return anyActive;
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

static void VCSyncFriendCalloutSpeed(FriendAnnotationV *fv, Friend *friend, NSNumber *_Nullable liveVelKmH) {
    UIView *detail = fv.detailCalloutAccessoryView;
    if (![detail isKindOfClass:[FriendCalloutSpeedView class]]) {
        return;
    }
    double kmh = -1.0;
    if ([liveVelKmH isKindOfClass:[NSNumber class]] && isfinite(liveVelKmH.doubleValue)) {
        kmh = liveVelKmH.doubleValue;
    } else {
        Waypoint *wp = friend.newestWaypoint;
        if (wp.vel != nil) {
            double v = wp.vel.doubleValue;
            if (isfinite(v) && v >= 0.0) {
                kmh = v;
            }
        }
    }
    [(FriendCalloutSpeedView *)detail updateSpeedKmH:kmh];
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
@property (weak, nonatomic) IBOutlet UIBarButtonItem *askForMapButton;
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
/// CADisplayLink that re-centers the map on the selected friend every frame.
@property (nonatomic, strong, nullable) CADisplayLink *followLink;
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
/// Active positional constraints for `mapRouteFollowStack` (rebuilt when `trackingButton` appears or is removed).
@property (nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *mapRouteFollowStackLayoutConstraints;
/// One-shot debug payload for the next `rebuildLiveTrackForTopic:` after a route GET merges (REST window vs API tst).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *routeLastFetchDebugByTopic;
/// Previous coordinate per MQTT topic for course-up / bearing fallback (`OTMapFollowHeading`).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *followMapPrevCoordByTopic;
/// User panned/rotated the map; skip heading lock until the next explicit follow selection.
@property (nonatomic, assign) BOOL followHeadingLockPausedByUserGesture;
@end


@implementation ViewController
static const DDLogLevel ddLogLevel = DDLogLevelInfo;

- (void)viewDidLoad {
    [super viewDidLoad];

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
    [self setupCompassButton];
    
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
    [self setupMapRouteFollowControlsRow];
    self.followEnabled = YES;
    [self updateFollowToggleAppearance];
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
    [NSLayoutConstraint activateConstraints:@[
        [compass.trailingAnchor constraintEqualToAnchor:self.mapView.trailingAnchor constant:-12],
        [compass.topAnchor constraintEqualToAnchor:self.mapView.topAnchor constant:12],
    ]];
    [self.view bringSubviewToFront:compass];
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
        return;
    }
    self.followFriend = f;
    self.followHeadingLockPausedByUserGesture = NO;
    Waypoint *wpHeading = f.newestWaypoint;
    double initialHeading = NAN;
    if (wpHeading.cog && OTHeadingDegreesValid(wpHeading.cog.doubleValue)) {
        initialHeading = OTNormalizeHeadingDegrees(wpHeading.cog.doubleValue);
    }
    [self applyFollow3DCameraToCoordinate:f.coordinate
                                  heading:initialHeading
                       preserveUserAltitude:YES];
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
    VCSyncFriendCalloutSpeed(friendAnnotationV, friend, nil);
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
    
    if (self.noMap == 0) {
        [self askForMap:nil];
    }

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

- (void)setCenter:(id<MKAnnotation>)annotation {
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
    if (!self.initialCenter) {
        self.initialCenter = TRUE;
        [self.mapView setCenterCoordinate:userLocation.location.coordinate animated:TRUE];
    }
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
        friendAnnotationV.canShowCallout = YES;
        friendAnnotationV.rightCalloutAccessoryView = [UIButton buttonWithType:UIButtonTypeDetailDisclosure];

        NSData *data = friend.image;
        UIImage *image = [UIImage imageWithData:data];
        friendAnnotationV.personImage = image;
        friendAnnotationV.tid = friend.effectiveTid;
        friendAnnotationV.speed = (waypoint.vel).doubleValue;
        friendAnnotationV.course = (waypoint.cog).doubleValue;
        friendAnnotationV.me = [friend.topic isEqualToString:[Settings theGeneralTopicInMOC:CoreData.sharedInstance.mainMOC]];
        [friendAnnotationV setNeedsDisplay];

        FriendCalloutSpeedView *speedCallout = [[FriendCalloutSpeedView alloc] initWithFrame:CGRectZero];
        double velKmh = -1.0;
        if (waypoint.vel != nil) {
            double v = waypoint.vel.doubleValue;
            if (isfinite(v) && v >= 0.0) {
                velKmh = v;
            }
        }
        [speedCallout updateSpeedKmH:velKmh];
        friendAnnotationV.detailCalloutAccessoryView = speedCallout;

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
        
    } else if ([overlay isKindOfClass:[MKTileOverlay class]]) {
        return self.osmRenderer;

    } else {
        return nil;
    }
}

- (void)mapView:(MKMapView *)mapView
 annotationView:(MKAnnotationView *)view
calloutAccessoryControlTapped:(UIControl *)control {
    if (control == view.rightCalloutAccessoryView) {
        if ([view.annotation isKindOfClass:[Region class]]) {
            [self performSegueWithIdentifier:@"showRegionFromMap" sender:view];
        } else if ([view.annotation isKindOfClass:[Friend class]]) {
            [self performSegueWithIdentifier:@"showWaypointFromMap" sender:view];
        } else if ([view.annotation isKindOfClass:[Waypoint class]]) {
            [self performSegueWithIdentifier:@"showWaypointFromMap" sender:view];
        }
    }
}

- (void)mapView:(MKMapView *)mapView didSelectAnnotationView:(MKAnnotationView *)view {
    if ([view.annotation isKindOfClass:[Friend class]]) {
        Friend *friend = (Friend *)view.annotation;
        DDLogInfo(@"[Follow] didSelectAnnotationView: topic=%@ coord=(%g,%g)",
                  friend.topic, friend.coordinate.latitude, friend.coordinate.longitude);
        self.followHeadingLockPausedByUserGesture = NO;
        [self applyFollowSelectionForMapFriend:friend mapView:mapView];
        if ([view isKindOfClass:[FriendAnnotationV class]]) {
            VCSyncFriendCalloutSpeed((FriendAnnotationV *)view, friend, nil);
        }
    }
}

- (void)mapView:(MKMapView *)mapView regionWillChangeAnimated:(BOOL)animated {
    // Pan/zoom must NOT clear the selected friend or their route — selection is tied to the
    // annotation (see didDeselectAnnotationView). Only stop optional camera-follow CADisplayLink.
    if (OTViewControllerRegionChangeIsPinchZoomOnly(mapView)) {
        DDLogInfo(@"[Follow] pinch zoom — keep course-up follow (selection + route unchanged)");
        [self stopFollowLink];
        return;
    }
    UIView *mapContentView = mapView.subviews.firstObject;
    for (UIGestureRecognizer *gr in mapContentView.gestureRecognizers) {
        if (gr.state == UIGestureRecognizerStateBegan ||
            gr.state == UIGestureRecognizerStateChanged) {
            DDLogInfo(@"[Follow] map pan/rotate — stopFollowLink; pause course-up (keep selection + route)");
            [self stopFollowLink];
            if (self.followEnabled && self.followFriend) {
                self.followHeadingLockPausedByUserGesture = YES;
                MKMapCamera *cam = [self.mapView.camera copy];
                cam.heading = 0.0;
                cam.pitch = OTMaxFollowMapCameraPitch();
                [self.mapView setCamera:cam animated:YES];
            }
            return;
        }
    }
}

- (void)mapView:(MKMapView *)mapView didDeselectAnnotationView:(MKAnnotationView *)view {
    if ([view.annotation isKindOfClass:[Friend class]]) {
        Friend *friend = (Friend *)view.annotation;
        NSString *topic = friend.topic;
        DDLogInfo(@"[Follow] didDeselectAnnotationView: topic=%@, stopping follow", friend.topic);
        [self stopFollowLink];
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
        [self applyFollow3DCameraToCoordinate:friend.coordinate
                                      heading:initialHeading
                           preserveUserAltitude:NO];
    }
    if ([self.routeFetchedTopics containsObject:friend.topic]
            && self.liveTrackPoints[friend.topic].count >= 2) {
        [self rebuildLiveTrackForTopic:friend.topic];
    } else {
        [self fetchRouteForFriend:friend mapView:mapView];
    }
    [self updateRouteHistoryToggleVisibility];
}

- (void)followFriendFromList:(Friend *)friend {
    if (!friend.topic.length) {
        DDLogWarn(@"[Follow] followFriendFromList: missing topic");
        return;
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
    DDLogInfo(@"[Follow] startFollowLink for topic=%@", self.followFriend.topic);
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self
                                                      selector:@selector(followTick:)];
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    self.followLink = link;
}

- (void)stopFollowLink {
    if (self.followLink) DDLogInfo(@"[Follow] stopFollowLink");
    [self.followLink invalidate];
    self.followLink = nil;
}

- (void)followTick:(CADisplayLink *)link {
    Friend *f = self.followEnabled ? self.followFriend : nil;
    if (!f) { [self stopFollowLink]; return; }
    CLLocationCoordinate2D coord = f.coordinate;
    // Log every ~60 frames (≈1 s) so the console stays readable.
    static NSUInteger sFollowTickCount = 0;
    if (++sFollowTickCount % 60 == 0) {
        CLLocationCoordinate2D center = self.mapView.centerCoordinate;
        DDLogInfo(@"[Follow] tick#%lu friend=(%g,%g) mapCenter=(%g,%g) coordValid=%d",
                  (unsigned long)sFollowTickCount,
                  coord.latitude, coord.longitude,
                  center.latitude, center.longitude,
                  CLLocationCoordinate2DIsValid(coord));
    }
    if (CLLocationCoordinate2DIsValid(coord)) {
        [self.mapView setCenterCoordinate:coord animated:NO];
    }
}

/// `historyHoursOverride`: pass 6 or 12 to force that window (e.g. toggle); pass -1 to use `NSUserDefaults` via `routeHistoryHours`.
- (void)fetchRouteForFriend:(Friend *)friend mapView:(MKMapView *)mapView {
    [self fetchRouteForFriend:friend mapView:mapView historyHours:-1];
}

- (void)fetchRouteForFriend:(Friend *)friend mapView:(MKMapView *)mapView historyHours:(NSInteger)historyHoursOverride {
    NSString *routeUser = friend.routeAPIUser;
    NSString *routeDevice = friend.tid;
    NSString *topic = friend.topic;

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
    NSURL *origin = [WebAppURLResolver webAppOriginURLFromPreferenceInMOC:mainMOC];
    if (!origin) {
        DDLogInfo(@"[ViewController] route fetch: no origin URL, showing cached track for %@", topic);
        [self.pendingRouteTopics removeObject:topic];
        [self rebuildLiveTrackForTopic:topic];
        return;
    }

    NSInteger endTs = (NSInteger)[[NSDate date] timeIntervalSince1970];
    NSInteger hours = (historyHoursOverride == 6 || historyHoursOverride == 12)
        ? historyHoursOverride
        : [self routeHistoryHours];
    NSInteger startTs = endTs - hours * 60 * 60;

    NSString *path = [NSString stringWithFormat:@"/api/location/history/%@/%@/route", routeUser, routeDevice];

    NSURLComponents *components = [NSURLComponents componentsWithURL:origin resolvingAgainstBaseURL:NO];
    components.path = path;
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"start" value:@(startTs).stringValue],
        [NSURLQueryItem queryItemWithName:@"end" value:@(endTs).stringValue],
    ];
    NSURL *routeURL = components.URL;
    if (!routeURL) {
        DDLogWarn(@"[ViewController] route fetch: could not build URL for %@", topic);
        [self.pendingRouteTopics removeObject:topic];
        [self rebuildLiveTrackForTopic:topic];
        return;
    }

    DDLogInfo(@"[ViewController] route fetch: GET %@ windowHours=%ld spanSec=%ld start=%ld end=%ld",
              routeURL, (long)hours, (long)(endTs - startTs), (long)startTs, (long)endTs);

    NSUInteger mqttBaseline = [self.liveTrackPoints[topic] count];
    self.routeFetchMQTTBaselineByTopic[topic] = @(mqttBaseline);
    DDLogInfo(@"[ViewController] route fetch: MQTT baseline count=%lu for topic=%@ (only points added after this merge with API)",
              (unsigned long)mqttBaseline, topic);

    __weak typeof(self) wself = self;
    [[LocationAPISyncService sharedInstance] performAuthenticatedGET:routeURL
                                                          completion:^(NSData * _Nullable data, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(wself) sself = wself;
            if (!sself) return;

            if (![sself.pendingRouteTopics containsObject:topic]) {
                // Friend was deselected while the request was in flight — discard.
                [sself.routeFetchMQTTBaselineByTopic removeObjectForKey:topic];
                [sself updateRouteHistoryToggleVisibility];
                return;
            }
            [sself.pendingRouteTopics removeObject:topic];

            DDLogInfo(@"[ViewController] route fetch: response for %@ — data=%lu bytes error=%@",
                      topic, (unsigned long)data.length, error.localizedDescription ?: @"none");

            if (error || !data.length) {
                DDLogInfo(@"[ViewController] route fetch failed for %@: %@, showing cached track", topic, error.localizedDescription);
                [sself.routeFetchMQTTBaselineByTopic removeObjectForKey:topic];
                [sself rebuildLiveTrackForTopic:topic];
                return;
            }

            NSError *jsonError = nil;
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (jsonError) {
                DDLogWarn(@"[ViewController] route fetch JSON parse error for %@: %@", topic, jsonError.localizedDescription);
                NSString *bodySnippet = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, MIN(data.length, 200))]
                                                              encoding:NSUTF8StringEncoding];
                DDLogWarn(@"[ViewController] route fetch raw body (first 200 bytes): %@", bodySnippet);
            }
            NSArray *points = nil;
            if ([obj isKindOfClass:[NSDictionary class]]) {
                id p = ((NSDictionary *)obj)[@"points"];
                if ([p isKindOfClass:[NSArray class]]) {
                    points = (NSArray *)p;
                } else {
                    DDLogWarn(@"[ViewController] route fetch: 'points' key missing or wrong type for %@ — keys: %@",
                              topic, [(NSDictionary *)obj allKeys]);
                }
            } else {
                DDLogWarn(@"[ViewController] route fetch: response is not a dict for %@ (class: %@)", topic, NSStringFromClass([obj class]));
            }

            DDLogInfo(@"[ViewController] route fetch: %lu raw points for %@", (unsigned long)points.count, topic);

            if (!points.count) {
                DDLogInfo(@"[ViewController] route fetch: no points for %@, showing cached track", topic);
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
            for (id pt in points) {
                if (![pt isKindOfClass:[NSDictionary class]]) {
                    continue;
                }
                NSDictionary *d = (NSDictionary *)pt;
                id latObj = d[@"latitude"];
                id lonObj = d[@"longitude"];
                if (![latObj isKindOfClass:[NSNumber class]] || ![lonObj isKindOfClass:[NSNumber class]]) {
                    continue;
                }
                double lat = [(NSNumber *)latObj doubleValue];
                double lon = [(NSNumber *)lonObj doubleValue];
                if (lat == 0.0 && lon == 0.0) {
                    continue;
                }
                NSTimeInterval unix = RouteHistoryPointUnixTime(d);
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
        });
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
        DDLogInfo(@"[RouteDebug] drawn topic=%@ no parsable tst on API points — cannot compare to %ldh window; extend RouteHistoryPointUnixTime if server uses another field",
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

/// Default camera altitude (m) when starting follow — street-level; user can pinch after.
static const CLLocationDistance kFollowDefaultCameraDistanceM = 900.0;

/// Course-up / north-up + maximum pitch while `followFriend` is set.
/// `preserveUserAltitude:YES` keeps `centerCoordinateDistance` after pinch-zoom (live updates).
/// `NO` resets to `kFollowDefaultCameraDistanceM` when the user first selects a device.
- (void)applyFollow3DCameraToCoordinate:(CLLocationCoordinate2D)coord
                                heading:(double)headingOrNAN
                     preserveUserAltitude:(BOOL)preserveUserAltitude {
    if (!self.followEnabled || !self.followFriend || !CLLocationCoordinate2DIsValid(coord)) {
        return;
    }
    MKMapCamera *cam = [self.mapView.camera copy];
    cam.centerCoordinate = coord;
    cam.pitch = OTMaxFollowMapCameraPitch();
    if (preserveUserAltitude) {
        double d = cam.centerCoordinateDistance;
        if (!isfinite(d) || d < 80.0 || d > 1.5e6) {
            cam.centerCoordinateDistance = kFollowDefaultCameraDistanceM;
        }
    } else {
        cam.centerCoordinateDistance = kFollowDefaultCameraDistanceM;
    }
    if (self.followHeadingLockPausedByUserGesture) {
        cam.heading = 0.0;
    } else if (headingOrNAN == headingOrNAN) {
        cam.heading = OTNormalizeHeadingDegrees(headingOrNAN);
    }
    // else: NAN (stationary / no new heading) — keep `cam.heading` from the camera copy.
    [self.mapView setCamera:cam animated:YES];
}

- (void)liveFriendLocationUpdate:(NSNotification *)note {
    NSString *topic = note.userInfo[@"topic"];
    double lat = [note.userInfo[@"lat"] doubleValue];
    double lon = [note.userInfo[@"lon"] doubleValue];
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(lat, lon);
    if (!CLLocationCoordinate2DIsValid(coord) || (lat == 0.0 && lon == 0.0)) return;

    // Smooth-animate the marker via CADisplayLink; no remove/readd, live track polyline is unaffected.
    NSTimeInterval tst = [note.userInfo[@"tst"] doubleValue];
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
                    VCSyncFriendCalloutSpeed(fv, friend, velNum);
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
    NSTimeInterval tstSec = tst;
    if (tstSec <= 0.0) {
        tstSec = [[NSDate date] timeIntervalSince1970];
    }
    [self.liveTrackPointUnixByTopic[topic] addObject:@(tstSec)];

    DDLogVerbose(@"[ViewController] live track for %@ now has %lu points", topic, (unsigned long)self.liveTrackPoints[topic].count);

    // Only update the visible overlay for the currently selected/followed friend.
    Friend *selected = self.selectedFriend;
    if (!selected || ![selected.topic isEqualToString:topic]) {
        return;
    }
    [self rebuildLiveTrackForTopic:topic];
    // Center map on the followed friend; rotate course-up when moving (unless user panned).
    if (CLLocationCoordinate2DIsValid(coord)) {
        NSValue *prevBox = self.followMapPrevCoordByTopic[topic];
        CLLocationCoordinate2D prev = kCLLocationCoordinate2DInvalid;
        if (prevBox) {
            prev = [prevBox MKCoordinateValue];
        }
        double heading = OTEffectiveFollowMapHeading(note.userInfo, coord, &prev);
        [self.followMapPrevCoordByTopic setObject:[NSValue valueWithMKCoordinate:prev] forKey:topic];

        if (self.followEnabled) {
            [self applyFollow3DCameraToCoordinate:coord
                                          heading:heading
                               preserveUserAltitude:YES];
        }
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
