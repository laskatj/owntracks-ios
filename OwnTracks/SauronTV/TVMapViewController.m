//
//  TVMapViewController.m
//  SauronTV
//
//  Full-screen interactive MKMapView.
//  Friend pins are driven by TVFriendStore notifications.
//  TVFriendsViewController calls -selectFriendByTopic: to zoom and follow.
//

#import "TVMapViewController.h"
#import "TVFriendStore.h"
#import "TVHardcodedConfig.h"
#import "TVRecorderOAuthClient.h"
#import "TVRecorderTokenStore.h"
#import "SmoothMarkerAnimator.h"
#import <CoreLocation/CoreLocation.h>
#import <CocoaLumberjack/CocoaLumberjack.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

static NSString * const kPinId = @"FriendPin";
/// Same notification name as iOS OwnTracksAppDelegate / TVAppDelegate.
static NSString * const kOTLiveFriendLocationNotification = @"OTLiveFriendLocation";

// Carries the MQTT topic on the annotation so viewForAnnotation: can look up the image.
@interface TVFriendAnnotation : MKPointAnnotation
@property (copy, nonatomic) NSString *topic;
@end
@implementation TVFriendAnnotation @end


// MKMapView subclass.
//
// Zoom routing on tvOS:
//   Siri Remote touchpad swipes often arrive as UIFocusSystem heading events, not only UIPress.
//   UITabBarController still shows the tab bar (so Menu can return focus to tabs); competing
//   window/layout gesture recognizers are wired in viewDidAppear: to require swipeUpGR to fail
//   first. UISwipeGestureRecognizers on this view handle Up/Down when interceptUpDown is YES.
//   Down swipes also arrive via shouldUpdateFocusInContext: as a belt-and-suspenders path.
@interface TVInteractiveMapView : MKMapView <UIGestureRecognizerDelegate>
@property (nonatomic) BOOL interceptUpDown;
@property (copy, nonatomic, nullable) void (^onZoom)(BOOL zoomIn);
@property (copy, nonatomic, nullable) void (^onSelect)(void);
@property (strong, nonatomic) UISwipeGestureRecognizer *swipeUpGR;
@property (strong, nonatomic) UISwipeGestureRecognizer *swipeDownGR;
@end

@implementation TVInteractiveMapView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        UISwipeGestureRecognizer *up = [[UISwipeGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleSwipeUp)];
        up.direction = UISwipeGestureRecognizerDirectionUp;
        up.enabled   = NO;
        up.delegate  = self;
        [self addGestureRecognizer:up];
        self.swipeUpGR = up;

        UISwipeGestureRecognizer *down = [[UISwipeGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleSwipeDown)];
        down.direction = UISwipeGestureRecognizerDirectionDown;
        down.enabled   = NO;
        down.delegate  = self;
        [self addGestureRecognizer:down];
        self.swipeDownGR = down;
    }
    return self;
}

- (void)handleSwipeUp   {
    NSLog(@"[zoomfix] swipeUpGR RECOGNIZED → zoom in");
    if (self.onZoom) self.onZoom(YES);
}
- (void)handleSwipeDown {
    NSLog(@"[zoomfix] swipeDownGR RECOGNIZED → zoom out");
    if (self.onZoom) self.onZoom(NO);
}

// Log when our GRs are asked to begin — if this doesn't fire, touches never reached us.
// MKMapView may set this view as delegate for its own recognizers (e.g. UITapGestureRecognizer);
// only UISwipeGestureRecognizer responds to -direction (Play/Pause can hit the tap path).
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gr {
    long dir = -1;
    if ([gr isKindOfClass:[UISwipeGestureRecognizer class]]) {
        dir = (long)[(UISwipeGestureRecognizer *)gr direction];
    }
    NSLog(@"[zoomfix] gestureRecognizerShouldBegin: %@ dir=%ld enabled=%d",
          NSStringFromClass([gr class]), dir, gr.enabled);
    return YES;
}

// Log when another GR wants to run alongside ours — a YES here means we might
// both fire; a NO from the other side means ours gets cancelled.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    NSLog(@"[zoomfix] simultaneouslyWith: our=%@ other=%@ (owner=%@)",
          NSStringFromClass([gr class]),
          NSStringFromClass([other class]),
          [other.view class]);
    return YES;  // allow simultaneous — don't let others cancel us
}

// Log if something requires our GR to fail before it can recognise.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr
    shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    NSLog(@"[zoomfix] shouldBeRequiredToFailBy: our=%@ other=%@ (owner=%@)",
          NSStringFromClass([gr class]),
          NSStringFromClass([other class]),
          [other.view class]);
    return NO;
}

