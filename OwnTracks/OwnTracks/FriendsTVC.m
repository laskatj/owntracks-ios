//
//  FriendTVC.m
//  OwnTracks
//
//  Created by Christoph Krey on 29.09.13.
//  Copyright © 2013-2025  Christoph Krey. All rights reserved.
//

#import "OwnTracksAppDelegate.h"
#import "Settings.h"
#import "FriendsTVC.h"
#import "WaypointTVC.h"
#import <Sauron-Swift.h>
#import "PersonTVC.h"
#import "Friend+CoreDataClass.h"
#import "FriendTableViewCell.h"
#import "ViewController.h"
#import "Waypoint+CoreDataClass.h"
#import "CoreData.h"
#import "FriendAnnotationV.h"
#import "OwnTracking.h"
#import "LocationAPISyncService.h"
#import <CocoaLumberjack/CocoaLumberjack.h>
#import <Contacts/Contacts.h>
#import <CoreLocation/CoreLocation.h>

typedef NS_ENUM(NSInteger, FriendsSortMode) {
    FriendsSortModeNameAsc = 0,
    FriendsSortModeNameDesc,
    FriendsSortModeLastActivityDesc,
};

typedef NS_ENUM(NSInteger, FriendsFilterMode) {
    FriendsFilterModeAll = 0,
    FriendsFilterModeRecent7Days,
};

static NSString *const kFriendsSortModeKey = @"FriendsTVC.sortMode";
static NSString *const kFriendsFilterModeKey = @"FriendsTVC.filterMode";

@interface FriendsTVC ()
@property (strong, nonatomic) NSFetchedResultsController *fetchedResultsController;
@property (nonatomic) FriendsSortMode friendsSortMode;
@property (nonatomic) FriendsFilterMode friendsFilterMode;
- (void)rebuildSortFilterMenu;
- (void)reloadFriendsTableWhenInViewHierarchy;
@end

@implementation FriendsTVC
static const DDLogLevel ddLogLevel = DDLogLevelInfo;

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    self = [super initWithCoder:aDecoder];
    
    OwnTracksAppDelegate *ad = (OwnTracksAppDelegate *)[UIApplication sharedApplication].delegate;

    [ad addObserver:self
         forKeyPath:@"inQueue"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:nil];
    
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:OwnTracksGeolocationCacheDidUpdateNotification object:nil];
}

