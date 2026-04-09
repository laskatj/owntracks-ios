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
#import <CocoaLumberjack/CocoaLumberjack.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

static NSString * const kPinId = @"FriendPin";

// Carries the MQTT topic on the annotation so viewForAnnotation: can look up the image.
@interface TVFriendAnnotation : MKPointAnnotation
@property (copy, nonatomic) NSString *topic;
@end
@implementation TVFriendAnnotation @end


@interface TVMapViewController ()
@property (strong, nonatomic) MKMapView *mapView;
// topic → TVFriendAnnotation
@property (strong, nonatomic) NSMutableDictionary<NSString *, TVFriendAnnotation *> *annotations;
// Currently followed friend (nil = no selection).
@property (copy, nonatomic, nullable) NSString *selectedTopic;
@end

@implementation TVMapViewController

#pragma mark - View setup

- (void)loadView {
    self.mapView = [[MKMapView alloc] initWithFrame:CGRectZero];
    self.mapView.delegate = self;
    self.mapView.mapType  = MKMapTypeStandard;
    self.mapView.showsUserLocation = NO;
    self.view = self.mapView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.annotations = [NSMutableDictionary dictionary];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(storeUpdated:)
               name:TVFriendStoreDidUpdateNotification
             object:nil];

    DDLogInfo(@"[TVMapViewController] viewDidLoad");
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - TVFriendStore updates

- (void)storeUpdated:(NSNotification *)note {
    NSString *topic  = note.userInfo[@"topic"];
    NSString *change = note.userInfo[@"change"];

    TVFriendStore *store = [TVFriendStore shared];

    if ([change isEqualToString:@"new"]) {
        // Add a new annotation.
        CLLocationCoordinate2D coord = [self coordForTopic:topic store:store];
        TVFriendAnnotation *ann = [[TVFriendAnnotation alloc] init];
        ann.topic      = topic;
        ann.coordinate = coord;
        ann.title      = store.friendLabels[topic] ?: [topic lastPathComponent];
        ann.subtitle   = store.friendTimes[topic];
        self.annotations[topic] = ann;
        [self.mapView addAnnotation:ann];
        DDLogInfo(@"[TVMapViewController] new pin: %@", topic);

        if (!self.selectedTopic) {
            [self zoomToFitAllAnnotations];
        }

    } else if ([change isEqualToString:@"location"]) {
        TVFriendAnnotation *ann = self.annotations[topic];
        if (ann) {
            CLLocationCoordinate2D coord = [self coordForTopic:topic store:store];
            ann.coordinate = coord;
            ann.subtitle   = store.friendTimes[topic];
            if (self.selectedTopic && [topic isEqualToString:self.selectedTopic]) {
                [self.mapView setCenterCoordinate:coord animated:YES];
            }
        }

    } else if ([change isEqualToString:@"image"] || [change isEqualToString:@"card"]) {
        // Remove and re-add to force viewForAnnotation: to run with the new image/name.
        TVFriendAnnotation *ann = self.annotations[topic];
        if (ann) {
            NSString *label = [TVFriendStore shared].friendLabels[topic] ?: [topic lastPathComponent];
            ann.title = label;
            [self.mapView removeAnnotation:ann];
            [self.mapView addAnnotation:ann];
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
    if (topic) {
        [self zoomToFriend:topic];
        DDLogInfo(@"[TVMapViewController] following %@", topic);
    } else {
        [self zoomToFitAllAnnotations];
        DDLogInfo(@"[TVMapViewController] showing all friends");
    }
}

#pragma mark - Map controls

- (void)zoomToFriend:(NSString *)topic {
    TVFriendAnnotation *ann = self.annotations[topic];
    if (!ann) return;
    MKCoordinateRegion region = MKCoordinateRegionMakeWithDistance(ann.coordinate, 152, 152);
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
