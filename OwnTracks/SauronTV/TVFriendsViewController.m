//
//  TVFriendsViewController.m
//  SauronTV
//
//  Full-screen UITableView listing friends grouped by person.
//  Selecting a device switches to the Map tab and follows that device.
//

#import "TVFriendsViewController.h"
#import "TVAppDelegate.h"
#import "TVFriendStore.h"
#import "TVMapViewController.h"
#import <CocoaLumberjack/CocoaLumberjack.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

static NSString * const kAllFriendsCellId   = @"TVAllFriendsCell";
static NSString * const kPersonGroupCellId  = @"TVPersonGroupCell";
static NSString * const kDeviceCellId       = @"TVDeviceCell";

static const CGFloat kRowHeight       = 88.0;
static const CGFloat kPhotoSize       = 60.0;
static const CGFloat kDeviceIndent    = 30.0;
static const CGFloat kStatusIconSize  = 28.0;

typedef NS_ENUM(NSInteger, TVFriendRowType) {
    TVFriendRowTypeAllFriends,
    TVFriendRowTypePersonGroup,
    TVFriendRowTypeDevice,
};

@interface TVFriendRow : NSObject
@property (nonatomic) TVFriendRowType rowType;
@property (copy, nonatomic, nullable) NSString *personKey;
@property (copy, nonatomic, nullable) NSString *topic;
@end

@implementation TVFriendRow
@end

typedef NS_ENUM(NSInteger, TVMotionStatus) {
    TVMotionStatusUnknown,
    TVMotionStatusStationary,
    TVMotionStatusMoving,
    TVMotionStatusDriving,
};

static TVMotionStatus TVMotionStatusFromVelocityKmh(double velKmh) {
    if (velKmh < 0.0) {
        return TVMotionStatusUnknown;
    }
    if (velKmh < 0.5) {
        return TVMotionStatusStationary;
    }
    if (velKmh < 30.0) {
        return TVMotionStatusMoving;
    }
    return TVMotionStatusDriving;
}

static void TVApplyMotionStatusToImageView(UIImageView *statusView, double velKmh) {
    TVMotionStatus status = TVMotionStatusFromVelocityKmh(velKmh);
    NSString *symbol = @"figure.stand";
    UIColor *tint = [UIColor colorWithWhite:0.45 alpha:1.0];

    switch (status) {
        case TVMotionStatusUnknown:
        case TVMotionStatusStationary:
            symbol = @"figure.stand";
            tint = [UIColor colorWithWhite:0.45 alpha:1.0];
            break;
        case TVMotionStatusMoving:
            symbol = @"figure.walk";
            tint = UIColor.systemGreenColor;
            break;
        case TVMotionStatusDriving:
            symbol = @"car.fill";
            if (velKmh >= 130.0) {
                tint = UIColor.systemRedColor;
            } else if (velKmh >= 80.0) {
                tint = UIColor.systemYellowColor;
            } else {
                tint = UIColor.systemGreenColor;
            }
            break;
    }

    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:kStatusIconSize
                                                                                      weight:UIImageSymbolWeightSemibold];
    statusView.image = [UIImage systemImageNamed:symbol withConfiguration:cfg];
    statusView.tintColor = tint;
}

// ---------------------------------------------------------------------------
#pragma mark - TVDeviceCell

@interface TVDeviceCell : UITableViewCell
@property (strong, nonatomic) UIImageView *photoView;
@property (strong, nonatomic) UILabel     *nameLabel;
@property (strong, nonatomic) UILabel     *timeLabel;
@property (strong, nonatomic) UIImageView *statusView;
@end