- (void)geolocationCacheDidUpdate:(NSNotification *)note {
    [self reloadFriendsTableWhenInViewHierarchy];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    [[NSNotificationCenter defaultCenter] addObserverForName:@"reload"
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note){
        self.fetchedResultsController = nil;
    }];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(geolocationCacheDidUpdate:)
                                                 name:OwnTracksGeolocationCacheDidUpdateNotification
                                               object:nil];
    
    BOOL locked = [Settings theLockedInMOC:CoreData.sharedInstance.mainMOC];
    if (!locked) {
        CNAuthorizationStatus status = [CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts];
        switch (status) {
            case CNAuthorizationStatusRestricted: {
                if (![[NSUserDefaults standardUserDefaults]
                      boolForKey:@"contactsAuthorization"]) {
                    
                    DDLogVerbose(@"CNAuthorizationStatus: CNAuthorizationStatusRestricted");
                    UIAlertController *ac =
                    [UIAlertController
                     alertControllerWithTitle:NSLocalizedString(@"Addressbook Access",
                                                                @"Headline in addressbook related error messages")
                     message:NSLocalizedString(@"has been restricted, possibly due to restrictions such as parental controls.",
                                               @"CNAuthorizationStatusRestricted")
                     preferredStyle:UIAlertControllerStyleAlert];
                    UIAlertAction *ok = [UIAlertAction
                                         actionWithTitle:NSLocalizedString(@"Continue",
                                                                           @"Continue button title")
                                         
                                         style:UIAlertActionStyleDefault
                                         handler:nil];
                    [ac addAction:ok];
                    [self presentViewController:ac animated:TRUE completion:nil];
                    [[NSUserDefaults standardUserDefaults]
                     setBool:TRUE
                     forKey:@"contactsAuthorization"];
                }
                break;
            }
                
            case CNAuthorizationStatusDenied: {
                if (![[NSUserDefaults standardUserDefaults]
                      boolForKey:@"contactsAuthorization"]) {
                    
                    DDLogVerbose(@"CNAuthorizationStatus: CNAuthorizationStatusDenied");
                    UIAlertController *ac =
                    [UIAlertController
                     alertControllerWithTitle:NSLocalizedString(@"Addressbook Access",
                                                                @"Headline in addressbook related error messages")
                     message:NSLocalizedString(@"has been denied by user. If you allow OwnTracks to access your contacts, you can link your devices to contacts. OwnTracks will then display the contact name and image instead of the device Id. No information of your address book will be uploaded to any server. Go to Settings/Privacy/Contacts to change",
                                               @"CNAuthorizationStatusDenied")
                     preferredStyle:UIAlertControllerStyleAlert];
                    UIAlertAction *ok = [UIAlertAction
                                         actionWithTitle:NSLocalizedString(@"Continue",
                                                                           @"Continue button title")
                                         
                                         style:UIAlertActionStyleDefault
                                         handler:nil];
                    [ac addAction:ok];
                    [self presentViewController:ac animated:TRUE completion:nil];
                    [[NSUserDefaults standardUserDefaults]
                     setBool:TRUE
                     forKey:@"contactsAuthorization"];
                }
                break;
            }
                
            case CNAuthorizationStatusAuthorized:
                DDLogVerbose(@"CNAuthorizationStatus: CNAuthorizationStatusAuthorized");
                break;
                
            case CNAuthorizationStatusNotDetermined:
            default:
                [[NSUserDefaults standardUserDefaults]
                 setBool:FALSE
                 forKey:@"contactsAuthorization"];
                
                DDLogVerbose(@"CNAuthorizationStatus: CNAuthorizationStatusNotDetermined");
                CNContactStore *contactStore = [[CNContactStore alloc] init];
                [contactStore requestAccessForEntityType:CNEntityTypeContacts
                                       completionHandler:^(BOOL granted, NSError * _Nullable error) {
                    if (granted) {
                        DDLogVerbose(@"requestAccessForEntityType granted");
                    } else {
                        DDLogVerbose(@"requestAccessForEntityType denied %@", error);
                    }
                }];
                break;
        }
    }

    [self rebuildSortFilterMenu];
}

#pragma mark - Sort & filter (persisted)

- (FriendsSortMode)friendsSortMode {
    NSInteger v = [[NSUserDefaults standardUserDefaults] integerForKey:kFriendsSortModeKey];
    if (v < FriendsSortModeNameAsc || v > FriendsSortModeLastActivityDesc) {
        v = FriendsSortModeNameAsc;
    }
    return (FriendsSortMode)v;
}

- (void)setFriendsSortMode:(FriendsSortMode)friendsSortMode {
    [[NSUserDefaults standardUserDefaults] setInteger:friendsSortMode forKey:kFriendsSortModeKey];
}

- (FriendsFilterMode)friendsFilterMode {
    NSInteger v = [[NSUserDefaults standardUserDefaults] integerForKey:kFriendsFilterModeKey];
    if (v < FriendsFilterModeAll || v > FriendsFilterModeRecent7Days) {
        v = FriendsFilterModeAll;
    }
    return (FriendsFilterMode)v;
}

- (void)setFriendsFilterMode:(FriendsFilterMode)friendsFilterMode {
    [[NSUserDefaults standardUserDefaults] setInteger:friendsFilterMode forKey:kFriendsFilterModeKey];
}

