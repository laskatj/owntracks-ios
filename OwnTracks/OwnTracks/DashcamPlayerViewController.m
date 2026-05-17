//
//  DashcamPlayerViewController.m
//  OwnTracks
//

#import "DashcamPlayerViewController.h"
#import "LocationAPISyncService.h"
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CocoaLumberjack/CocoaLumberjack.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

/// Preferred camera ordering when picking the initial camera and rendering the switcher chips.
static NSArray<NSString *> *DashcamPreferredCameraOrder(void) {
    static NSArray<NSString *> *order;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        order = @[ @"front", @"back", @"left_repeater", @"right_repeater", @"left_pillar", @"right_pillar" ];
    });
    return order;
}

static NSString *DashcamHumanCameraName(NSString *camera) {
    static NSDictionary<NSString *, NSString *> *labels;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        labels = @{
            @"front": @"Front",
            @"back": @"Rear",
            @"left_repeater": @"Left",
            @"right_repeater": @"Right",
            @"left_pillar": @"Left Pillar",
            @"right_pillar": @"Right Pillar",
        };
    });
    return labels[camera] ?: camera;
}

@interface DashcamPlayerViewController ()
@property (nonatomic, strong, readonly) OTDashcamClipItem *clip;
@property (nonatomic, strong) AVPlayerViewController *playerVC;
@property (nonatomic, strong) UIStackView *cameraStack;
@property (nonatomic, strong) UIScrollView *cameraScroll;
@property (nonatomic, strong) UILabel *metadataLabel;
@property (nonatomic, copy, nullable) NSString *currentCamera;
@property (nonatomic, strong) NSArray<NSString *> *sortedCameras;
@end

@implementation DashcamPlayerViewController

- (instancetype)initWithClip:(OTDashcamClipItem *)clip {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _clip = clip;
        _sortedCameras = [DashcamPlayerViewController sortedCameraIDsForClip:clip];
    }
    return self;
}

+ (NSArray<NSString *> *)sortedCameraIDsForClip:(OTDashcamClipItem *)clip {
    NSMutableSet<NSString *> *available = [NSMutableSet set];
    for (OTDashcamClipCamera *cam in clip.cameras) {
        if (cam.camera.length > 0) {
            [available addObject:cam.camera];
        }
    }
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *preferred in DashcamPreferredCameraOrder()) {
        if ([available containsObject:preferred]) {
            [out addObject:preferred];
            [available removeObject:preferred];
        }
    }
    NSArray<NSString *> *extras = [available.allObjects sortedArrayUsingSelector:@selector(compare:)];
    [out addObjectsFromArray:extras];
    return [out copy];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = self.clip.device.length > 0 ? self.clip.device : @"Clip";

    [self installPlayer];
    [self installCameraSwitcher];
    [self installMetadataLabel];

    if (self.sortedCameras.count == 0) {
        self.metadataLabel.text = @"No cameras are available for this clip.";
        return;
    }
    [self switchToCamera:self.sortedCameras.firstObject];
    [self refreshMetadataLabel];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.playerVC.player pause];
}

#pragma mark - Subviews

- (void)installPlayer {
    AVPlayerViewController *pvc = [[AVPlayerViewController alloc] init];
    pvc.view.translatesAutoresizingMaskIntoConstraints = NO;
    pvc.view.backgroundColor = UIColor.blackColor;
    pvc.showsPlaybackControls = YES;
    pvc.videoGravity = AVLayerVideoGravityResizeAspect;
    [self addChildViewController:pvc];
    [self.view addSubview:pvc.view];
    [pvc didMoveToParentViewController:self];
    self.playerVC = pvc;

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [pvc.view.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [pvc.view.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [pvc.view.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [pvc.view.heightAnchor constraintEqualToAnchor:pvc.view.widthAnchor multiplier:9.0/16.0],
    ]];
}

- (void)installCameraSwitcher {
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsHorizontalScrollIndicator = NO;
    [self.view addSubview:scroll];
    self.cameraScroll = scroll;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = 8.0;
    [scroll addSubview:stack];
    self.cameraStack = stack;

    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.playerVC.view.bottomAnchor constant:8],
        [scroll.heightAnchor constraintEqualToConstant:42],

        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-12],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [stack.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor],
    ]];

    for (NSString *camera in self.sortedCameras) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        [button setTitle:DashcamHumanCameraName(camera) forState:UIControlStateNormal];
        button.contentEdgeInsets = UIEdgeInsetsMake(6, 14, 6, 14);
        button.layer.cornerRadius = 14.0;
        button.backgroundColor = [UIColor secondarySystemBackgroundColor];
        [button setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        [button addTarget:self action:@selector(cameraChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        button.accessibilityIdentifier = camera;
        [stack addArrangedSubview:button];
    }
}

- (void)installMetadataLabel {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    label.textColor = [UIColor secondaryLabelColor];
    label.numberOfLines = 0;
    [self.view addSubview:label];
    self.metadataLabel = label;
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16],
        [label.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
        [label.topAnchor constraintEqualToAnchor:self.cameraScroll.bottomAnchor constant:12],
        [label.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
    ]];
}