@implementation TVDeviceCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseId {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseId])) {
        self.backgroundColor = UIColor.clearColor;

        _photoView = [[UIImageView alloc] init];
        _photoView.translatesAutoresizingMaskIntoConstraints = NO;
        _photoView.layer.cornerRadius = kPhotoSize / 2.0;
        _photoView.clipsToBounds      = YES;
        _photoView.contentMode        = UIViewContentModeScaleAspectFill;
        [self.contentView addSubview:_photoView];

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _nameLabel.textColor = UIColor.whiteColor;
        _nameLabel.font      = [UIFont systemFontOfSize:28.0 weight:UIFontWeightMedium];
        [self.contentView addSubview:_nameLabel];

        _timeLabel = [[UILabel alloc] init];
        _timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _timeLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
        _timeLabel.font      = [UIFont systemFontOfSize:22.0];
        [self.contentView addSubview:_timeLabel];

        _statusView = [[UIImageView alloc] init];
        _statusView.translatesAutoresizingMaskIntoConstraints = NO;
        _statusView.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentView addSubview:_statusView];

        const CGFloat pad = 20.0;
        const CGFloat gap = 14.0;

        [NSLayoutConstraint activateConstraints:@[
            [_photoView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                     constant:pad + kDeviceIndent],
            [_photoView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_photoView.widthAnchor constraintEqualToConstant:kPhotoSize],
            [_photoView.heightAnchor constraintEqualToConstant:kPhotoSize],

            [_nameLabel.leadingAnchor constraintEqualToAnchor:_photoView.trailingAnchor constant:gap],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_statusView.leadingAnchor constant:-gap],
            [_nameLabel.topAnchor constraintEqualToAnchor:_photoView.topAnchor constant:4.0],

            [_timeLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_timeLabel.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor],
            [_timeLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:4.0],

            [_statusView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-pad],
            [_statusView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_statusView.widthAnchor constraintEqualToConstant:kStatusIconSize + 8.0],
            [_statusView.heightAnchor constraintEqualToConstant:kStatusIconSize + 8.0],
        ]];
    }
    return self;
}

@end

// ---------------------------------------------------------------------------
#pragma mark - TVPersonGroupCell

@interface TVPersonGroupCell : UITableViewCell
@property (strong, nonatomic) UIImageView *photoView;
@property (strong, nonatomic) UILabel     *nameLabel;
@property (strong, nonatomic) UILabel     *countLabel;
@property (strong, nonatomic) UIImageView *chevronView;
@end

@implementation TVPersonGroupCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseId {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseId])) {
        self.backgroundColor = UIColor.clearColor;

        _photoView = [[UIImageView alloc] init];
        _photoView.translatesAutoresizingMaskIntoConstraints = NO;
        _photoView.layer.cornerRadius = kPhotoSize / 2.0;
        _photoView.clipsToBounds      = YES;
        _photoView.contentMode        = UIViewContentModeScaleAspectFill;
        [self.contentView addSubview:_photoView];

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _nameLabel.textColor = UIColor.whiteColor;
        _nameLabel.font      = [UIFont systemFontOfSize:30.0 weight:UIFontWeightSemibold];
        [self.contentView addSubview:_nameLabel];

        _countLabel = [[UILabel alloc] init];
        _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _countLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
        _countLabel.font      = [UIFont systemFontOfSize:22.0];
        [self.contentView addSubview:_countLabel];

        _chevronView = [[UIImageView alloc] init];
        _chevronView.translatesAutoresizingMaskIntoConstraints = NO;
        _chevronView.contentMode = UIViewContentModeScaleAspectFit;
        _chevronView.tintColor = [UIColor colorWithWhite:0.55 alpha:1.0];
        [self.contentView addSubview:_chevronView];

        const CGFloat pad = 20.0;
        const CGFloat gap = 14.0;

        [NSLayoutConstraint activateConstraints:@[
            [_photoView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:pad],
            [_photoView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_photoView.widthAnchor constraintEqualToConstant:kPhotoSize],
            [_photoView.heightAnchor constraintEqualToConstant:kPhotoSize],

            [_nameLabel.leadingAnchor constraintEqualToAnchor:_photoView.trailingAnchor constant:gap],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_chevronView.leadingAnchor constant:-gap],
            [_nameLabel.topAnchor constraintEqualToAnchor:_photoView.topAnchor constant:2.0],

            [_countLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_countLabel.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor],
            [_countLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:4.0],

            [_chevronView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-pad],
            [_chevronView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_chevronView.widthAnchor constraintEqualToConstant:24.0],
            [_chevronView.heightAnchor constraintEqualToConstant:24.0],
        ]];
    }
    return self;
}

- (void)setExpanded:(BOOL)expanded {
    NSString *symbol = expanded ? @"chevron.down" : @"chevron.right";
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:20.0
                                                                                      weight:UIImageSymbolWeightSemibold];
    self.chevronView.image = [UIImage systemImageNamed:symbol withConfiguration:cfg];
}

@end

// ---------------------------------------------------------------------------
#pragma mark - TVAllFriendsCell

@interface TVAllFriendsCell : UITableViewCell
@property (strong, nonatomic) UIImageView *photoView;
@property (strong, nonatomic) UILabel     *nameLabel;
@end

