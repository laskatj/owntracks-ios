//
//  OTMapFollowHeading.h
//  OwnTracks
//
//  Helpers for course-up / heading-up map follow using OTLiveFriendLocation payloads.
//

#import <CoreLocation/CoreLocation.h>
#import <Foundation/Foundation.h>

/// Maximum `MKMapCamera.pitch` for follow / 3D navigation (MapKit caps at 60° for most map types).
double OTMaxFollowMapCameraPitch(void);

/// True if `degrees` is a usable OwnTracks `cog` / map heading in [0, 360].
BOOL OTHeadingDegreesValid(double degrees);

/// Clockwise degrees from true north, normalized to [0, 360).
double OTNormalizeHeadingDegrees(double degrees);

/// Initial bearing from `from` to `to` (clockwise from true north), or NAN if undefined.
double OTBearingDegreesBetween(CLLocationCoordinate2D from, CLLocationCoordinate2D to);

/*
 Effective map heading for MKMapCamera while following.

 `liveUserInfo`: OTLiveFriendLocation userInfo (optional `cog`, `vel` as NSNumber).

 `inOutPrev`: previous coordinate for this topic; updated to `coord` when `coord` is valid.
 Use kCLLocationCoordinate2DInvalid for “no previous fix”.

 Returns normalized heading in [0, 360) when the device is considered **moving** and a
 heading can be determined (from `cog` or bearing from previous fix).

 Returns NAN when stationary / unknown — there is no new heading for this update. Callers
 that want course-up follow to continue while stopped should **keep** the previous map or
 camera heading; callers that want north-up when idle may set heading to 0 instead.
 */
double OTEffectiveFollowMapHeading(NSDictionary *liveUserInfo,
                                   CLLocationCoordinate2D coord,
                                   CLLocationCoordinate2D *inOutPrev);
