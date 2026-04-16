//
//  SmoothMarkerAnimator.m
//  SauronTV
//
//  Why this removes jump/pause behaviour
//  ──────────────────────────────────────
//  MapKit's UIView.animate snaps to the destination in one fixed-duration
//  slide — it has no concept of how long ago the previous GPS fix arrived.
//  This class derives animation duration from the actual inter-fix elapsed
//  time, then lerps the coordinate every frame with CADisplayLink.
//  Mid-animation retargeting starts from the *current rendered position*,
//  so the marker never pauses or teleports when a new fix arrives early.
//

#import "SmoothMarkerAnimator.h"

static const CFTimeInterval  kMinDuration      = 0.10;  // 100 ms floor
static const CFTimeInterval  kMaxDuration      = 3.00;  // 3 s ceiling
static const NSTimeInterval  kGapSnapThreshold = 5.0;   // s → snap, no animation
static const CLLocationDistance kJitterThreshold = 0.1; // m → ignore duplicate fix

@interface SmoothMarkerAnimator ()
// Weak: we don't extend the annotation's lifetime.
@property (weak, nonatomic) MKPointAnnotation *annotation;

// Latest GPS fix (current animation target).
@property (assign, nonatomic) CLLocationCoordinate2D targetCoord;
@property (assign, nonatomic) NSTimeInterval         targetTimestamp;
@property (assign, nonatomic) BOOL                   hasTarget;

// Active CADisplayLink animation state.
@property (strong, nonatomic, nullable) CADisplayLink *displayLink;
@property (assign, nonatomic) CLLocationCoordinate2D animStartCoord;
@property (assign, nonatomic) CFTimeInterval         animStartTime;
@property (assign, nonatomic) CFTimeInterval         animDuration;
@end

@implementation SmoothMarkerAnimator

- (instancetype)initWithAnnotation:(MKPointAnnotation *)annotation {
    if ((self = [super init])) {
        _annotation      = annotation;
        _targetTimestamp = 0;
        _hasTarget       = NO;
    }
    return self;
}

- (void)startOrUpdateWithLatitude:(double)latitude
                        longitude:(double)longitude
                        timestamp:(NSTimeInterval)timestamp {
    MKPointAnnotation *ann = self.annotation;
    if (!ann) { [self cancel]; return; }

    CLLocationCoordinate2D newCoord = CLLocationCoordinate2DMake(latitude, longitude);

    // ── Duplicate / jitter filter ─────────────────────────────────────────
    if (self.hasTarget) {
        CLLocation *prev = [[CLLocation alloc] initWithLatitude:self.targetCoord.latitude
                                                      longitude:self.targetCoord.longitude];
        CLLocation *next = [[CLLocation alloc] initWithLatitude:latitude longitude:longitude];
        if ([prev distanceFromLocation:next] < kJitterThreshold) return;
    }

    // ── Current rendered position (start of next animation) ───────────────
    // Mid-animation: read the pin's actual interpolated position so the next
    // animation starts from where the pin visually is, not where it was headed.
    CLLocationCoordinate2D fromCoord;
    if (self.displayLink) {
        fromCoord = ann.coordinate;
    } else {
        fromCoord = self.hasTarget ? self.targetCoord : newCoord;
    }

    // ── Compute inter-fix gap ─────────────────────────────────────────────
    NSTimeInterval timeDiff = 0;
    if (self.targetTimestamp > 0 && timestamp > self.targetTimestamp) {
        timeDiff = timestamp - self.targetTimestamp;
    }

    // Advance state before any early return so the next call sees correct values.
    self.targetCoord     = newCoord;
    self.targetTimestamp = timestamp;
    self.hasTarget       = YES;

    [self cancel];

    // ── Gap snap ──────────────────────────────────────────────────────────
    // No prior timing info OR large gap → teleport immediately, no animation.
    if (timeDiff == 0 || timeDiff > kGapSnapThreshold) {
        ann.coordinate = newCoord;
        return;
    }

    // ── Clamp duration ────────────────────────────────────────────────────
    self.animDuration   = MIN(MAX(timeDiff, kMinDuration), kMaxDuration);
    self.animStartCoord = fromCoord;
    self.animStartTime  = CACurrentMediaTime();

    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self
                                                      selector:@selector(step:)];
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    self.displayLink = link;
}

- (void)cancel {
    [self.displayLink invalidate];
    self.displayLink = nil;
}

- (void)step:(CADisplayLink *)link {
    MKPointAnnotation *ann = self.annotation;
    if (!ann || !self.hasTarget) { [self cancel]; return; }

    CFTimeInterval elapsed  = CACurrentMediaTime() - self.animStartTime;
    double         progress = MIN(elapsed / self.animDuration, 1.0);

    // Linear interpolation — unrounded doubles to avoid pixel snapping.
    double lat = self.animStartCoord.latitude
               + (self.targetCoord.latitude  - self.animStartCoord.latitude)  * progress;
    double lon = self.animStartCoord.longitude
               + (self.targetCoord.longitude - self.animStartCoord.longitude) * progress;
    ann.coordinate = CLLocationCoordinate2DMake(lat, lon);

    if (progress >= 1.0) {
        ann.coordinate = self.targetCoord;  // force exact final position; avoids float drift
        [self cancel];
    }
}

- (void)dealloc {
    [self cancel];
}

@end
