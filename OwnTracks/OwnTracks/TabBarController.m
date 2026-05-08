//
//  TBC.m
//  OwnTracks
//
//  Created by Christoph Krey on 21.06.15.
//  Copyright © 2015-2025  OwnTracks. All rights reserved.
//

#import "TabBarController.h"
#import "Settings.h"
#import "OwnTracksAppDelegate.h"
#import "CoreData.h"
#import "LocationAPISyncService.h"
#import "WebAppURLResolver.h"
#import "ViewController.h"
#import <CocoaLumberjack/CocoaLumberjack.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

typedef NS_ENUM(NSInteger, OTLocationsSourceFilter) {
    OTLocationsSourceFilterAll = 0,
    OTLocationsSourceFilterCustom,
    OTLocationsSourceFilterZone,
    OTLocationsSourceFilterDestination,
    OTLocationsSourceFilterReverseGeocode,
    OTLocationsSourceFilterOther
};

@interface OTLocationDetailsViewController : UITableViewController
@property (nonatomic, strong) OTWebLocationItem *locationItem;
@property (nonatomic, copy) void (^showOnMapHandler)(OTWebLocationItem *item);
@end

@interface OTLocationsViewController : UITableViewController
@property (nonatomic, strong) NSArray<OTWebLocationItem *> *allLocations;
@property (nonatomic, strong) NSArray<OTWebLocationItem *> *visibleLocations;
@property (nonatomic) OTLocationsSourceFilter sourceFilter;
@property (nonatomic, strong) UIStackView *tileStack;
@property (nonatomic, strong) NSArray<UIButton *> *tileButtons;
@end

@implementation OTLocationDetailsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.locationItem.displayName.length > 0 ? self.locationItem.displayName : @"Location Details";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 3; // identity
        case 1: return 3; // coordinates
        case 2: return 2; // time
        case 3: return 1; // action
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"Identity";
        case 1: return @"Coordinates & Radius";
        case 2: return @"Timestamps";
        case 3: return @"Actions";
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"LocationDetailCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cellId];
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    OTWebLocationItem *item = self.locationItem;

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Display Name";
            cell.detailTextLabel.text = item.displayName ?: @"-";
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Original Name";
            cell.detailTextLabel.text = item.originalDisplayName.length > 0 ? item.originalDisplayName : @"-";
        } else {
            cell.textLabel.text = @"Source Type";
            NSString *source = item.sourceType.length > 0 ? item.sourceType : @"Other";
            cell.detailTextLabel.text = [source isEqualToString:@"GeoLocation"] ? @"Reverse Geocode" : source;
        }
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Latitude";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.6f", item.latitude];
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Longitude";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.6f", item.longitude];
        } else {
            cell.textLabel.text = @"Radius (m)";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.1f", item.radius ? item.radius.doubleValue : 35.0];
        }
    } else if (indexPath.section == 2) {
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateStyle = NSDateFormatterMediumStyle;
        fmt.timeStyle = NSDateFormatterMediumStyle;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Created";
            cell.detailTextLabel.text = item.createdAt ? [fmt stringFromDate:item.createdAt] : @"-";
        } else {
            cell.textLabel.text = @"Last Accessed";
            cell.detailTextLabel.text = item.lastAccessed ? [fmt stringFromDate:item.lastAccessed] : @"-";
        }
    } else {
        cell.textLabel.text = @"Show on Map";
        cell.detailTextLabel.text = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 3 && self.showOnMapHandler) {
        self.showOnMapHandler(self.locationItem);
    }
}

@end

@implementation OTLocationsViewController

- (NSString *)tileTitleForFilter:(OTLocationsSourceFilter)filter {
    switch (filter) {
        case OTLocationsSourceFilterAll: return @"All";
        case OTLocationsSourceFilterCustom: return @"Custom";
        case OTLocationsSourceFilterDestination: return @"Destination";
        case OTLocationsSourceFilterZone: return @"Zone";
        case OTLocationsSourceFilterReverseGeocode: return @"Reverse Geocode";
        case OTLocationsSourceFilterOther: return @"Other";
    }
}

- (NSInteger)countForFilter:(OTLocationsSourceFilter)filter {
    if (filter == OTLocationsSourceFilterAll) {
        return self.allLocations.count;
    }
    NSInteger count = 0;
    for (OTWebLocationItem *item in self.allLocations) {
        NSString *source = item.sourceType ?: @"";
        if (filter == OTLocationsSourceFilterCustom && [source isEqualToString:@"Custom"]) { count++; continue; }
        if (filter == OTLocationsSourceFilterZone && [source isEqualToString:@"Zone"]) { count++; continue; }
        if (filter == OTLocationsSourceFilterDestination && [source isEqualToString:@"Destination"]) { count++; continue; }
        if (filter == OTLocationsSourceFilterReverseGeocode && [source isEqualToString:@"GeoLocation"]) { count++; continue; }
        if (filter == OTLocationsSourceFilterOther && (source.length == 0 || (![source isEqualToString:@"Custom"] &&
                                                                                ![source isEqualToString:@"Zone"] &&
                                                                                ![source isEqualToString:@"Destination"] &&
                                                                                ![source isEqualToString:@"GeoLocation"]))) {
            count++;
        }
    }
    return count;
}