- (void)rebuildSortFilterMenu {
    FriendsSortMode sort = self.friendsSortMode;
    FriendsFilterMode filter = self.friendsFilterMode;
    __weak typeof(self) weakSelf = self;

    UIAction *nameAsc = [UIAction actionWithTitle:NSLocalizedString(@"Name (A–Z)",
                                                                    @"Friends list sort: alphabetical A–Z")
                                           image:nil
                                      identifier:nil
                                         handler:^(__kindof UIAction * _Nonnull action) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf.friendsSortMode = FriendsSortModeNameAsc;
        strongSelf.fetchedResultsController = nil;
        [strongSelf.tableView reloadData];
        [strongSelf rebuildSortFilterMenu];
    }];
    nameAsc.state = (sort == FriendsSortModeNameAsc) ? UIMenuElementStateOn : UIMenuElementStateOff;

    UIAction *nameDesc = [UIAction actionWithTitle:NSLocalizedString(@"Name (Z–A)",
                                                                     @"Friends list sort: reverse alphabetical")
                                            image:nil
                                       identifier:nil
                                          handler:^(__kindof UIAction * _Nonnull action) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf.friendsSortMode = FriendsSortModeNameDesc;
        strongSelf.fetchedResultsController = nil;
        [strongSelf.tableView reloadData];
        [strongSelf rebuildSortFilterMenu];
    }];
    nameDesc.state = (sort == FriendsSortModeNameDesc) ? UIMenuElementStateOn : UIMenuElementStateOff;

    UIAction *lastActivity = [UIAction actionWithTitle:NSLocalizedString(@"Last activity (newest first)",
                                                                          @"Friends list sort by last location time")
                                                image:nil
                                           identifier:nil
                                              handler:^(__kindof UIAction * _Nonnull action) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf.friendsSortMode = FriendsSortModeLastActivityDesc;
        strongSelf.fetchedResultsController = nil;
        [strongSelf.tableView reloadData];
        [strongSelf rebuildSortFilterMenu];
    }];
    lastActivity.state = (sort == FriendsSortModeLastActivityDesc) ? UIMenuElementStateOn : UIMenuElementStateOff;

    UIMenu *sortSection = [UIMenu menuWithTitle:NSLocalizedString(@"Sort by", @"Friends list: sort menu section title")
                                        image:nil
                                   identifier:nil
                                      options:UIMenuOptionsDisplayInline
                                     children:@[nameAsc, nameDesc, lastActivity]];

    UIAction *filterAll = [UIAction actionWithTitle:NSLocalizedString(@"All", @"Friends list filter: show all")
                                              image:nil
                                         identifier:nil
                                            handler:^(__kindof UIAction * _Nonnull action) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf.friendsFilterMode = FriendsFilterModeAll;
        strongSelf.fetchedResultsController = nil;
        [strongSelf.tableView reloadData];
        [strongSelf rebuildSortFilterMenu];
    }];
    filterAll.state = (filter == FriendsFilterModeAll) ? UIMenuElementStateOn : UIMenuElementStateOff;

    UIAction *filterRecent = [UIAction actionWithTitle:NSLocalizedString(@"Recent activity (last 7 days)",
                                                                        @"Friends list filter: last week only")
                                               image:nil
                                          identifier:nil
                                             handler:^(__kindof UIAction * _Nonnull action) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf.friendsFilterMode = FriendsFilterModeRecent7Days;
        strongSelf.fetchedResultsController = nil;
        [strongSelf.tableView reloadData];
        [strongSelf rebuildSortFilterMenu];
    }];
    filterRecent.state = (filter == FriendsFilterModeRecent7Days) ? UIMenuElementStateOn : UIMenuElementStateOff;

    UIMenu *filterSection = [UIMenu menuWithTitle:NSLocalizedString(@"Filter", @"Friends list: filter menu section title")
                                          image:nil
                                     identifier:nil
                                        options:UIMenuOptionsDisplayInline
                                       children:@[filterAll, filterRecent]];

    UIMenu *rootMenu = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:0 children:@[sortSection, filterSection]];

    UIImage *icon = [UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"];
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithImage:icon
                                                               style:UIBarButtonItemStylePlain
                                                              target:nil
                                                              action:nil];
    item.menu = rootMenu;
    item.accessibilityLabel = NSLocalizedString(@"Sort and filter friends",
                                                @"Accessibility: opens friends list sort and filter menu");
    self.navigationItem.rightBarButtonItem = item;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    while (!self.fetchedResultsController) {
        //
    }
    [self reloadFriendsTableWhenInViewHierarchy];
    [[LocationAPISyncService sharedInstance] requestLocationRefreshIfAppropriate];
    [[LocationAPISyncService sharedInstance] requestGeolocationCachePrefetchIfAppropriate];
}

