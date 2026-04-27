//
//  TVFriendsViewController.m
//  SauronTV
//
//  Full-screen UITableView listing all MQTT-tracked friends.
//  Selecting a row switches to the Map tab and zooms to that friend.
//

#import "TVFriendsViewController.h"
#import "TVAppDelegate.h"
#import "TVFriendStore.h"
#import "TVMapViewController.h"
#import <CocoaLumberjack/CocoaLumberjack.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

static NSString * const kCellId     = @"TVFriendCell";
static const CGFloat    kCellHeight = 88.0;
static const CGFloat    kPhotoSize  = 60.0;

// ---------------------------------------------------------------------------
#pragma mark - TVFriendCell

@interface TVFriendCell : UITableViewCell
@property (strong, nonatomic) UIImageView *photoView;
@property (strong, nonatomic) UILabel     *nameLabel;
@property (strong, nonatomic) UILabel     *timeLabel;
@end

@implementation TVFriendCell

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

        const CGFloat pad  = 20.0;
        const CGFloat gap  = 14.0;

        [NSLayoutConstraint activateConstraints:@[
            // Photo: left-aligned, vertically centred
            [_photoView.leadingAnchor  constraintEqualToAnchor:self.contentView.leadingAnchor constant:pad],
            [_photoView.centerYAnchor  constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_photoView.widthAnchor    constraintEqualToConstant:kPhotoSize],
            [_photoView.heightAnchor   constraintEqualToConstant:kPhotoSize],

            // Name: right of photo
            [_nameLabel.leadingAnchor  constraintEqualToAnchor:_photoView.trailingAnchor constant:gap],
            [_nameLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-pad],
            [_nameLabel.topAnchor      constraintEqualToAnchor:_photoView.topAnchor constant:4.0],

            // Time: below name
            [_timeLabel.leadingAnchor  constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_timeLabel.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor],
            [_timeLabel.topAnchor      constraintEqualToAnchor:_nameLabel.bottomAnchor constant:4.0],
        ]];
    }
    return self;
}

@end

// ---------------------------------------------------------------------------
#pragma mark - TVFriendsViewController

@interface TVFriendsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (strong, nonatomic) UITableView *tableView;
@end

@implementation TVFriendsViewController

- (void)loadView {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.backgroundColor = UIColor.blackColor;
    self.view = self.tableView;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.tableView.dataSource = self;
    self.tableView.delegate   = self;
    self.tableView.rowHeight  = kCellHeight;
    [self.tableView registerClass:[TVFriendCell class] forCellReuseIdentifier:kCellId];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(storeUpdated:)
               name:TVFriendStoreDidUpdateNotification
             object:nil];

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
    NSString *topic  = note.userInfo[@"topic"];

    if ([change isEqualToString:@"new"] || [change isEqualToString:@"card"]
        || [change isEqualToString:@"allowlist"]) {
        // Full reload: new friend changes row count; card may change label and sort order.
        [self.tableView reloadData];
    } else {
        // Refresh only the affected row.
        NSUInteger idx = [[TVFriendStore shared].friendTopics indexOfObject:topic];
        if (idx != NSNotFound) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:(NSInteger)idx + 1 inSection:0];
            [self.tableView reloadRowsAtIndexPaths:@[ip]
                                 withRowAnimation:UITableViewRowAnimationNone];
        }
    }
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return 1 + (NSInteger)[TVFriendStore shared].friendTopics.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    TVFriendCell *cell = [tv dequeueReusableCellWithIdentifier:kCellId forIndexPath:ip];

    if (ip.row == 0) {
        cell.photoView.image = [[TVFriendStore shared] imageForTopic:@"__all__"];
        cell.nameLabel.text  = @"All Friends";
        cell.timeLabel.text  = nil;
        cell.accessoryType   = UITableViewCellAccessoryNone;
    } else {
        TVFriendStore *store = [TVFriendStore shared];
        NSString *topic = store.friendTopics[(NSUInteger)(ip.row - 1)];
        cell.photoView.image = [store imageForTopic:topic];
        cell.nameLabel.text  = store.friendLabels[topic] ?: [topic lastPathComponent];
        cell.timeLabel.text  = store.friendTimes[topic];
        cell.accessoryType   = UITableViewCellAccessoryNone;
    }
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    NSString *topic = nil;
    if (ip.row > 0) {
        topic = [TVFriendStore shared].friendTopics[(NSUInteger)(ip.row - 1)];
    }

    // Delegate to the map VC and switch to the Map tab.
    UITabBarController *tabs = (UITabBarController *)self.tabBarController;
    TVMapViewController *mapVC = (TVMapViewController *)tabs.viewControllers[0];
    [mapVC selectFriendByTopic:topic];
    tabs.selectedIndex = 0;

    DDLogInfo(@"[TVFriendsViewController] selected %@", topic ?: @"(all)");
}

@end