- (void)tileTapped:(UIButton *)sender {
    self.sourceFilter = (OTLocationsSourceFilter)sender.tag;
    [self applyFilter];
}

- (void)updateTileButtons {
    for (UIButton *button in self.tileButtons) {
        OTLocationsSourceFilter filter = (OTLocationsSourceFilter)button.tag;
        NSInteger count = [self countForFilter:filter];
        NSString *title = [NSString stringWithFormat:@"%@\n%ld", [self tileTitleForFilter:filter], (long)count];
        [button setTitle:title forState:UIControlStateNormal];
        button.titleLabel.numberOfLines = 2;
        button.titleLabel.textAlignment = NSTextAlignmentCenter;
        BOOL selected = (filter == self.sourceFilter);
        button.backgroundColor = selected ? [UIColor systemBlueColor] : [UIColor secondarySystemBackgroundColor];
        [button setTitleColor:selected ? UIColor.whiteColor : [UIColor labelColor] forState:UIControlStateNormal];
        button.layer.cornerRadius = 10.0;
    }
}

- (void)navigateToMapForLocation:(OTWebLocationItem *)item {
    UITabBarController *tabs = self.tabBarController;
    UINavigationController *mapNav = nil;
    NSUInteger targetIndex = NSNotFound;
    for (NSUInteger i = 0; i < tabs.viewControllers.count; i++) {
        UIViewController *candidate = tabs.viewControllers[i];
        if (![candidate isKindOfClass:[UINavigationController class]]) {
            continue;
        }
        UIViewController *top = ((UINavigationController *)candidate).topViewController;
        if ([top isKindOfClass:[ViewController class]]) {
            mapNav = (UINavigationController *)candidate;
            targetIndex = i;
            break;
        }
    }
    if (mapNav && targetIndex != NSNotFound) {
        tabs.selectedIndex = targetIndex;
        ViewController *mapVC = (ViewController *)mapNav.topViewController;
        CLLocationDistance radius = item.radius ? item.radius.doubleValue : 35.0;
        [mapVC showLocationZoneWithName:item.displayName
                             coordinate:CLLocationCoordinate2DMake(item.latitude, item.longitude)
                                 radius:radius];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Locations";
    self.allLocations = @[];
    self.visibleLocations = @[];
    self.sourceFilter = OTLocationsSourceFilterAll;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                             target:self
                                                                                             action:@selector(reloadLocations)];
    UIScrollView *tileScroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 84)];
    tileScroll.showsHorizontalScrollIndicator = NO;
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = 10.0;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [tileScroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:tileScroll.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:tileScroll.trailingAnchor constant:-12],
        [stack.topAnchor constraintEqualToAnchor:tileScroll.topAnchor constant:8],
        [stack.bottomAnchor constraintEqualToAnchor:tileScroll.bottomAnchor constant:-8],
        [stack.heightAnchor constraintEqualToConstant:68]
    ]];
    self.tileStack = stack;
    NSMutableArray<UIButton *> *tiles = [NSMutableArray array];
    NSArray<NSNumber *> *filters = @[
        @(OTLocationsSourceFilterAll),
        @(OTLocationsSourceFilterCustom),
        @(OTLocationsSourceFilterDestination),
        @(OTLocationsSourceFilterZone),
        @(OTLocationsSourceFilterReverseGeocode)
    ];
    for (NSNumber *filterNumber in filters) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = filterNumber.integerValue;
        button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        [button addTarget:self action:@selector(tileTapped:) forControlEvents:UIControlEventTouchUpInside];
        [button.widthAnchor constraintEqualToConstant:126].active = YES;
        [stack addArrangedSubview:button];
        [tiles addObject:button];
    }
    self.tileButtons = [tiles copy];
    self.tableView.tableHeaderView = tileScroll;
    tileScroll.contentSize = CGSizeMake(12 + (self.tileButtons.count * 126) + ((self.tileButtons.count - 1) * 10) + 12, 84);

    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(reloadLocations) forControlEvents:UIControlEventValueChanged];
    [self reloadLocations];
}

- (void)applyFilter {
    if (self.sourceFilter == OTLocationsSourceFilterAll) {
        self.visibleLocations = self.allLocations;
    } else {
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(OTWebLocationItem *item, NSDictionary *bindings) {
            NSString *source = item.sourceType ?: @"";
            if (self.sourceFilter == OTLocationsSourceFilterCustom) return [source isEqualToString:@"Custom"];
            if (self.sourceFilter == OTLocationsSourceFilterZone) return [source isEqualToString:@"Zone"];
            if (self.sourceFilter == OTLocationsSourceFilterDestination) return [source isEqualToString:@"Destination"];
            if (self.sourceFilter == OTLocationsSourceFilterReverseGeocode) return [source isEqualToString:@"GeoLocation"];
            return source.length == 0 || (![source isEqualToString:@"Custom"] &&
                                          ![source isEqualToString:@"Zone"] &&
                                          ![source isEqualToString:@"Destination"] &&
                                          ![source isEqualToString:@"GeoLocation"]);
        }];
        self.visibleLocations = [self.allLocations filteredArrayUsingPredicate:predicate];
    }
    [self updateTileButtons];
    [self.tableView reloadData];
}