/// Avoids `UITableViewAlertForLayoutOutsideViewHierarchy` when `reloadData` runs before the table is in a window (tab timing).
- (void)reloadFriendsTableWhenInViewHierarchy {
    __weak typeof(self) weakSelf = self;
    void (^reload)(void) = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (strongSelf.tableView.window != nil) {
            [strongSelf.tableView reloadData];
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) inner = weakSelf;
            if (inner.tableView.window != nil) {
                [inner.tableView reloadData];
            }
        });
    };
    reload();
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    OwnTracksAppDelegate *ad = (OwnTracksAppDelegate *)object;
    [self performSelectorOnMainThread:@selector(setBadge:)
                           withObject:ad.inQueue
                        waitUntilDone:NO];
}

- (void)setBadge:(NSNumber *)number {
    unsigned long inQueue = number.unsignedLongValue;
    DDLogVerbose(@"inQueue %lu", inQueue);
    if (inQueue > 0) {
        (self.navigationController.tabBarItem).badgeValue = [NSString stringWithFormat:@"%lu", inQueue];
    } else {
        [self.navigationController.tabBarItem setBadgeValue:nil];
    }
}

- (BOOL)shouldPerformSegueWithIdentifier:(NSString *)identifier sender:(id)sender {
    if ([identifier isEqualToString:@"showWaypointFromFriends"]) {
        NSIndexPath *ip = [self.tableView indexPathForCell:sender];
        if (ip) {
            Friend *friend = [self.fetchedResultsController objectAtIndexPath:ip];
            Waypoint *waypoint = friend.newestWaypoint;
            if (waypoint) {
                DeviceDetailHostingController *vc =
                    [[DeviceDetailHostingController alloc] initWithWaypoint:waypoint];
                [self.navigationController pushViewController:vc animated:YES];
            }
        }
        return NO;
    }
    return YES;
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    NSIndexPath *indexPath = nil;

    if ([sender isKindOfClass:[UITableViewCell class]]) {
        indexPath = [self.tableView indexPathForCell:sender];
    }

    if (indexPath) {
        Friend *friend = [self.fetchedResultsController objectAtIndexPath:indexPath];

        if ([segue.identifier isEqualToString:@"showWaypointFromFriends"]) {
            if ([segue.destinationViewController respondsToSelector:@selector(setWaypoint:)]) {
                Waypoint *waypoint = friend.newestWaypoint;
                if (waypoint) {
                    [segue.destinationViewController performSelector:@selector(setWaypoint:) withObject:waypoint];
                }
            }
        }

    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    Friend *friend = [self.fetchedResultsController objectAtIndexPath:indexPath];

    UITabBarController *tbc;
    UINavigationController *nc;
    NSUInteger targetIndex = NSNotFound;

    if (self.splitViewController) {
        UISplitViewController *svc = self.splitViewController;
        nc = svc.viewControllers[1];
    } else {
        tbc = self.tabBarController;
        NSArray *vcs = tbc.viewControllers;
        for (NSUInteger i = 0; i < vcs.count; i++) {
            UIViewController *candidate = vcs[i];
            if ([candidate isKindOfClass:[UINavigationController class]]) {
                UIViewController *top = [(UINavigationController *)candidate topViewController];
                if ([top respondsToSelector:@selector(setCenter:)]) {
                    nc = (UINavigationController *)candidate;
                    targetIndex = i;
                    break;
                }
            }
        }
    }

    UIViewController *vc = nc.topViewController;
    if ([vc respondsToSelector:@selector(setCenter:)]) {
        [vc performSelector:@selector(setCenter:) withObject:friend];
        if (tbc && targetIndex != NSNotFound) {
            tbc.selectedIndex = targetIndex;
        }
        if ([vc isKindOfClass:[ViewController class]]) {
            [(ViewController *)vc followFriendFromList:friend];
        }
    }
}

#pragma mark - Table View

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (self.fetchedResultsController).sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    id <NSFetchedResultsSectionInfo> sectionInfo = (self.fetchedResultsController).sections[section];
    if (sectionInfo.numberOfObjects == 0) {
        [self empty];
    } else {
        [self nonempty];
    }
    return sectionInfo.numberOfObjects;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"friend" forIndexPath:indexPath];
    [self configureCell:cell atIndexPath:indexPath];
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

