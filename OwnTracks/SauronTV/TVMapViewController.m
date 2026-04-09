//
//  TVMapViewController.m
//  SauronTV
//
//  Full-screen map viewer for tvOS.
//  One pin per friend topic, updated live via OTLiveFriendLocation notifications.
//  Siri Remote controls map pan/zoom via MapKit's built-in focus engine support.
//

#import "TVMapViewController.h"
#import <CocoaLumberjack/CocoaLumberjack.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

// Notification name shared with OwnTracksAppDelegate (iOS) and TVAppDelegate (tvOS).
static NSString * const kOTLiveFriendLocationNotification = @"OTLiveFriendLocation";

@interface TVMapViewController ()
@property (strong, nonatomic) MKMapView *mapView;
// topic (NSString) → MKPointAnnotation
@property (strong, nonatomic) NSMutableDictionary<NSString *, MKPointAnnotation *> *annotations;
@end

@implementation TVMapViewController

- (void)loadView {
    self.mapView = [[MKMapView alloc] initWithFrame:CGRectZero];
    self.mapView.delegate = self;
    self.mapView.mapType = MKMapTypeStandard;
    self.mapView.showsUserLocation = NO;
    // tvOS Siri Remote sends focus-engine swipe events to MKMapView automatically.
    self.view = self.mapView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.annotations = [NSMutableDictionary dictionary];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(friendLocationUpdated:)
               name:kOTLiveFriendLocationNotification
             object:nil];

    // Play/Pause tap → zoom in
    UITapGestureRecognizer *zoomInGR = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(zoomIn)];
    zoomInGR.allowedPressTypes = @[@(UIPressTypePlayPause)];
    [self.view addGestureRecognizer:zoomInGR];

    // Play/Pause long-press → zoom out
    UILongPressGestureRecognizer *zoomOutGR = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(zoomOut:)];
    zoomOutGR.allowedPressTypes = @[@(UIPressTypePlayPause)];
    [self.view addGestureRecognizer:zoomOutGR];

    DDLogInfo(@"[TVMapViewController] viewDidLoad — waiting for OTLiveFriendLocation");
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - OTLiveFriendLocation

- (void)friendLocationUpdated:(NSNotification *)note {
    NSDictionary *info = note.userInfo;
    NSString *topic = info[@"topic"];
    double   lat   = [info[@"lat"] doubleValue];
    double   lon   = [info[@"lon"] doubleValue];
    NSString *label = info[@"label"] ?: [topic lastPathComponent];

    if (!topic.length) return;

    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(lat, lon);

    MKPointAnnotation *ann = self.annotations[topic];
    if (ann) {
        // Animate the pin to its new position.
        ann.coordinate = coord;
        ann.subtitle   = [self timestampStringFromInfo:info];
    } else {
        ann = [[MKPointAnnotation alloc] init];
        ann.coordinate = coord;
        ann.title      = label;
        ann.subtitle   = [self timestampStringFromInfo:info];
        self.annotations[topic] = ann;
        [self.mapView addAnnotation:ann];
        DDLogInfo(@"[TVMapViewController] new friend pin: %@ at %.5f,%.5f", topic, lat, lon);
        [self zoomToFitAllAnnotations];
    }
}

- (NSString *)timestampStringFromInfo:(NSDictionary *)info {
    NSNumber *tst = info[@"tst"];
    if (!tst || tst.doubleValue == 0) return nil;
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:tst.doubleValue];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateStyle = NSDateFormatterNoStyle;
    fmt.timeStyle = NSDateFormatterShortStyle;
    return [fmt stringFromDate:date];
}

- (void)zoomIn {
    MKCoordinateRegion region = self.mapView.region;
    region.span.latitudeDelta  /= 2.0;
    region.span.longitudeDelta /= 2.0;
    [self.mapView setRegion:region animated:YES];
}

- (void)zoomOut:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    MKCoordinateRegion region = self.mapView.region;
    region.span.latitudeDelta  = MIN(region.span.latitudeDelta  * 2.0, 170.0);
    region.span.longitudeDelta = MIN(region.span.longitudeDelta * 2.0, 360.0);
    [self.mapView setRegion:region animated:YES];
}

- (void)zoomToFitAllAnnotations {
    NSArray<id<MKAnnotation>> *all = self.mapView.annotations;
    if (all.count == 0) return;

    MKMapRect rect = MKMapRectNull;
    for (id<MKAnnotation> a in all) {
        MKMapPoint pt = MKMapPointForCoordinate(a.coordinate);
        rect = MKMapRectUnion(rect, MKMapRectMake(pt.x, pt.y, 0, 0));
    }

    UIEdgeInsets padding = UIEdgeInsetsMake(80, 80, 80, 80);
    [self.mapView setVisibleMapRect:rect edgePadding:padding animated:YES];
}

#pragma mark - MKMapViewDelegate

- (MKAnnotationView *)mapView:(MKMapView *)mapView
            viewForAnnotation:(id<MKAnnotation>)annotation {
    if ([annotation isKindOfClass:[MKUserLocation class]]) return nil;

    static NSString *reuseId = @"FriendPin";
    MKMarkerAnnotationView *view =
        (MKMarkerAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:reuseId];
    if (!view) {
        view = [[MKMarkerAnnotationView alloc] initWithAnnotation:annotation
                                                  reuseIdentifier:reuseId];
        view.canShowCallout = YES;
    } else {
        view.annotation = annotation;
    }
    view.glyphText = annotation.title ?: @"?";
    return view;
}

@end