- (void)setInterceptUpDown:(BOOL)interceptUpDown {
    _interceptUpDown         = interceptUpDown;
    self.scrollEnabled       = !interceptUpDown;
    self.swipeUpGR.enabled   = interceptUpDown;
    self.swipeDownGR.enabled = interceptUpDown;
    // Dump all current gesture recognizers on this view so we can see what's competing.
    NSLog(@"[zoomfix] setInterceptUpDown=%d — all GRs on mapView:", interceptUpDown);
    for (UIGestureRecognizer *gr in self.gestureRecognizers) {
        NSLog(@"[zoomfix]   %@ enabled=%d state=%ld",
              NSStringFromClass([gr class]), gr.enabled, (long)gr.state);
    }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *p in presses) {
        NSLog(@"[zoomfix] pressesBegan type=%ld interceptUpDown=%d", (long)p.type, self.interceptUpDown);
    }
    if (self.interceptUpDown) {
        BOOL handled = NO;
        for (UIPress *p in presses) {
            if (p.type == UIPressTypeUpArrow   && self.onZoom)   { self.onZoom(YES); handled = YES; }
            if (p.type == UIPressTypeDownArrow && self.onZoom)   { self.onZoom(NO);  handled = YES; }
            if (p.type == UIPressTypeSelect    && self.onSelect) { self.onSelect();  handled = YES; }
        }
        if (handled) return;
    }
    [super pressesBegan:presses withEvent:event];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    NSLog(@"[zoomfix] touchesBegan count=%lu interceptUpDown=%d", (unsigned long)touches.count, self.interceptUpDown);
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    NSLog(@"[zoomfix] touchesEnded count=%lu", (unsigned long)touches.count);
    [super touchesEnded:touches withEvent:event];
}

// Log ALL focus heading events so we can see if up swipe arrives here at all.
- (BOOL)shouldUpdateFocusInContext:(UIFocusUpdateContext *)context {
    NSLog(@"[zoomfix] shouldUpdateFocusInContext heading=%lu interceptUpDown=%d next=%@",
          (unsigned long)context.focusHeading, self.interceptUpDown,
          NSStringFromClass([context.nextFocusedItem class]));
    if (self.interceptUpDown) {
        UIFocusHeading h = context.focusHeading;
        if (h & UIFocusHeadingUp)   { NSLog(@"[zoomfix] UP heading → zoom in");  if (self.onZoom) self.onZoom(YES); return NO; }
        if (h & UIFocusHeadingDown) { NSLog(@"[zoomfix] DOWN heading → zoom out"); if (self.onZoom) self.onZoom(NO);  return NO; }
    }
    return [super shouldUpdateFocusInContext:context];
}

@end


@interface TVMapViewController ()
@property (strong, nonatomic) TVInteractiveMapView *mapView;
@property (strong, nonatomic) NSMutableDictionary<NSString *, TVFriendAnnotation *> *annotations;
@property (strong, nonatomic) NSMutableDictionary<NSString *, SmoothMarkerAnimator *> *animators;
@property (copy, nonatomic, nullable) NSString *selectedTopic;
@property (assign, nonatomic) CFTimeInterval trackingStartTime;
@property (strong, nonatomic, nullable) CADisplayLink *followLink;
@property (assign, nonatomic) NSUInteger followTickCount;
/// Throttles follow pans: 60Hz setRegion + per-frame SmoothMarkerAnimator updates stress MapKit Metal.
@property (assign, nonatomic) CFAbsoluteTime lastFollowPanTime;
@property (strong, nonatomic) UIView      *trackingHUD;
@property (strong, nonatomic) UIImageView *hudPhotoView;
@property (strong, nonatomic) UILabel     *hudNameLabel;

/// Live route cache (same pattern as iOS ViewController).
@property (strong, nonatomic) NSMutableDictionary<NSString *, NSMutableArray<NSValue *> *> *liveTrackPoints;
@property (strong, nonatomic) NSMutableDictionary<NSString *, MKPolyline *> *liveTrackPolylines;
@property (strong, nonatomic) NSMutableSet<NSString *> *routeFetchedTopics;
@property (strong, nonatomic) NSMutableSet<NSString *> *pendingRouteTopics;
@end

@implementation TVMapViewController

#pragma mark - View setup