- (void)tableView:(UITableView *)tableView
commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        NSManagedObjectContext *context = (self.fetchedResultsController).managedObjectContext;
        OwnTracksAppDelegate *ad = (OwnTracksAppDelegate *)[UIApplication sharedApplication].delegate;
        Friend *friend = [self.fetchedResultsController objectAtIndexPath:indexPath];
        if (friend.topic.length) {
            [ad sendEmpty:friend.topic];
        } else {
            DDLogWarn(@"[FriendsTVC] deleting friend without topic; skipping sendEmpty");
        }
        [context deleteObject:friend];
        [[CoreData sharedInstance] sync:context];
    }
}

#pragma mark - Fetched results controller

- (NSFetchedResultsController *)fetchedResultsController {
    if (_fetchedResultsController != nil) {
        return _fetchedResultsController;
    }
    
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
    NSEntityDescription *entity = [NSEntityDescription entityForName:@"Friend"
                                              inManagedObjectContext:CoreData.sharedInstance.mainMOC];
    fetchRequest.entity = entity;
    fetchRequest.fetchBatchSize = 20;

    NSMutableArray<NSPredicate *> *predicates = [NSMutableArray array];
    double ignoreStaleLocations = [Settings doubleForKey:@"ignorestalelocations_preference"
                                                   inMOC:CoreData.sharedInstance.mainMOC];
    if (ignoreStaleLocations) {
        NSTimeInterval stale = -ignoreStaleLocations * 24.0 * 3600.0;
        [predicates addObject:[NSPredicate predicateWithFormat:@"lastLocation > %@",
                               [NSDate dateWithTimeIntervalSinceNow:stale]]];
    }
    if (self.friendsFilterMode == FriendsFilterModeRecent7Days) {
        NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-7.0 * 24.0 * 3600.0];
        [predicates addObject:[NSPredicate predicateWithFormat:@"lastLocation > %@", cutoff]];
    }
    if (predicates.count > 0) {
        fetchRequest.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:predicates];
    }

    NSSortDescriptor *topicAsc = [NSSortDescriptor sortDescriptorWithKey:@"topic"
                                                                 ascending:YES
                                                                  selector:@selector(caseInsensitiveCompare:)];
    NSSortDescriptor *topicDesc = [NSSortDescriptor sortDescriptorWithKey:@"topic"
                                                                ascending:NO
                                                                 selector:@selector(caseInsensitiveCompare:)];
    NSSortDescriptor *cardNameAsc = [NSSortDescriptor sortDescriptorWithKey:@"cardName"
                                                                  ascending:YES
                                                                   selector:@selector(caseInsensitiveCompare:)];
    NSSortDescriptor *cardNameDesc = [NSSortDescriptor sortDescriptorWithKey:@"cardName"
                                                                   ascending:NO
                                                                    selector:@selector(caseInsensitiveCompare:)];
    NSSortDescriptor *lastLocationDesc = [NSSortDescriptor sortDescriptorWithKey:@"lastLocation" ascending:NO];

    NSArray<NSSortDescriptor *> *sortDescriptors;
    switch (self.friendsSortMode) {
        case FriendsSortModeNameDesc:
            sortDescriptors = @[cardNameDesc, topicDesc];
            break;
        case FriendsSortModeLastActivityDesc:
            sortDescriptors = @[lastLocationDesc, topicAsc];
            break;
        case FriendsSortModeNameAsc:
        default:
            sortDescriptors = @[cardNameAsc, topicAsc];
            break;
    }
    fetchRequest.sortDescriptors = sortDescriptors;
    
    NSFetchedResultsController *aFetchedResultsController = [[NSFetchedResultsController alloc]
                                                             initWithFetchRequest:fetchRequest
                                                             managedObjectContext:CoreData.sharedInstance.mainMOC
                                                             sectionNameKeyPath:nil
                                                             cacheName:nil];
    aFetchedResultsController.delegate = self;
    self.fetchedResultsController = aFetchedResultsController;
    
    NSError *error = nil;
    if (![self.fetchedResultsController performFetch:&error]) {
        DDLogError(@"Unresolved error %@, %@", error, [error userInfo]);
    }
    
    return _fetchedResultsController;
}

