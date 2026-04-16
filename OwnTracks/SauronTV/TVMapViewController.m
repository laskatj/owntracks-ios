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
#import "SmoothMarkerAnimator.h"
#import <CocoaLumberjack/CocoaLumberjack.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

static NSString * const kPinId = @"FriendPin";

// Carries the MQTT topic on the annotation so viewForAnnotation: can look up the image.
@interface TVFriendAnnotation : MKPointAnnotation
@property (copy, nonatomic) NSString *topic;
@end
@implementation TVFriendAnnotation @end


// MKMapView subclass.
//
// Zoom routing on tvOS:
//   Siri Remote touchpad swipes arrive as UIFocusSystem heading events, not UIPress
//   events. Up swipes were intercepted by UITabBarController before reaching us.
//   Fix: hide the tab bar when tracking starts (removes its gesture recognizers entirely),
//   and install UISwipeGestureRecognizers on this view for Up/Down.
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
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gr {
    NSLog(@"[zoomfix] gestureRecognizerShouldBegin: %@ dir=%ld enabled=%d",
          NSStringFromClass([gr class]),
          (long)[(UISwipeGestureRecognizer *)gr direction],
          gr.enabled);
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
@property (strong, nonatomic) UIView      *trackingHUD;
@property (strong, nonatomic) UIImageView *hudPhotoView;
@property (strong, nonatomic) UILabel     *hudNameLabel;
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

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(storeUpdated:)
               name:TVFriendStoreDidUpdateNotification
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
    MKCoordinateRegion region = self.mapView.region;
    region.center = ann.coordinate;
    [self.mapView setRegion:region animated:NO];
}

#pragma mark - TVFriendStore updates

- (void)storeUpdated:(NSNotification *)note {
    NSString *topic  = note.userInfo[@"topic"];
    NSString *change = note.userInfo[@"change"];

    TVFriendStore *store = [TVFriendStore shared];

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
        TVFriendAnnotation *ann = self.annotations[topic];
        if (ann) {
            CLLocationCoordinate2D coord = [self coordForTopic:topic store:store];
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
    self.selectedTopic = topic;
    self.mapView.interceptUpDown = (topic != nil);
    if (topic) {
        self.trackingStartTime = CACurrentMediaTime();
        // Hide the tab bar so its system upward-swipe gesture recognizer
        // (which reveals the tab bar) cannot intercept our zoom-in swipes.
        self.tabBarController.tabBar.hidden = YES;
        [self showTrackingHUDForTopic:topic];
        [self zoomToFriend:topic];
        [self startFollowLink];
        DDLogInfo(@"[TVMapViewController] following %@", topic);
    } else {
        self.tabBarController.tabBar.hidden = NO;
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

@end