@implementation TVAllFriendsCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseId {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseId])) {
        self.backgroundColor = UIColor.clearColor;

        _photoView = [[UIImageView alloc] init];
        _photoView.translatesAutoresizingMaskIntoConstraints = NO;
        _photoView.layer.cornerRadius = kPhotoSize / 2.0;
        _photoView.clipsToBounds      = YES;
        _photoView.contentMode        = UIViewContentModeScaleAspectFill;
        [self.contentView addSubview:_photoView];

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _nameLabel.textColor = UIColor.whiteColor;
        _nameLabel.font      = [UIFont systemFontOfSize:28.0 weight:UIFontWeightMedium];
        [self.contentView addSubview:_nameLabel];

        const CGFloat pad = 20.0;
        const CGFloat gap = 14.0;

        [NSLayoutConstraint activateConstraints:@[
            [_photoView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:pad],
            [_photoView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_photoView.widthAnchor constraintEqualToConstant:kPhotoSize],
            [_photoView.heightAnchor constraintEqualToConstant:kPhotoSize],

            [_nameLabel.leadingAnchor constraintEqualToAnchor:_photoView.trailingAnchor constant:gap],
            [_nameLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-pad],
            [_nameLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        ]];
    }
    return self;
}

@end

// ---------------------------------------------------------------------------
#pragma mark - TVFriendsViewController

@interface TVFriendsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (strong, nonatomic) UITableView *tableView;
@property (strong, nonatomic) NSMutableArray<TVFriendRow *> *rows;
@property (strong, nonatomic) NSMutableSet<NSString *> *expandedPersonKeys;
@end

@implementation TVFriendsViewController