- (void)controllerWillChangeContent:(NSFetchedResultsController *)controller {
    [self beginUpdates];
}

- (void)beginUpdates {
    [self.tableView beginUpdates];
}

- (void)controller:(NSFetchedResultsController *)controller
  didChangeSection:(id <NSFetchedResultsSectionInfo>)sectionInfo
           atIndex:(NSUInteger)sectionIndex
     forChangeType:(NSFetchedResultsChangeType)type {
    NSDictionary *d = @{@"type": @(type),
                        @"sectionIndex": @(sectionIndex)};
    DDLogVerbose(@"[FriensTVC] didChangeSection %@", d);
    [self didChangeSection:d];
}

- (void)didChangeSection:(NSDictionary *)d {
    NSNumber *type = d[@"type"];
    NSNumber *sectionIndex = d[@"sectionIndex"];
    
    switch(type.intValue) {
        case NSFetchedResultsChangeInsert:
            [self.tableView insertSections:[NSIndexSet indexSetWithIndex:sectionIndex.intValue]
                          withRowAnimation:UITableViewRowAnimationAutomatic];
            break;
            
        case NSFetchedResultsChangeDelete:
            [self.tableView deleteSections:[NSIndexSet indexSetWithIndex:sectionIndex.intValue]
                          withRowAnimation:UITableViewRowAnimationAutomatic];
            break;
        default:
            break;
    }
}

- (void)controller:(NSFetchedResultsController *)controller
   didChangeObject:(id)anObject
       atIndexPath:(NSIndexPath *)indexPath
     forChangeType:(NSFetchedResultsChangeType)type
      newIndexPath:(NSIndexPath *)newIndexPath {
    NSMutableDictionary *d = [@{@"type": @(type)}
                              mutableCopy];
    if (indexPath) {
        d[@"indexPath"] = indexPath;
    }
    if (newIndexPath) {
        d[@"newIndexPath"] = newIndexPath;
    }
    DDLogVerbose(@"[FriendsTVC] didChangeObject %@", d);
    [self didChangeObject:d];
}

- (void)didChangeObject:(NSDictionary *)d {
    NSNumber *type = d[@"type"];
    NSIndexPath *indexPath = d[@"indexPath"];
    NSIndexPath *newIndexPath = d[@"newIndexPath"];
    
    switch(type.intValue) {
        case NSFetchedResultsChangeInsert:
            if (newIndexPath) {
                [self.tableView insertRowsAtIndexPaths:@[newIndexPath]
                                      withRowAnimation:UITableViewRowAnimationAutomatic];
            }
            break;
            
        case NSFetchedResultsChangeDelete:
            if (indexPath) {
                [self.tableView deleteRowsAtIndexPaths:@[indexPath]
                                      withRowAnimation:UITableViewRowAnimationAutomatic];
            }
            break;
            
        case NSFetchedResultsChangeUpdate:
            if (indexPath) {
                [self.tableView reloadRowsAtIndexPaths:@[indexPath]
                                      withRowAnimation:UITableViewRowAnimationAutomatic];
            }
            break;
            
        case NSFetchedResultsChangeMove:
            if (indexPath) {
                [self.tableView deleteRowsAtIndexPaths:@[indexPath]
                                      withRowAnimation:UITableViewRowAnimationAutomatic];
            }
            if (newIndexPath) {
                [self.tableView insertRowsAtIndexPaths:@[newIndexPath]
                                      withRowAnimation:UITableViewRowAnimationAutomatic];
            }
            break;
    }
}

