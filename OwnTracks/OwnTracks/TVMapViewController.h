//
//  TVMapViewController.h
//  SauronTV
//
//  Full-screen MKMapView showing friend locations.
//  Observes OTLiveFriendLocation notifications posted by TVAppDelegate.
//

#import <UIKit/UIKit.h>
#import <MapKit/MapKit.h>

@interface TVMapViewController : UIViewController <MKMapViewDelegate>

@end