- (void)loadView {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.backgroundColor = UIColor.blackColor;
    self.view = self.tableView;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.rows = [NSMutableArray array];
    self.expandedPersonKeys = [NSMutableSet set];

    self.tableView.dataSource = self;
    self.tableView.delegate   = self;
    self.tableView.rowHeight  = kRowHeight;
    [self.tableView registerClass:[TVAllFriendsCell class] forCellReuseIdentifier:kAllFriendsCellId];
    [self.tableView registerClass:[TVPersonGroupCell class] forCellReuseIdentifier:kPersonGroupCellId];
    [self.tableView registerClass:[TVDeviceCell class] forCellReuseIdentifier:kDeviceCellId];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(storeUpdated:)
               name:TVFriendStoreDidUpdateNotification
             object:nil];

    [self rebuildRowsPreservingExpansion:YES];
    DDLogInfo(@"[TVFriendsViewController] viewDidLoad");
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    TVAppDelegate *app = (TVAppDelegate *)UIApplication.sharedApplication.delegate;
    [app refreshLocationAllowlistPresentingSignInFrom:self completion:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)storeUpdated:(NSNotification *)note {
    NSString *change = note.userInfo[@"change"];
    if ([change isEqualToString:@"new"] || [change isEqualToString:@"card"]
        || [change isEqualToString:@"allowlist"]) {
        [self rebuildRowsPreservingExpansion:YES];
        [self.tableView reloadData];
        return;
    }

    NSString *topic = note.userInfo[@"topic"];
    if (!topic.length) {
        [self.tableView reloadData];
        return;
    }

    NSInteger rowIndex = [self rowIndexForTopic:topic];
    if (rowIndex != NSNotFound) {
        [self configureDeviceRowAtIndex:rowIndex topic:topic];
        NSIndexPath *ip = [NSIndexPath indexPathForRow:rowIndex inSection:0];
        [self.tableView reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)rebuildRowsPreservingExpansion:(BOOL)preserveExpansion {
    NSMutableSet<NSString *> *previousExpanded = preserveExpansion ? [self.expandedPersonKeys mutableCopy] : nil;
    [self.rows removeAllObjects];

    TVFriendRow *allRow = [[TVFriendRow alloc] init];
    allRow.rowType = TVFriendRowTypeAllFriends;
    [self.rows addObject:allRow];

    TVFriendStore *store = [TVFriendStore shared];
    NSArray<NSString *> *personKeys = store.personKeys;

    if (personKeys.count == 0) {
        for (NSString *topic in store.friendTopics) {
            TVFriendRow *deviceRow = [[TVFriendRow alloc] init];
            deviceRow.rowType = TVFriendRowTypeDevice;
            deviceRow.topic = topic;
            [self.rows addObject:deviceRow];
        }
        return;
    }

    [self.expandedPersonKeys removeAllObjects];
    for (NSString *personKey in personKeys) {
        if (preserveExpansion && [previousExpanded containsObject:personKey]) {
            [self.expandedPersonKeys addObject:personKey];
        }

        TVFriendRow *groupRow = [[TVFriendRow alloc] init];
        groupRow.rowType = TVFriendRowTypePersonGroup;
        groupRow.personKey = personKey;
        [self.rows addObject:groupRow];

        if ([self.expandedPersonKeys containsObject:personKey]) {
            for (NSString *topic in [store topicsForPersonKey:personKey]) {
                TVFriendRow *deviceRow = [[TVFriendRow alloc] init];
                deviceRow.rowType = TVFriendRowTypeDevice;
                deviceRow.topic = topic;
                deviceRow.personKey = personKey;
                [self.rows addObject:deviceRow];
            }
        }
    }
}

- (NSInteger)rowIndexForTopic:(NSString *)topic {
    for (NSUInteger i = 0; i < self.rows.count; i++) {
        TVFriendRow *row = self.rows[i];
        if (row.rowType == TVFriendRowTypeDevice && [row.topic isEqualToString:topic]) {
            return (NSInteger)i;
        }
    }
    return NSNotFound;
}

- (NSArray<TVFriendRow *> *)deviceRowsForPersonKey:(NSString *)personKey {
    NSMutableArray<TVFriendRow *> *deviceRows = [NSMutableArray array];
    for (NSString *topic in [[TVFriendStore shared] topicsForPersonKey:personKey]) {
        TVFriendRow *deviceRow = [[TVFriendRow alloc] init];
        deviceRow.rowType = TVFriendRowTypeDevice;
        deviceRow.topic = topic;
        deviceRow.personKey = personKey;
        [deviceRows addObject:deviceRow];
    }
    return deviceRows;
}

- (NSUInteger)deviceRowCountForPersonKey:(NSString *)personKey afterGroupRow:(NSUInteger)groupRow {
    NSUInteger count = 0;
    for (NSUInteger i = groupRow + 1; i < self.rows.count; i++) {
        TVFriendRow *row = self.rows[i];
        if (row.rowType != TVFriendRowTypeDevice || ![row.personKey isEqualToString:personKey]) {
            break;
        }
        count++;
    }
    return count;
}

- (void)expandPersonKey:(NSString *)personKey atGroupRow:(NSInteger)groupRow {
    if ([self.expandedPersonKeys containsObject:personKey]) {
        return;
    }
    NSArray<TVFriendRow *> *deviceRows = [self deviceRowsForPersonKey:personKey];
    if (deviceRows.count == 0) {
        return;
    }

    [self.expandedPersonKeys addObject:personKey];
    NSUInteger insertIndex = (NSUInteger)groupRow + 1;
    NSIndexSet *indexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(insertIndex, deviceRows.count)];
    [self.rows insertObjects:deviceRows atIndexes:indexes];

    NSMutableArray<NSIndexPath *> *insertPaths = [NSMutableArray arrayWithCapacity:deviceRows.count];
    for (NSUInteger i = 0; i < deviceRows.count; i++) {
        [insertPaths addObject:[NSIndexPath indexPathForRow:(NSInteger)(insertIndex + i) inSection:0]];
    }
    NSIndexPath *groupPath = [NSIndexPath indexPathForRow:groupRow inSection:0];

    [self.tableView performBatchUpdates:^{
        [self.tableView insertRowsAtIndexPaths:insertPaths withRowAnimation:UITableViewRowAnimationTop];
        [self.tableView reloadRowsAtIndexPaths:@[groupPath] withRowAnimation:UITableViewRowAnimationNone];
    } completion:nil];
}

- (void)collapsePersonKey:(NSString *)personKey atGroupRow:(NSInteger)groupRow {
    if (![self.expandedPersonKeys containsObject:personKey]) {
        return;
    }
    NSUInteger deviceCount = [self deviceRowCountForPersonKey:personKey afterGroupRow:(NSUInteger)groupRow];
    if (deviceCount == 0) {
        [self.expandedPersonKeys removeObject:personKey];
        return;
    }

    [self.expandedPersonKeys removeObject:personKey];
    NSUInteger deleteIndex = (NSUInteger)groupRow + 1;
    NSRange deleteRange = NSMakeRange(deleteIndex, deviceCount);
    [self.rows removeObjectsInRange:deleteRange];

    NSMutableArray<NSIndexPath *> *deletePaths = [NSMutableArray arrayWithCapacity:deviceCount];
    for (NSUInteger i = 0; i < deviceCount; i++) {
        [deletePaths addObject:[NSIndexPath indexPathForRow:(NSInteger)(deleteIndex + i) inSection:0]];
    }
    NSIndexPath *groupPath = [NSIndexPath indexPathForRow:groupRow inSection:0];

    [self.tableView performBatchUpdates:^{
        [self.tableView deleteRowsAtIndexPaths:deletePaths withRowAnimation:UITableViewRowAnimationTop];
        [self.tableView reloadRowsAtIndexPaths:@[groupPath] withRowAnimation:UITableViewRowAnimationNone];
    } completion:nil];
}

- (void)configureDeviceRowAtIndex:(NSInteger)index topic:(NSString *)topic {
    NSIndexPath *ip = [NSIndexPath indexPathForRow:index inSection:0];
    TVDeviceCell *cell = (TVDeviceCell *)[self.tableView cellForRowAtIndexPath:ip];
    if (![cell isKindOfClass:[TVDeviceCell class]]) {
        return;
    }
    TVFriendStore *store = [TVFriendStore shared];
    cell.photoView.image = [store imageForTopic:topic];
    cell.nameLabel.text  = store.friendLabels[topic] ?: [topic lastPathComponent];
    cell.timeLabel.text  = store.friendTimes[topic];
    TVApplyMotionStatusToImageView(cell.statusView, [store velocityKmhForTopic:topic]);
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    TVFriendRow *row = self.rows[(NSUInteger)ip.row];
    TVFriendStore *store = [TVFriendStore shared];

    switch (row.rowType) {
        case TVFriendRowTypeAllFriends: {
            TVAllFriendsCell *cell = [tv dequeueReusableCellWithIdentifier:kAllFriendsCellId forIndexPath:ip];
            cell.photoView.image = [store imageForTopic:@"__all__"];
            cell.nameLabel.text  = @"All Friends";
            return cell;
        }
        case TVFriendRowTypePersonGroup: {
            TVPersonGroupCell *cell = [tv dequeueReusableCellWithIdentifier:kPersonGroupCellId forIndexPath:ip];
            NSString *personKey = row.personKey;
            NSArray<NSString *> *topics = [store topicsForPersonKey:personKey];
            cell.nameLabel.text = [store displayNameForPersonKey:personKey];
            NSUInteger count = topics.count;
            cell.countLabel.text = count == 1 ? @"1 device" : [NSString stringWithFormat:@"%lu devices", (unsigned long)count];
            NSString *firstTopic = topics.firstObject;
            cell.photoView.image = firstTopic.length ? [store imageForTopic:firstTopic] : [store imageForTopic:@"__unknown__"];
            [cell setExpanded:[self.expandedPersonKeys containsObject:personKey]];
            return cell;
        }
        case TVFriendRowTypeDevice: {
            TVDeviceCell *cell = [tv dequeueReusableCellWithIdentifier:kDeviceCellId forIndexPath:ip];
            NSString *topic = row.topic;
            cell.photoView.image = [store imageForTopic:topic];
            cell.nameLabel.text  = store.friendLabels[topic] ?: [topic lastPathComponent];
            cell.timeLabel.text  = store.friendTimes[topic];
            TVApplyMotionStatusToImageView(cell.statusView, [store velocityKmhForTopic:topic]);
            return cell;
        }
    }
    return [[UITableViewCell alloc] init];
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    TVFriendRow *row = self.rows[(NSUInteger)ip.row];

    if (row.rowType == TVFriendRowTypePersonGroup) {
        NSString *personKey = row.personKey;
        TVFriendStore *store = [TVFriendStore shared];
        NSArray<NSString *> *topics = [store topicsForPersonKey:personKey];

        if (topics.count == 1) {
            UITabBarController *tabs = (UITabBarController *)self.tabBarController;
            TVMapViewController *mapVC = (TVMapViewController *)tabs.viewControllers[0];
            [mapVC selectFriendByTopic:topics.firstObject];
            tabs.selectedIndex = 0;
            DDLogInfo(@"[TVFriendsViewController] selected person %@ → device %@", personKey, topics.firstObject);
            return;
        }

        NSInteger groupRow = ip.row;
        if ([self.expandedPersonKeys containsObject:personKey]) {
            [self collapsePersonKey:personKey atGroupRow:groupRow];
        } else {
            [self expandPersonKey:personKey atGroupRow:groupRow];
        }
        return;
    }

    NSString *topic = nil;
    if (row.rowType == TVFriendRowTypeDevice) {
        topic = row.topic;
    }

    UITabBarController *tabs = (UITabBarController *)self.tabBarController;
    TVMapViewController *mapVC = (TVMapViewController *)tabs.viewControllers[0];
    [mapVC selectFriendByTopic:topic];
    tabs.selectedIndex = 0;

    DDLogInfo(@"[TVFriendsViewController] selected %@", topic ?: @"(all)");
}

@end