- (void)controllerDidChangeContent:(NSFetchedResultsController *)controller {
    [self endUpdates];
}

- (void)endUpdates {
    [self.tableView endUpdates];
}

- (void)configureCell:(UITableViewCell *)cell atIndexPath:(NSIndexPath *)indexPath {
    FriendTableViewCell *friendTableViewCell = (FriendTableViewCell *)cell;
    
    Friend *friend = [self.fetchedResultsController objectAtIndexPath:indexPath];
    
    friendTableViewCell.name.text = friend.name ? friend.name : friend.tid;
    
    FriendAnnotationV *friendAnnotationView = [[FriendAnnotationV alloc] initWithFrame:CGRectMake(0, 0, 40, 40)];
    friendAnnotationView.personImage = friend.image ? [UIImage imageWithData:friend.image] : nil;
    friendAnnotationView.me = [friend.topic isEqualToString:[Settings theGeneralTopicInMOC:CoreData.sharedInstance.mainMOC]];
    friendAnnotationView.tid = friend.effectiveTid;
    
    Waypoint *waypoint = friend.newestWaypoint;
    if (waypoint) {
        CLLocationCoordinate2D coord = CLLocationCoordinate2DMake((waypoint.lat).doubleValue, (waypoint.lon).doubleValue);
        OTWebLocationItem *contained = nil;
        if (CLLocationCoordinate2DIsValid(coord)) {
            contained = [[LocationAPISyncService sharedInstance] geolocationItemContainingCoordinate:coord];
        }
        if (contained) {
            friendTableViewCell.address.text = contained.displayName;
        } else if (waypoint.placemark) {
            friendTableViewCell.address.text = waypoint.placemark;
        } else {
            DDLogVerbose(@"[FriendsTVC] configureCell resolving %@", waypoint);
            friendTableViewCell.address.text = NSLocalizedString(@"resolving...",
                                                                 @"temporary display while resolving address");
            [friendTableViewCell deferredReverseGeoCode:waypoint];
        }
        friendAnnotationView.speed = (waypoint.vel).doubleValue;
        friendAnnotationView.course = (waypoint.cog).doubleValue;

        NSDateComponents *dateComponents = [[NSCalendar currentCalendar]
                                            components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay
                                            fromDate:[NSDate date]];
        NSDate *thisMorning = [[NSCalendar currentCalendar] dateFromComponents:dateComponents];
        if ([waypoint.tst timeIntervalSinceDate:thisMorning] > 0) {
            friendTableViewCell.timestamp.text = [NSDateFormatter localizedStringFromDate:waypoint.tst
                                                                                dateStyle:NSDateFormatterNoStyle
                                                                                timeStyle:NSDateFormatterShortStyle];
        } else {
            friendTableViewCell.timestamp.text = [NSDateFormatter localizedStringFromDate:waypoint.tst
                                                                                dateStyle:NSDateFormatterShortStyle
                                                                                timeStyle:NSDateFormatterNoStyle];
        }
    } else {
        friendTableViewCell.address.text = @"";
        friendAnnotationView.speed = -1;
        friendAnnotationView.course = -1;
        friendTableViewCell.timestamp.text = @"";
    }
    
    friendTableViewCell.image.image = [friendAnnotationView getImage];
}

@end