- (void)loadView {
    self.mapView = [[TVInteractiveMapView alloc] initWithFrame:CGRectZero];
    self.mapView.delegate = self;
    self.mapView.mapType  = MKMapTypeStandard;
    self.mapView.showsUserLocation = NO;
    self.view = self.mapView;

    __weak typeof(self) weak = self;
    self.mapView.onZoom = ^(BOOL zoomIn) { [weak adjustZoom:zoomIn]; };
    self.mapView.onSelect = ^{
        if (!weak) return;
        if (CACurrentMediaTime() - weak.trackingStartTime > 0.5) {
            [weak selectFriendByTopic:nil];
        } else {
            DDLogInfo(@"[TVMapViewController] Select ignored (%.3fs after start)",
                      CACurrentMediaTime() - weak.trackingStartTime);
        }
    };
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.annotations = [NSMutableDictionary dictionary];
    self.animators   = [NSMutableDictionary dictionary];
    self.liveTrackPoints    = [NSMutableDictionary dictionary];
    self.liveTrackPolylines = [NSMutableDictionary dictionary];
    self.routeFetchedTopics = [NSMutableSet set];
    self.pendingRouteTopics = [NSMutableSet set];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(storeUpdated:)
               name:TVFriendStoreDidUpdateNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(liveFriendLocationUpdated:)
               name:kOTLiveFriendLocationNotification
             object:nil];

    [self buildTrackingHUD];

    DDLogInfo(@"[TVMapViewController] viewDidLoad");
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // One-time setup: make competing window/container gesture recognizers
    // require our swipeUpGR to fail before they can recognize.
    // This gives our UP swipe priority over _UIFocusEnginePanGestureRecognizer
    // (which normally intercepts ALL UP swipes for focus navigation before
    // touches even reach our view). Since swipeUpGR.enabled=NO when not
    // tracking, it instantly "fails" and the system GRs proceed normally.
    static BOOL gestureRequirementsSetUp = NO;
    if (!gestureRequirementsSetUp && self.view.window) {
        gestureRequirementsSetUp = YES;
        // UIWindow-level GRs (includes _UIFocusEnginePanGestureRecognizer)
        for (UIGestureRecognizer *gr in self.view.window.gestureRecognizers) {
            NSString *name = NSStringFromClass([gr class]);
            NSLog(@"[zoomfix] window GR: %@", name);
            if ([name containsString:@"Focus"] || [name containsString:@"TabBar"]) {
                [gr requireGestureRecognizerToFail:self.mapView.swipeUpGR];
                NSLog(@"[zoomfix] LINKED: %@ must wait for swipeUpGR to fail first", name);
            }
        }
        // UILayoutContainerView-level GRs (includes _UITabBarTouchDetectionGestureRecognizer)
        UIView *v = self.view.superview;
        while (v) {
            NSString *viewName = NSStringFromClass([v class]);
            if ([viewName containsString:@"LayoutContainer"] || [viewName containsString:@"TabBar"]) {
                for (UIGestureRecognizer *gr in v.gestureRecognizers) {
                    NSString *name = NSStringFromClass([gr class]);
                    [gr requireGestureRecognizerToFail:self.mapView.swipeUpGR];
                    NSLog(@"[zoomfix] LINKED: %@ (on %@) must wait for swipeUpGR to fail first", name, viewName);
                }
            }
            v = v.superview;
        }
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopFollowLink];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopFollowLink];
}

#pragma mark - Tracking HUD