- (void)reloadLocations {
    [[LocationAPISyncService sharedInstance] fetchGeolocationCacheWithCompletion:^(NSArray<OTWebLocationItem *> * _Nullable locations, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.refreshControl endRefreshing];
            if (error) {
                DDLogWarn(@"[OTLocations] fetch failed: %@", error.localizedDescription);
                return;
            }
            self.allLocations = locations ?: @[];
            [self applyFilter];
        });
    }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibleLocations.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LocationCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"LocationCell"];
    }
    OTWebLocationItem *item = self.visibleLocations[(NSUInteger)indexPath.row];
    cell.textLabel.numberOfLines = 1;
    NSString *source = item.sourceType.length > 0 ? item.sourceType : @"Other";
    if ([source isEqualToString:@"GeoLocation"]) {
        source = @"Reverse Geocode";
    }
    cell.textLabel.text = item.displayName;
    if (item.sourceDeviceName.length > 0) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", source, item.sourceDeviceName];
    } else if (item.originalDisplayName.length > 0 && ![item.originalDisplayName isEqualToString:item.displayName]) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", source, item.originalDisplayName];
    } else {
        cell.detailTextLabel.text = source;
    }
    cell.accessoryType = item.mapsUrl.length > 0 ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    OTWebLocationItem *item = self.visibleLocations[(NSUInteger)indexPath.row];
    OTLocationDetailsViewController *details = [[OTLocationDetailsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    details.locationItem = item;
    __weak typeof(self) weakSelf = self;
    details.showOnMapHandler = ^(OTWebLocationItem *selectedItem) {
        __strong typeof(weakSelf) sself = weakSelf;
        if (!sself) {
            return;
        }
        [sself navigateToMapForLocation:selectedItem];
    };
    [self.navigationController pushViewController:details animated:YES];
}

- (void)attemptDeleteLocation:(OTWebLocationItem *)item replacementZoneId:(NSNumber *)replacementZoneId {
    __weak typeof(self) weakSelf = self;
    [[LocationAPISyncService sharedInstance] deleteGeolocationCacheLocationId:item.locationId
                                                             replacementZoneId:replacementZoneId
                                                                    completion:^(NSInteger updatedReferences, NSNumber * _Nullable echoedReplacementZoneId, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) sself = weakSelf;
            if (!sself) {
                return;
            }
            if (!error) {
                NSMutableArray<OTWebLocationItem *> *updated = [sself.allLocations mutableCopy];
                NSIndexSet *indexes = [updated indexesOfObjectsPassingTest:^BOOL(OTWebLocationItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                    return obj.locationId == item.locationId;
                }];
                if (indexes.count > 0) {
                    [updated removeObjectsAtIndexes:indexes];
                }
                sself.allLocations = [updated copy];
                [sself applyFilter];
                return;
            }

            NSString *errorCode = error.userInfo[OTLocationDeleteErrorCodeKey];
            if ([errorCode isEqualToString:@"REFERENCES_EXIST_REQUIRES_REPLACEMENT"]) {
                UIAlertController *picker = [UIAlertController alertControllerWithTitle:@"Replacement Required"
                                                                                 message:error.localizedDescription
                                                                          preferredStyle:UIAlertControllerStyleActionSheet];
                NSArray<OTWebLocationItem *> *zoneCandidates = [sself.allLocations filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(OTWebLocationItem *location, NSDictionary *bindings) {
                    return location.locationId != item.locationId && [location.sourceType isEqualToString:@"Zone"];
                }]];
                for (OTWebLocationItem *candidate in zoneCandidates) {
                    [picker addAction:[UIAlertAction actionWithTitle:candidate.displayName
                                                                style:UIAlertActionStyleDefault
                                                              handler:^(UIAlertAction * _Nonnull action) {
                        [sself attemptDeleteLocation:item replacementZoneId:@(candidate.locationId)];
                    }]];
                }
                [picker addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
                [sself presentViewController:picker animated:YES completion:nil];
                return;
            }

            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete Failed"
                                                                           message:error.localizedDescription
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [sself presentViewController:alert animated:YES completion:nil];
        });
    }];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    OTWebLocationItem *item = self.visibleLocations[(NSUInteger)indexPath.row];
    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                                title:@"Delete"
                                                                              handler:^(__kindof UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Delete Location?"
                                                                         message:[NSString stringWithFormat:@"Delete \"%@\"?", item.displayName]
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            completionHandler(NO);
        }]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            [self attemptDeleteLocation:item replacementZoneId:nil];
            completionHandler(YES);
        }]];
        [self presentViewController:confirm animated:YES completion:nil];
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
}

@end

typedef NS_ENUM(NSInteger, OTInboxTypeFilter) {
    OTInboxTypeFilterAll = 0,
    OTInboxTypeFilterZoneTransition,
    OTInboxTypeFilterTrip,
    OTInboxTypeFilterUserLogin,
    OTInboxTypeFilterSpeedAlert
};

