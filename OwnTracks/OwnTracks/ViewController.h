//
//  ViewController.h
//  OwnTracks
//
//  Created by Christoph Krey on 17.08.13.
//  Copyright © 2013-2025  Christoph Krey. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreData/CoreData.h>
#import <MapKit/MapKit.h>
#import "Connection.h"
#import "AttachPhotoTVC.h"
#import "OwnTracksAppDelegate.h"
#import "coredata/Friend+CoreDataClass.h"

@interface ViewController : UIViewController <MKMapViewDelegate, NSFetchedResultsControllerDelegate>
- (IBAction)actionPressed:(UIBarButtonItem *)sender;
/// Called by FriendsTVC when a friend is selected from the list.
/// Activates smooth map following for that friend (same as tapping the pin).
- (void)followFriendFromList:(Friend *)friend;
@end