- (void)buildTrackingHUD {
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    blurView.alpha = 0;
    blurView.userInteractionEnabled = NO;
    self.trackingHUD = blurView;
    [self.view addSubview:blurView];

    [NSLayoutConstraint activateConstraints:@[
        [blurView.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [blurView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [blurView.bottomAnchor   constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [blurView.heightAnchor   constraintEqualToConstant:90],
    ]];

    UIView *content = blurView.contentView;

    UIImageView *photo = [[UIImageView alloc] init];
    photo.translatesAutoresizingMaskIntoConstraints = NO;
    photo.layer.cornerRadius = 24;
    photo.clipsToBounds      = YES;
    photo.contentMode        = UIViewContentModeScaleAspectFill;
    [content addSubview:photo];
    self.hudPhotoView = photo;

    UILabel *nameLabel = [[UILabel alloc] init];
    nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    nameLabel.textColor = UIColor.whiteColor;
    nameLabel.font      = [UIFont systemFontOfSize:28 weight:UIFontWeightMedium];
    [content addSubview:nameLabel];
    self.hudNameLabel = nameLabel;

    UILabel *hintLabel = [[UILabel alloc] init];
    hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    hintLabel.textColor     = [UIColor colorWithWhite:0.65 alpha:1];
    hintLabel.font          = [UIFont systemFontOfSize:22 weight:UIFontWeightRegular];
    hintLabel.text          = @"↑ Zoom In   ↓ Zoom Out   ◉ Stop";
    hintLabel.textAlignment = NSTextAlignmentRight;
    [content addSubview:hintLabel];

    const CGFloat pad = 40, gap = 16;
    [NSLayoutConstraint activateConstraints:@[
        [photo.leadingAnchor  constraintEqualToAnchor:content.leadingAnchor constant:pad],
        [photo.centerYAnchor  constraintEqualToAnchor:content.centerYAnchor],
        [photo.widthAnchor    constraintEqualToConstant:48],
        [photo.heightAnchor   constraintEqualToConstant:48],

        [nameLabel.leadingAnchor  constraintEqualToAnchor:photo.trailingAnchor constant:gap],
        [nameLabel.centerYAnchor  constraintEqualToAnchor:content.centerYAnchor],

        [hintLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-pad],
        [hintLabel.centerYAnchor  constraintEqualToAnchor:content.centerYAnchor],
        [hintLabel.leadingAnchor  constraintGreaterThanOrEqualToAnchor:nameLabel.trailingAnchor constant:gap],
    ]];
}

- (void)showTrackingHUDForTopic:(NSString *)topic {
    TVFriendStore *store    = [TVFriendStore shared];
    self.hudNameLabel.text  = store.friendLabels[topic] ?: [topic lastPathComponent];
    self.hudPhotoView.image = [store imageForTopic:topic];

    self.trackingHUD.transform = CGAffineTransformMakeTranslation(0, 20);
    [UIView animateWithDuration:0.3
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.trackingHUD.alpha     = 1;
        self.trackingHUD.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)hideTrackingHUD {
    [UIView animateWithDuration:0.2
                          delay:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{ self.trackingHUD.alpha = 0; }
                     completion:nil];
}

#pragma mark - Smooth map following (CADisplayLink)

- (void)startFollowLink {
    [self stopFollowLink];
    self.followTickCount = 0;
    self.lastFollowPanTime = 0;
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self
                                                      selector:@selector(followTick:)];
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    self.followLink = link;
}

- (void)stopFollowLink {
    [self.followLink invalidate];
    self.followLink = nil;
}

- (void)followTick:(CADisplayLink *)link {
    if (!self.selectedTopic) { [self stopFollowLink]; return; }
    TVFriendAnnotation *ann = self.annotations[self.selectedTopic];
    if (!ann) return;

    CLLocationCoordinate2D target = ann.coordinate;
    if (!CLLocationCoordinate2DIsValid(target)) return;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    const CFTimeInterval kFollowPanMinInterval = 0.2;
    if (now - self.lastFollowPanTime < kFollowPanMinInterval) return;

    CLLocation *mapCtr = [[CLLocation alloc] initWithLatitude:self.mapView.region.center.latitude
                                                    longitude:self.mapView.region.center.longitude];
    CLLocation *pinLoc = [[CLLocation alloc] initWithLatitude:target.latitude longitude:target.longitude];
    CLLocationDistance driftM = [mapCtr distanceFromLocation:pinLoc];
    const CLLocationDistance kFollowPanMinDriftM = 5.0;
    if (driftM < kFollowPanMinDriftM) {
        self.lastFollowPanTime = now;
        return;
    }

    self.lastFollowPanTime = now;
    MKCoordinateRegion region = self.mapView.region;
    region.center = target;
    [self.mapView setRegion:region animated:NO];
}

#pragma mark - Live route (iOS ViewController pattern)

- (void)removeVisibleRouteAndPendingForTopic:(NSString *)topic {
    MKPolyline *liveTrack = self.liveTrackPolylines[topic];
    if (liveTrack) {
        [self.mapView removeOverlay:liveTrack];
        [self.liveTrackPolylines removeObjectForKey:topic];
    }
    [self.pendingRouteTopics removeObject:topic];
}

/// Derives Recorder API user and device from MQTT topic `owntracks/{user}/{device...}`.
- (void)routeUser:(NSString * _Nullable * _Nonnull)outUser
           device:(NSString * _Nullable * _Nonnull)outDevice
         fromTopic:(NSString *)topic {
    *outUser = nil;
    *outDevice = nil;
    NSArray<NSString *> *parts = [topic componentsSeparatedByString:@"/"];
    if (parts.count >= 3) {
        *outUser = parts[1];
        *outDevice = [[parts subarrayWithRange:NSMakeRange(2, parts.count - 2)]
                      componentsJoinedByString:@"/"];
    }
}

- (void)rebuildLiveTrackForTopic:(NSString *)topic {
    NSArray<NSValue *> *points = self.liveTrackPoints[topic];
    if (points.count < 2) return;
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
}

- (void)liveFriendLocationUpdated:(NSNotification *)note {
    NSString *topic = note.userInfo[@"topic"];
    if (![[TVFriendStore shared] isBaseTopicAllowed:topic]) {
        return;
    }
    double lat = [note.userInfo[@"lat"] doubleValue];
    double lon = [note.userInfo[@"lon"] doubleValue];
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(lat, lon);
    if (!topic.length || !CLLocationCoordinate2DIsValid(coord) || (lat == 0.0 && lon == 0.0)) return;

    if (!self.liveTrackPoints[topic]) {
        self.liveTrackPoints[topic] = [NSMutableArray array];
    }
    [self.liveTrackPoints[topic] addObject:[NSValue valueWithMKCoordinate:coord]];

    if (self.selectedTopic.length && [self.selectedTopic isEqualToString:topic]) {
        [self rebuildLiveTrackForTopic:topic];
    }
}

- (void)fetchRouteForTopic:(NSString *)topic {
    NSString *routeUser = nil;
    NSString *routeDevice = nil;
    [self routeUser:&routeUser device:&routeDevice fromTopic:topic];

    DDLogInfo(@"[TVMapViewController] route fetch: topic=%@ user=%@ device=%@",
              topic, routeUser ?: @"(nil)", routeDevice ?: @"(nil)");

    if (!routeUser.length || !routeDevice.length) {
        DDLogInfo(@"[TVMapViewController] route fetch: cannot derive user/device — cached MQTT track only");
        [self rebuildLiveTrackForTopic:topic];
        return;
    }

    if ([self.pendingRouteTopics containsObject:topic]) return;

    NSURL *origin = [NSURL URLWithString:kTVWebAppOriginURL];
    if (!origin || !kTVWebAppOriginURL.length) {
        DDLogInfo(@"[TVMapViewController] route fetch: no Recorder origin URL — MQTT track only");
        [self rebuildLiveTrackForTopic:topic];
        return;
    }

    [self.pendingRouteTopics addObject:topic];

    __weak typeof(self) weak = self;
    UIViewController *pvc = self.tabBarController;
    if (!pvc) pvc = self.view.window.rootViewController;

    [[TVRecorderOAuthClient shared] ensureValidAccessTokenPresentingSignInFrom:pvc
                                                                      completion:^(NSString *token, NSError *err) {
        __strong typeof(weak) sself = weak;
        if (!sself) return;
        if (![sself.pendingRouteTopics containsObject:topic]) return;
        if (!token.length) {
            DDLogInfo(@"[TVMapViewController] route fetch: no bearer token — MQTT only (%@)",
                      err.localizedDescription ?: @"not configured");
            [sself.pendingRouteTopics removeObject:topic];
            [sself rebuildLiveTrackForTopic:topic];
            return;
        }
        [sself performRouteGETForTopic:topic
                             routeUser:routeUser
                           routeDevice:routeDevice
                                origin:origin
                           accessToken:token
                            is401Retry:NO];
    }];
}

- (void)applyRouteHistoryJSONToTopic:(NSString *)topic data:(NSData *)data {
    NSError *jsonError = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (jsonError) {
        DDLogWarn(@"[TVMapViewController] route JSON error %@: %@", topic, jsonError.localizedDescription);
    }
    NSArray *points = nil;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        id p = ((NSDictionary *)obj)[@"points"];
        if ([p isKindOfClass:[NSArray class]]) {
            points = (NSArray *)p;
        }
    }

    if (!points.count) {
        DDLogInfo(@"[TVMapViewController] route fetch: API points count=0 for %@", topic);
        [self rebuildLiveTrackForTopic:topic];
        return;
    }

    CLLocationCoordinate2D *coords = malloc(points.count * sizeof(CLLocationCoordinate2D));
    if (!coords) {
        [self rebuildLiveTrackForTopic:topic];
        return;
    }
    NSUInteger count = 0;
    for (id pt in points) {
        if (![pt isKindOfClass:[NSDictionary class]]) continue;
        id latObj = ((NSDictionary *)pt)[@"latitude"];
        id lonObj = ((NSDictionary *)pt)[@"longitude"];
        if (![latObj isKindOfClass:[NSNumber class]] || ![lonObj isKindOfClass:[NSNumber class]]) continue;
        double plat = [(NSNumber *)latObj doubleValue];
        double plon = [(NSNumber *)lonObj doubleValue];
        if (plat == 0.0 && plon == 0.0) continue;
        coords[count++] = CLLocationCoordinate2DMake(plat, plon);
    }

    if (count == 0) {
        DDLogInfo(@"[TVMapViewController] route fetch: API points count=%lu usable=0 for %@",
                  (unsigned long)points.count, topic);
        free(coords);
        [self rebuildLiveTrackForTopic:topic];
        return;
    }

    NSMutableArray<NSValue *> *historical = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        [historical addObject:[NSValue valueWithMKCoordinate:coords[i]]];
    }
    free(coords);

    NSMutableArray<NSValue *> *existing = self.liveTrackPoints[topic] ?: [NSMutableArray array];
    NSUInteger mqttBefore = existing.count;
    [historical addObjectsFromArray:existing];
    self.liveTrackPoints[topic] = historical;
    [self.routeFetchedTopics addObject:topic];
    [self rebuildLiveTrackForTopic:topic];
    DDLogInfo(@"[TVMapViewController] route fetch: API points count=%lu usable=%lu MQTT buffered=%lu merged total=%lu for %@",
              (unsigned long)points.count, (unsigned long)count, (unsigned long)mqttBefore,
              (unsigned long)historical.count, topic);
}

- (void)performRouteGETForTopic:(NSString *)topic
                      routeUser:(NSString *)routeUser
                    routeDevice:(NSString *)routeDevice
                         origin:(NSURL *)origin
                    accessToken:(NSString *)token
                     is401Retry:(BOOL)is401Retry {
    NSInteger endTs = (NSInteger)[[NSDate date] timeIntervalSince1970];
    NSInteger startTs = endTs - 1 * 24 * 60 * 60;

    // Do not pre-encode: NSURLComponents encodes path once when building .URL; pre-encoding
    // produces %2520 for spaces (double-encoded).
    NSString *path = [NSString stringWithFormat:@"/api/location/history/%@/%@/route", routeUser, routeDevice];

    NSURLComponents *components = [NSURLComponents componentsWithURL:origin resolvingAgainstBaseURL:NO];
    components.path = path;
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"start" value:@(startTs).stringValue],
        [NSURLQueryItem queryItemWithName:@"end" value:@(endTs).stringValue],
    ];
    NSURL *routeURL = components.URL;
    if (!routeURL) {
        DDLogWarn(@"[TVMapViewController] route fetch: bad URL for %@", topic);
        [self.pendingRouteTopics removeObject:topic];
        [self rebuildLiveTrackForTopic:topic];
        return;
    }

    DDLogInfo(@"[TVMapViewController] route fetch: GET %@", routeURL);

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:routeURL];
    [req setHTTPMethod:@"GET"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];

    __weak typeof(self) weak = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weak) sself = weak;
                if (!sself) return;
                if (![sself.pendingRouteTopics containsObject:topic]) return;

                NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]]
                    ? (NSHTTPURLResponse *)response : nil;
                NSInteger status = http ? http.statusCode : 0;

                if (status == 401 && !is401Retry && !kTVWebAppBearerToken.length
                        && [TVRecorderTokenStore refreshToken].length) {
                    [[TVRecorderOAuthClient shared] refreshAccessTokenWithCompletion:^(NSString *newTok, NSError *re) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            __strong typeof(weak) inner = weak;
                            if (!inner) return;
                            if (![inner.pendingRouteTopics containsObject:topic]) return;
                            if (newTok.length) {
                                [inner performRouteGETForTopic:topic
                                                   routeUser:routeUser
                                                 routeDevice:routeDevice
                                                      origin:origin
                                                 accessToken:newTok
                                                  is401Retry:YES];
                            } else {
                                DDLogInfo(@"[TVMapViewController] route fetch: refresh failed after 401 — %@", re);
                                [inner.pendingRouteTopics removeObject:topic];
                                if ([inner.selectedTopic isEqualToString:topic]) {
                                    [inner rebuildLiveTrackForTopic:topic];
                                }
                            }
                        });
                    }];
                    return;
                }

                [sself.pendingRouteTopics removeObject:topic];

                if (![sself.selectedTopic isEqualToString:topic]) {
                    DDLogInfo(@"[TVMapViewController] route fetch: discard (deselected) %@", topic);
                    return;
                }

                if (error || !data.length) {
                    DDLogInfo(@"[TVMapViewController] route fetch failed %@: %@", topic, error.localizedDescription ?: @"no data");
                    [sself rebuildLiveTrackForTopic:topic];
                    return;
                }

                [sself applyRouteHistoryJSONToTopic:topic data:data];
            });
        }];
    [task resume];
}