@interface OTInboxTableViewCell : UITableViewCell
@property (nonatomic, strong) UIButton *checkboxButton;
@property (nonatomic, strong) UIImageView *avatarView;
@property (nonatomic, strong) UILabel *chipLabel;
@property (nonatomic, strong) UIView *unreadDotView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, copy) void (^checkboxTapped)(void);
@end

@implementation OTInboxTableViewCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _checkboxButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _checkboxButton.translatesAutoresizingMaskIntoConstraints = NO;
        [_checkboxButton setImage:[UIImage systemImageNamed:@"square"] forState:UIControlStateNormal];
        [_checkboxButton addTarget:self action:@selector(checkboxPressed) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_checkboxButton];

        _avatarView = [[UIImageView alloc] init];
        _avatarView.translatesAutoresizingMaskIntoConstraints = NO;
        _avatarView.clipsToBounds = YES;
        _avatarView.layer.cornerRadius = 18.0;
        _avatarView.contentMode = UIViewContentModeScaleAspectFill;
        [self.contentView addSubview:_avatarView];

        _chipLabel = [[UILabel alloc] init];
        _chipLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _chipLabel.textColor = UIColor.whiteColor;
        _chipLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        _chipLabel.backgroundColor = [UIColor systemBlueColor];
        _chipLabel.layer.cornerRadius = 10.0;
        _chipLabel.clipsToBounds = YES;
        _chipLabel.textAlignment = NSTextAlignmentCenter;
        [self.contentView addSubview:_chipLabel];

        _unreadDotView = [[UIView alloc] init];
        _unreadDotView.translatesAutoresizingMaskIntoConstraints = NO;
        _unreadDotView.backgroundColor = [UIColor systemBlueColor];
        _unreadDotView.layer.cornerRadius = 4.0;
        [self.contentView addSubview:_unreadDotView];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        _titleLabel.numberOfLines = 2;
        [self.contentView addSubview:_titleLabel];

        _subtitleLabel = [[UILabel alloc] init];
        _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _subtitleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
        _subtitleLabel.textColor = [UIColor secondaryLabelColor];
        _subtitleLabel.numberOfLines = 2;
        [self.contentView addSubview:_subtitleLabel];

        _timeLabel = [[UILabel alloc] init];
        _timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _timeLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        _timeLabel.textColor = [UIColor tertiaryLabelColor];
        [self.contentView addSubview:_timeLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_checkboxButton.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12.0],
            [_checkboxButton.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_checkboxButton.widthAnchor constraintEqualToConstant:24.0],
            [_checkboxButton.heightAnchor constraintEqualToConstant:24.0],

            [_avatarView.leadingAnchor constraintEqualToAnchor:_checkboxButton.trailingAnchor constant:10.0],
            [_avatarView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12.0],
            [_avatarView.widthAnchor constraintEqualToConstant:36.0],
            [_avatarView.heightAnchor constraintEqualToConstant:36.0],

            [_chipLabel.leadingAnchor constraintEqualToAnchor:_avatarView.trailingAnchor constant:10.0],
            [_chipLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10.0],
            [_chipLabel.heightAnchor constraintEqualToConstant:20.0],
            [_chipLabel.widthAnchor constraintGreaterThanOrEqualToConstant:72.0],

            [_unreadDotView.leadingAnchor constraintEqualToAnchor:_chipLabel.trailingAnchor constant:8.0],
            [_unreadDotView.centerYAnchor constraintEqualToAnchor:_chipLabel.centerYAnchor],
            [_unreadDotView.widthAnchor constraintEqualToConstant:8.0],
            [_unreadDotView.heightAnchor constraintEqualToConstant:8.0],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_avatarView.trailingAnchor constant:10.0],
            [_titleLabel.topAnchor constraintEqualToAnchor:_chipLabel.bottomAnchor constant:6.0],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12.0],

            [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2.0],
            [_subtitleLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],

            [_timeLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_timeLabel.topAnchor constraintEqualToAnchor:_subtitleLabel.bottomAnchor constant:4.0],
            [_timeLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10.0],
            [_timeLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor]
        ]];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.avatarView.image = [UIImage systemImageNamed:@"person.crop.circle.fill"];
    self.checkboxTapped = nil;
}

- (void)checkboxPressed {
    if (self.checkboxTapped) {
        self.checkboxTapped();
    }
}

@end

@interface OTInboxViewController : UITableViewController
@property (nonatomic, strong) OTWebNotificationsPage *page;
@property (nonatomic) BOOL includeRead;
@property (nonatomic) OTInboxTypeFilter typeFilter;
@property (nonatomic) NSInteger skip;
@property (nonatomic) NSInteger take;
@property (nonatomic, copy) void (^badgeUpdateBlock)(NSInteger count);
@property (nonatomic, strong) NSMutableSet<NSNumber *> *selectedNotificationIDs;
@property (nonatomic, strong) NSRelativeDateTimeFormatter *relativeFormatter;
@end