- (void)refreshMetadataLabel {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    static NSDateFormatter *fmt;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateStyle = NSDateFormatterFullStyle;
        fmt.timeStyle = NSDateFormatterMediumStyle;
        fmt.locale = NSLocale.currentLocale;
    });
    NSDate *date = self.clip.eventDate;
    if (date) {
        [lines addObject:[fmt stringFromDate:date]];
    }
    NSMutableArray<NSString *> *placeParts = [NSMutableArray array];
    if (self.clip.street.length > 0) {
        [placeParts addObject:self.clip.street];
    }
    if (self.clip.city.length > 0) {
        [placeParts addObject:self.clip.city];
    }
    if (placeParts.count > 0) {
        [lines addObject:[placeParts componentsJoinedByString:@", "]];
    }
    if (self.clip.reason.length > 0) {
        [lines addObject:[NSString stringWithFormat:@"Reason: %@", self.clip.reason]];
    }
    if (self.clip.owner.length > 0 || self.clip.device.length > 0) {
        NSString *owner = self.clip.owner ?: @"";
        NSString *device = self.clip.device ?: @"";
        [lines addObject:[NSString stringWithFormat:@"Device: %@/%@", owner, device]];
    }
    if (self.clip.usedRouteStartFallback || self.clip.warning.length > 0) {
        NSString *warning = self.clip.warning.length > 0 ? self.clip.warning : @"Location approximated from route history.";
        [lines addObject:warning];
    }
    self.metadataLabel.text = [lines componentsJoinedByString:@"\n"];
}

#pragma mark - Camera switching

- (void)cameraChipTapped:(UIButton *)sender {
    NSString *cam = sender.accessibilityIdentifier;
    if (cam.length == 0 || [cam isEqualToString:self.currentCamera]) {
        return;
    }
    [self switchToCamera:cam];
}

- (void)highlightSelectedCameraChip {
    for (UIView *subview in self.cameraStack.arrangedSubviews) {
        if (![subview isKindOfClass:[UIButton class]]) {
            continue;
        }
        UIButton *button = (UIButton *)subview;
        BOOL selected = [button.accessibilityIdentifier isEqualToString:self.currentCamera];
        button.backgroundColor = selected ? [UIColor systemBlueColor] : [UIColor secondarySystemBackgroundColor];
        [button setTitleColor:selected ? [UIColor whiteColor] : [UIColor labelColor] forState:UIControlStateNormal];
    }
}

- (void)switchToCamera:(NSString *)camera {
    self.currentCamera = camera;
    [self highlightSelectedCameraChip];
    [self.playerVC.player pause];

    __weak typeof(self) wself = self;
    NSString *targetCamera = camera;
    NSString *targetClipId = self.clip.clipId;
    [[LocationAPISyncService sharedInstance] resolveDashcamMediaURLForClipId:targetClipId
                                                                       camera:targetCamera
                                                                         kind:@"stream"
                                                                   completion:^(NSURL * _Nullable url, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(wself) sself = wself;
            if (!sself || ![sself.currentCamera isEqualToString:targetCamera]) {
                return;
            }
            if (!url) {
                DDLogWarn(@"[Dashcam] could not build stream URL for camera %@: %@", targetCamera, error.localizedDescription);
                return;
            }
            AVPlayer *newPlayer = [AVPlayer playerWithURL:url];
            newPlayer.automaticallyWaitsToMinimizeStalling = YES;
            sself.playerVC.player = newPlayer;
            [newPlayer play];
        });
    }];
}

@end