#pragma mark - TVFriendStore updates

- (void)storeUpdated:(NSNotification *)note {
    NSString *topic  = note.userInfo[@"topic"];
    NSString *change = note.userInfo[@"change"];

    TVFriendStore *store = [TVFriendStore shared];

    if ([change isEqualToString:@"allowlist"]) {
        for (NSString *t in [self.annotations copy]) {
            if (![store.friendTopics containsObject:t]) {
                TVFriendAnnotation *gone = self.annotations[t];
                if (gone) {
                    [self.mapView removeAnnotation:gone];
                }
                [self.annotations removeObjectForKey:t];
                [self.animators removeObjectForKey:t];
                [self removeVisibleRouteAndPendingForTopic:t];
                [self.liveTrackPoints removeObjectForKey:t];
                MKPolyline *pl = self.liveTrackPolylines[t];
                if (pl) {
                    [self.mapView removeOverlay:pl];
                }
                [self.liveTrackPolylines removeObjectForKey:t];
                [self.routeFetchedTopics removeObject:t];
            }
        }
        for (NSString *t in store.friendTopics) {
            CLLocationCoordinate2D coord = [self coordForTopic:t store:store];
            if (!CLLocationCoordinate2DIsValid(coord) || (coord.latitude == 0.0 && coord.longitude == 0.0)) {
                continue;
            }
            TVFriendAnnotation *ann = self.annotations[t];
            if (!ann) {
                ann = [[TVFriendAnnotation alloc] init];
                ann.topic      = t;
                ann.coordinate = coord;
                ann.title      = store.friendLabels[t] ?: [t lastPathComponent];
                ann.subtitle   = store.friendTimes[t];
                self.annotations[t] = ann;
                [self.mapView addAnnotation:ann];
                DDLogInfo(@"[TVMapViewController] allowlist pin: %@", t);
            } else {
                ann.coordinate = coord;
                ann.title      = store.friendLabels[t] ?: [t lastPathComponent];
                ann.subtitle   = store.friendTimes[t];
            }
        }
        if (self.selectedTopic.length && ![store.friendTopics containsObject:self.selectedTopic]) {
            [self selectFriendByTopic:nil];
        }
        if (!self.selectedTopic) {
            [self zoomToFitAllAnnotations];
        }
        return;
    }

    if ([change isEqualToString:@"new"]) {
        CLLocationCoordinate2D coord = [self coordForTopic:topic store:store];
        TVFriendAnnotation *ann = [[TVFriendAnnotation alloc] init];
        ann.topic      = topic;
        ann.coordinate = coord;
        ann.title      = store.friendLabels[topic] ?: [topic lastPathComponent];
        ann.subtitle   = store.friendTimes[topic];
        self.annotations[topic] = ann;
        [self.mapView addAnnotation:ann];
        DDLogInfo(@"[TVMapViewController] new pin: %@", topic);
        if (!self.selectedTopic) [self zoomToFitAllAnnotations];

    } else if ([change isEqualToString:@"location"]) {
        CLLocationCoordinate2D coord = [self coordForTopic:topic store:store];
        TVFriendAnnotation *ann = self.annotations[topic];
        if (!ann && CLLocationCoordinate2DIsValid(coord) && !(coord.latitude == 0.0 && coord.longitude == 0.0)) {
            ann = [[TVFriendAnnotation alloc] init];
            ann.topic      = topic;
            ann.coordinate = coord;
            ann.title      = store.friendLabels[topic] ?: [topic lastPathComponent];
            ann.subtitle   = store.friendTimes[topic];
            self.annotations[topic] = ann;
            [self.mapView addAnnotation:ann];
            DDLogInfo(@"[TVMapViewController] first pin from MQTT location: %@", topic);
            if (!self.selectedTopic) {
                [self zoomToFitAllAnnotations];
            }
        } else if (ann) {
            SmoothMarkerAnimator *animator = self.animators[topic];
            if (!animator) {
                animator = [[SmoothMarkerAnimator alloc] initWithAnnotation:ann];
                self.animators[topic] = animator;
            }
            NSTimeInterval tst = [[TVFriendStore shared] rawTimestampForTopic:topic];
            [animator startOrUpdateWithLatitude:coord.latitude
                                      longitude:coord.longitude
                                      timestamp:tst];
            ann.subtitle = store.friendTimes[topic];
        }

    } else if ([change isEqualToString:@"image"] || [change isEqualToString:@"card"]) {
        TVFriendAnnotation *ann = self.annotations[topic];
        if (ann) {
            ann.title = [TVFriendStore shared].friendLabels[topic] ?: [topic lastPathComponent];
            [self.animators[topic] cancel];
            [self.animators removeObjectForKey:topic];
            [self.mapView removeAnnotation:ann];
            [self.mapView addAnnotation:ann];
        }
        if (self.selectedTopic && [topic isEqualToString:self.selectedTopic]) {
            [self showTrackingHUDForTopic:topic];
        }
    }
}