@implementation OTInboxViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Inbox";
    self.take = 50;
    self.includeRead = NO;
    self.typeFilter = OTInboxTypeFilterAll;
    self.page = [[OTWebNotificationsPage alloc] init];
    self.page.notifications = @[];
    self.selectedNotificationIDs = [NSMutableSet set];
    self.relativeFormatter = [[NSRelativeDateTimeFormatter alloc] init];
    self.relativeFormatter.unitsStyle = NSRelativeDateTimeFormatterUnitsStyleFull;

    [self.tableView registerClass:[OTInboxTableViewCell class] forCellReuseIdentifier:@"InboxCell"];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 96.0;
    self.tableView.allowsMultipleSelectionDuringEditing = YES;
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(reloadPage) forControlEvents:UIControlEventValueChanged];
    [self rebuildNavButtons];
    [self reloadPage];
}

- (NSString *)displayNameForNotification:(OTWebNotificationItem *)item {
    NSArray<NSString *> *keys = @[ @"deviceName", @"DeviceName", @"personName", @"PersonName", @"name", @"Name", @"username", @"userName", @"UserName", @"user", @"User", @"Device" ];
    for (NSString *expectedKey in keys) {
        id value = item.dataDictionary[expectedKey];
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
            return (NSString *)value;
        }
        for (NSString *actualKey in item.dataDictionary) {
            if (![actualKey isKindOfClass:[NSString class]]) {
                continue;
            }
            if ([actualKey caseInsensitiveCompare:expectedKey] != NSOrderedSame) {
                continue;
            }
            id ciValue = item.dataDictionary[actualKey];
            if ([ciValue isKindOfClass:[NSString class]] && [(NSString *)ciValue length] > 0) {
                return (NSString *)ciValue;
            }
        }
    }
    return nil;
}

- (UIColor *)chipColorForType:(NSString *)type {
    if ([type isEqualToString:@"ZoneTransition"] || [type isEqualToString:@"ZoneChanged"]) {
        return [UIColor systemBlueColor];
    }
    if ([type isEqualToString:@"UserLogin"]) {
        return [UIColor systemGreenColor];
    }
    if ([type isEqualToString:@"Trip"] || [type isEqualToString:@"Navigate"] || [type isEqualToString:@"DestinationArrival"]) {
        return [UIColor systemIndigoColor];
    }
    if ([type isEqualToString:@"SpeedAlert"]) {
        return [UIColor systemOrangeColor];
    }
    return [UIColor systemGrayColor];
}

- (NSString *)relativeTimeStringForDate:(NSDate *)date {
    if (!date) {
        return @"";
    }
    return [self.relativeFormatter localizedStringForDate:date relativeToDate:[NSDate date]];
}

- (UIImage *)placeholderAvatarForNotification:(OTWebNotificationItem *)item {
    NSString *name = [self displayNameForNotification:item] ?: item.title ?: @"";
    NSString *initial = name.length > 0 ? [[name substringToIndex:1] uppercaseString] : @"?";
    CGSize size = CGSizeMake(36, 36);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
        [[UIColor systemGray5Color] setFill];
        UIBezierPath *circle = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 36, 36)];
        [circle fill];
        NSDictionary *attrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold],
            NSForegroundColorAttributeName: [UIColor secondaryLabelColor]
        };
        CGSize textSize = [initial sizeWithAttributes:attrs];
        [initial drawAtPoint:CGPointMake((36 - textSize.width) / 2.0, (36 - textSize.height) / 2.0)
              withAttributes:attrs];
    }];
}

- (NSString *)imageValueForNotification:(OTWebNotificationItem *)item {
    NSArray<NSString *> *keys = @[
        @"deviceImage", @"deviceImageURL", @"deviceImageUrl",
        @"markerImage", @"markerImageURL", @"markerImageUrl",
        @"avatar", @"avatarUrl", @"avatarURL",
        @"image", @"imageUrl", @"imageURL",
        @"face", @"faceUrl", @"faceURL"
    ];
    for (NSString *expectedKey in keys) {
        id value = item.dataDictionary[expectedKey];
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
            return (NSString *)value;
        }
        for (NSString *actualKey in item.dataDictionary) {
            if (![actualKey isKindOfClass:[NSString class]]) {
                continue;
            }
            if ([actualKey caseInsensitiveCompare:expectedKey] != NSOrderedSame) {
                continue;
            }
            id ciValue = item.dataDictionary[actualKey];
            if ([ciValue isKindOfClass:[NSString class]] && [(NSString *)ciValue length] > 0) {
                return (NSString *)ciValue;
            }
        }
    }
    // Fallback for partially malformed JSON strings: pull image-like field via regex.
    if (item.dataString.length > 0) {
        NSError *regexErr = nil;
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\"(deviceImage|DeviceImage|deviceImageURL|DeviceImageURL|avatarUrl|AvatarUrl|imageUrl|ImageUrl|faceUrl|FaceUrl)\"\\s*:\\s*\"([^\"]+)\""
                                                                            options:0
                                                                              error:&regexErr];
        if (!regexErr && re) {
            NSTextCheckingResult *match = [re firstMatchInString:item.dataString options:0 range:NSMakeRange(0, item.dataString.length)];
            if (match.numberOfRanges >= 3) {
                NSString *val = [item.dataString substringWithRange:[match rangeAtIndex:2]];
                if (val.length > 0) {
                    return val;
                }
            }
        }
    }
    return nil;
}

- (void)applyIconForNotification:(OTWebNotificationItem *)item
                            cell:(OTInboxTableViewCell *)cell
                    notificationId:(NSInteger)notificationId {
    cell.avatarView.image = [self placeholderAvatarForNotification:item];
    NSString *imageValue = [self imageValueForNotification:item];
    if (imageValue.length == 0) {
        return;
    }
    UIImage *base64Image = [[UIImage alloc] initWithData:[[NSData alloc] initWithBase64EncodedString:imageValue options:0]];
    if (base64Image) {
        cell.avatarView.image = base64Image;
        return;
    }
    NSURL *url = nil;
    if ([imageValue hasPrefix:@"http://"] || [imageValue hasPrefix:@"https://"]) {
        url = [NSURL URLWithString:imageValue];
    } else if ([imageValue hasPrefix:@"/"]) {
        NSURL *origin = [WebAppURLResolver webAppOriginURLFromPreferenceInMOC:CoreData.sharedInstance.mainMOC];
        if (origin) {
            NSURLComponents *c = [NSURLComponents componentsWithURL:origin resolvingAgainstBaseURL:NO];
            c.path = imageValue;
            c.query = nil;
            c.fragment = nil;
            url = c.URL;
        }
    } else {
        // Handle relative path without leading slash.
        NSURL *origin = [WebAppURLResolver webAppOriginURLFromPreferenceInMOC:CoreData.sharedInstance.mainMOC];
        if (origin) {
            NSURLComponents *c = [NSURLComponents componentsWithURL:origin resolvingAgainstBaseURL:NO];
            c.path = [@"/" stringByAppendingString:imageValue];
            c.query = nil;
            c.fragment = nil;
            url = c.URL;
        }
    }
    if (!url) {
        return;
    }
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
    });
    UIImage *cached = [cache objectForKey:url.absoluteString];
    if (cached) {
        cell.avatarView.image = cached;
        return;
    }
    NSURL *finalURL = url;
    cell.avatarView.tag = notificationId;
    __weak OTInboxTableViewCell *weakCell = cell;
    [[LocationAPISyncService sharedInstance] performAuthenticatedGET:url completion:^(NSData * _Nullable data, NSError * _Nullable error) {
        if (error || data.length == 0) {
            return;
        }
        UIImage *img = [UIImage imageWithData:data];
        if (!img) {
            return;
        }
        [cache setObject:img forKey:finalURL.absoluteString];
        dispatch_async(dispatch_get_main_queue(), ^{
            OTInboxTableViewCell *strongCell = weakCell;
            if (!strongCell) {
                return;
            }
            if (strongCell.avatarView.tag == notificationId) {
                strongCell.avatarView.image = img;
            }
        });
    }];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self refreshBadge];
}

- (NSString *)selectedTypeString {
    switch (self.typeFilter) {
        case OTInboxTypeFilterZoneTransition: return @"ZoneTransition";
        case OTInboxTypeFilterTrip: return @"Trip";
        case OTInboxTypeFilterUserLogin: return @"UserLogin";
        case OTInboxTypeFilterSpeedAlert: return @"SpeedAlert";
        case OTInboxTypeFilterAll:
        default: return nil;
    }
}

- (NSString *)typeButtonTitle {
    switch (self.typeFilter) {
        case OTInboxTypeFilterZoneTransition: return @"Zone";
        case OTInboxTypeFilterTrip: return @"Trip";
        case OTInboxTypeFilterUserLogin: return @"Login";
        case OTInboxTypeFilterSpeedAlert: return @"Speed";
        case OTInboxTypeFilterAll:
        default: return @"All Types";
    }
}

- (void)rebuildNavButtons {
    self.navigationItem.leftBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:(self.includeRead ? @"All" : @"Unread")
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(toggleReadFilter)],
        [[UIBarButtonItem alloc] initWithTitle:[self typeButtonTitle]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(cycleTypeFilter)]
    ];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"Prev"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(prevPage)],
        [[UIBarButtonItem alloc] initWithTitle:@"Next"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(nextPage)],
        [[UIBarButtonItem alloc] initWithTitle:@"Actions"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(showActions)]
    ];
}

- (void)toggleReadFilter {
    self.includeRead = !self.includeRead;
    self.skip = 0;
    [self rebuildNavButtons];
    [self reloadPage];
}

- (void)cycleTypeFilter {
    self.typeFilter = (OTInboxTypeFilter)((self.typeFilter + 1) % 5);
    self.skip = 0;
    [self rebuildNavButtons];
    [self reloadPage];
}

- (void)prevPage {
    self.skip = MAX(0, self.skip - self.take);
    [self reloadPage];
}

- (void)nextPage {
    if (self.page.totalCount > 0 && self.skip + self.take >= self.page.totalCount) {
        return;
    }
    self.skip += self.take;
    [self reloadPage];
}

- (NSArray<NSNumber *> *)selectedNotificationIds {
    return [self.selectedNotificationIDs.allObjects copy];
}