- (CLLocationCoordinate2D)coordForTopic:(NSString *)topic store:(TVFriendStore *)store {
    NSValue *val = store.friendCoords[topic];
    if (!val) return kCLLocationCoordinate2DInvalid;
    CLLocationCoordinate2D coord;
    [val getValue:&coord];
    return coord;
}

#pragma mark - Public selection API

- (void)selectFriendByTopic:(nullable NSString *)topic {
    NSString *previous = self.selectedTopic;

    if (topic) {
        if (previous.length && ![previous isEqualToString:topic]) {
            [self removeVisibleRouteAndPendingForTopic:previous];
        }
        self.selectedTopic = topic;
        self.mapView.interceptUpDown = YES;
        self.trackingStartTime = CACurrentMediaTime();
        [self showTrackingHUDForTopic:topic];
        [self zoomToFriend:topic];

        if ([self.routeFetchedTopics containsObject:topic] && self.liveTrackPoints[topic].count >= 2) {
            [self rebuildLiveTrackForTopic:topic];
        } else {
            [self fetchRouteForTopic:topic];
        }
        [self startFollowLink];
        DDLogInfo(@"[TVMapViewController] following %@", topic);
    } else {
        if (previous.length) {
            [self removeVisibleRouteAndPendingForTopic:previous];
        }
        self.selectedTopic = nil;
        self.mapView.interceptUpDown = NO;
        [self hideTrackingHUD];
        [self stopFollowLink];
        [self zoomToFitAllAnnotations];
        DDLogInfo(@"[TVMapViewController] showing all friends");
    }
}