- (void)showActions {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Inbox Actions"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Read All" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [[LocationAPISyncService sharedInstance] markAllNotificationsReadWithCompletion:^(NSError * _Nullable error) {
            [self reloadPage];
        }];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Bulk Read (Selected)" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [[LocationAPISyncService sharedInstance] bulkMarkNotificationsRead:[self selectedNotificationIds] completion:^(NSError * _Nullable error) {
            [self reloadPage];
        }];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Bulk Unread (Selected)" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [[LocationAPISyncService sharedInstance] bulkMarkNotificationsUnread:[self selectedNotificationIds] completion:^(NSError * _Nullable error) {
            [self reloadPage];
        }];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Bulk Delete (Selected)" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [[LocationAPISyncService sharedInstance] bulkDeleteNotifications:[self selectedNotificationIds] completion:^(NSError * _Nullable error) {
            self.skip = 0;
            [self reloadPage];
        }];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)refreshBadge {
    [[LocationAPISyncService sharedInstance] fetchUnreadNotificationCountWithCompletion:^(NSInteger count, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!error && self.badgeUpdateBlock) {
                self.badgeUpdateBlock(count);
            }
        });
    }];
}

- (void)reloadPage {
    NSString *type = [self selectedTypeString];
    [[LocationAPISyncService sharedInstance] fetchNotificationsWithSkip:self.skip
                                                                   take:self.take
                                                            includeRead:self.includeRead
                                                                   type:type
                                                             completion:^(OTWebNotificationsPage * _Nullable page, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.refreshControl endRefreshing];
            if (error) {
                DDLogWarn(@"[OTInbox] fetch failed: %@", error.localizedDescription);
                return;
            }
            self.page = page ?: [[OTWebNotificationsPage alloc] init];
            if (self.page.notifications == nil) {
                self.page.notifications = @[];
            }
            NSMutableSet<NSNumber *> *validIDs = [NSMutableSet set];
            for (OTWebNotificationItem *item in self.page.notifications) {
                [validIDs addObject:@(item.notificationIdValue)];
            }
            [self.selectedNotificationIDs intersectSet:validIDs];
            if (self.page.totalCount > 0 && self.skip >= self.page.totalCount) {
                self.skip = MAX(0, self.page.totalCount - self.take);
            }
            [self.tableView reloadData];
            [self refreshBadge];
        });
    }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.page.notifications.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    OTInboxTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"InboxCell" forIndexPath:indexPath];
    OTWebNotificationItem *item = self.page.notifications[(NSUInteger)indexPath.row];
    NSString *name = [self displayNameForNotification:item];
    NSString *eventText = item.summary.length > 0 ? item.summary : (item.title.length > 0 ? item.title : item.type);
    cell.titleLabel.text = name.length > 0 ? [NSString stringWithFormat:@"%@ %@", name, eventText] : eventText;
    cell.subtitleLabel.text = item.title.length > 0 && ![item.title isEqualToString:eventText] ? item.title : item.type;
    cell.timeLabel.text = [self relativeTimeStringForDate:item.createdAt];
    cell.chipLabel.text = [NSString stringWithFormat:@"  %@  ", item.type.length > 0 ? item.type : @"Unknown"];
    cell.chipLabel.backgroundColor = [self chipColorForType:item.type];
    cell.unreadDotView.hidden = item.isRead;

    NSNumber *notificationIdNumber = @(item.notificationIdValue);
    BOOL selected = [self.selectedNotificationIDs containsObject:notificationIdNumber];
    [cell.checkboxButton setImage:[UIImage systemImageNamed:(selected ? @"checkmark.square.fill" : @"square")]
                         forState:UIControlStateNormal];
    __weak typeof(self) weakSelf = self;
    cell.checkboxTapped = ^{
        __strong typeof(weakSelf) sself = weakSelf;
        if (!sself) {
            return;
        }
        if ([sself.selectedNotificationIDs containsObject:notificationIdNumber]) {
            [sself.selectedNotificationIDs removeObject:notificationIdNumber];
        } else {
            [sself.selectedNotificationIDs addObject:notificationIdNumber];
        }
        [sself.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    };

    [self applyIconForNotification:item cell:cell notificationId:item.notificationIdValue];
    return cell;
}

- (NSArray<UITableViewRowAction *> *)tableView:(UITableView *)tableView editActionsForRowAtIndexPath:(NSIndexPath *)indexPath {
    OTWebNotificationItem *item = self.page.notifications[(NSUInteger)indexPath.row];
    UITableViewRowAction *toggleRead = [UITableViewRowAction rowActionWithStyle:UITableViewRowActionStyleNormal
                                                                           title:(item.isRead ? @"Unread" : @"Read")
                                                                         handler:^(UITableViewRowAction * _Nonnull action, NSIndexPath * _Nonnull ip) {
        void (^finish)(NSError *) = ^(NSError *error) {
            [self reloadPage];
        };
        if (item.isRead) {
            [[LocationAPISyncService sharedInstance] markNotificationUnread:item.notificationIdValue completion:finish];
        } else {
            [[LocationAPISyncService sharedInstance] markNotificationRead:item.notificationIdValue completion:finish];
        }
    }];
    UITableViewRowAction *deleteAction = [UITableViewRowAction rowActionWithStyle:UITableViewRowActionStyleDestructive
                                                                             title:@"Delete"
                                                                           handler:^(UITableViewRowAction * _Nonnull action, NSIndexPath * _Nonnull ip) {
        [[LocationAPISyncService sharedInstance] deleteNotification:item.notificationIdValue completion:^(NSError * _Nullable error) {
            [self reloadPage];
        }];
    }];
    return @[deleteAction, toggleRead];
}