#pragma mark - Map controls

- (void)zoomToFriend:(NSString *)topic {
    TVFriendAnnotation *ann = self.annotations[topic];
    if (!ann) return;
    MKCoordinateRegion region = MKCoordinateRegionMakeWithDistance(ann.coordinate, 500, 500);
    [self.mapView setRegion:region animated:NO];
}

- (void)zoomToFitAllAnnotations {
    NSArray<id<MKAnnotation>> *all = self.mapView.annotations;
    if (all.count == 0) return;
    MKMapRect rect = MKMapRectNull;
    for (id<MKAnnotation> a in all) {
        MKMapPoint pt = MKMapPointForCoordinate(a.coordinate);
        rect = MKMapRectUnion(rect, MKMapRectMake(pt.x, pt.y, 0, 0));
    }
    [self.mapView setVisibleMapRect:rect
                        edgePadding:UIEdgeInsetsMake(80, 80, 80, 80)
                           animated:YES];
}

- (void)adjustZoom:(BOOL)zoomIn {
    MKCoordinateRegion region = self.mapView.region;
    double factor = zoomIn ? 0.5 : 2.0;
    region.span.latitudeDelta  = MAX(0.001, MIN(region.span.latitudeDelta  * factor, 90.0));
    region.span.longitudeDelta = MAX(0.001, MIN(region.span.longitudeDelta * factor, 180.0));
    [self.mapView setRegion:region animated:YES];
}

#pragma mark - MKMapViewDelegate

- (MKAnnotationView *)mapView:(MKMapView *)mapView
            viewForAnnotation:(id<MKAnnotation>)annotation {
    if ([annotation isKindOfClass:[MKUserLocation class]]) return nil;

    MKAnnotationView *view =
        [mapView dequeueReusableAnnotationViewWithIdentifier:kPinId];
    if (!view) {
        view = [[MKAnnotationView alloc] initWithAnnotation:annotation
                                            reuseIdentifier:kPinId];
        view.canShowCallout = YES;
    } else {
        view.annotation = annotation;
    }

    if ([annotation isKindOfClass:[TVFriendAnnotation class]]) {
        NSString *topic = ((TVFriendAnnotation *)annotation).topic;
        view.image = [[TVFriendStore shared] imageForTopic:topic];
    } else {
        view.image = [[TVFriendStore shared] imageForTopic:@"__unknown__"];
    }

    return view;
}

- (MKOverlayRenderer *)mapView:(MKMapView *)mapView rendererForOverlay:(id<MKOverlay>)overlay {
    if (![overlay isKindOfClass:[MKPolyline class]]) {
        return nil;
    }
    MKPolylineRenderer *renderer = [[MKPolylineRenderer alloc] initWithPolyline:(MKPolyline *)overlay];
    renderer.lineWidth   = 3;
    renderer.strokeColor = [UIColor colorNamed:@"trackColor"];
    return renderer;
}

@end