@end

@interface TabBarController ()
@property (strong, nonatomic) UIViewController *historyVC;
@property (strong, nonatomic) UIViewController *regionVC;
@property (strong, nonatomic) UIViewController *friendsVC;
@property (strong, nonatomic) UIViewController *locationsVC;
@property (strong, nonatomic) UIViewController *inboxVC;
@property (strong, nonatomic) NSArray<UIViewController *> *fixedBaseControllers;
@end

@implementation TabBarController

- (void)viewDidLoad {
    [super viewDidLoad];

    for (UIViewController *vc in self.viewControllers) {
        if (vc.tabBarItem.tag == 95) {
            self.friendsVC = vc;
        }
        if (vc.tabBarItem.tag == 96) {
            self.regionVC = vc;
        }
        if (vc.tabBarItem.tag == 97) {
            self.historyVC = vc;
        }
    }
    [self installParityTabsIfNeeded];
    self.fixedBaseControllers = [self.viewControllers copy];
    
    [[NSNotificationCenter defaultCenter]
     addObserverForName:@"reload"
     object:nil
     queue:[NSOperationQueue mainQueue]
     usingBlock:^(NSNotification *note){
        [self performSelectorOnMainThread:@selector(adjust)
                               withObject:nil
                            waitUntilDone:NO];
    }];
    [[NSNotificationCenter defaultCenter]
     addObserverForName:UIApplicationDidBecomeActiveNotification
     object:nil
     queue:[NSOperationQueue mainQueue]
     usingBlock:^(NSNotification *note){
        [self refreshInboxBadge];
    }];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self adjust];
}

- (void)adjust {
    NSMutableArray *viewControllers = [[NSMutableArray alloc] initWithArray:self.fixedBaseControllers ?: self.viewControllers];


    if (self.historyVC) {
        if ([Settings theMaximumHistoryInMOC:[CoreData sharedInstance].mainMOC]) {
            if (![viewControllers containsObject:self.historyVC]) {
                [viewControllers insertObject:self.historyVC
                                      atIndex:viewControllers.count];
            }
        } else {
            if ([viewControllers containsObject:self.historyVC]) {
                [viewControllers removeObject:self.historyVC];
            }
        }
    }
    
    if (self.regionVC) {
        if (![Settings theLockedInMOC:CoreData.sharedInstance.mainMOC]) {
            if (![viewControllers containsObject:self.regionVC]) {
                if ([viewControllers containsObject:self.historyVC]) {
                    [viewControllers insertObject:self.regionVC
                                          atIndex:viewControllers.count - 1];
                } else {
                    [viewControllers insertObject:self.regionVC
                                          atIndex:viewControllers.count];
                }
            }
        } else {
            if ([viewControllers containsObject:self.regionVC]) {
                [viewControllers removeObject:self.regionVC];
            }
        }
    }

    [self setViewControllers:viewControllers animated:FALSE];
}

- (void)installParityTabsIfNeeded {
    if (self.locationsVC && self.inboxVC) {
        return;
    }
    OTLocationsViewController *locations = [[OTLocationsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *locationsNav = [[UINavigationController alloc] initWithRootViewController:locations];
    locationsNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Locations"
                                                             image:[UIImage systemImageNamed:@"mappin.and.ellipse"]
                                                               tag:110];
    OTInboxViewController *inbox = [[OTInboxViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    __weak typeof(self) wself = self;
    inbox.badgeUpdateBlock = ^(NSInteger count) {
        __strong typeof(wself) sself = wself;
        if (!sself) {
            return;
        }
        sself.inboxVC.tabBarItem.badgeValue = count > 0 ? [NSString stringWithFormat:@"%ld", (long)count] : nil;
    };
    UINavigationController *inboxNav = [[UINavigationController alloc] initWithRootViewController:inbox];
    inboxNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Inbox"
                                                         image:[UIImage systemImageNamed:@"tray.full"]
                                                           tag:111];

    self.locationsVC = locationsNav;
    self.inboxVC = inboxNav;
    NSMutableArray *vcs = [NSMutableArray arrayWithArray:self.viewControllers ?: @[]];
    [vcs addObject:locationsNav];
    [vcs addObject:inboxNav];
    [self setViewControllers:vcs animated:NO];
}

- (void)refreshInboxBadge {
    [[LocationAPISyncService sharedInstance] fetchUnreadNotificationCountWithCompletion:^(NSInteger count, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!error && self.inboxVC) {
                self.inboxVC.tabBarItem.badgeValue = count > 0 ? [NSString stringWithFormat:@"%ld", (long)count] : nil;
            }
        });
    }];
}

@end
