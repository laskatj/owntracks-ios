//
//  TVRecorderAuthViewController.m
//  SauronTV
//

#import "TVRecorderAuthViewController.h"
#import "TVRecorderOAuthClient.h"
#import "TVRecorderTokenStore.h"
#import "TVRecorderDeviceSignInViewController.h"
#import "TVHardcodedConfig.h"
#import <CocoaLumberjack/CocoaLumberjack.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

@interface TVRecorderAuthViewController ()
@property (strong, nonatomic) UILabel *statusLabel;
@property (strong, nonatomic) UIButton *signInButton;
@property (strong, nonatomic) UIButton *signOutButton;
@end

@implementation TVRecorderAuthViewController

- (void)loadView {
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = UIColor.blackColor;
    self.view = v;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(refreshStatus)
               name:TVRecorderOAuthTokensDidChangeNotification
             object:nil];

    _statusLabel = [[UILabel alloc] init];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.textColor = UIColor.whiteColor;
    _statusLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightRegular];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.numberOfLines = 0;
    [self.view addSubview:_statusLabel];

    _signInButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _signInButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_signInButton setTitle:@"Sign in with device code" forState:UIControlStateNormal];
    _signInButton.titleLabel.font = [UIFont systemFontOfSize:32 weight:UIFontWeightSemibold];
    [_signInButton addTarget:self action:@selector(signInTapped) forControlEvents:UIControlEventPrimaryActionTriggered];
    [self.view addSubview:_signInButton];

    _signOutButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _signOutButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_signOutButton setTitle:@"Sign out" forState:UIControlStateNormal];
    _signOutButton.titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightRegular];
    [_signOutButton addTarget:self action:@selector(signOutTapped) forControlEvents:UIControlEventPrimaryActionTriggered];
    [self.view addSubview:_signOutButton];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_statusLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-80],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:48],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-48],

        [_signInButton.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:40],
        [_signInButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],

        [_signOutButton.topAnchor constraintEqualToAnchor:_signInButton.bottomAnchor constant:32],
        [_signOutButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    ]];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshStatus];
}

- (void)refreshStatus {
    if (kTVWebAppBearerToken.length) {
        self.statusLabel.text = @"Using dev bearer token from config.";
        self.signInButton.enabled = NO;
        self.signOutButton.enabled = NO;
        DDLogInfo(@"[TVRecorderAuth] status: dev bearer override");
        return;
    }
    self.signInButton.enabled = YES;
    self.signOutButton.enabled = YES;
    if (!kTVOAuthDiscoveryURL.length || !kTVOAuthClientId.length) {
        self.statusLabel.text = @"Recorder OAuth is not configured (discovery URL and client id).";
        self.signInButton.enabled = NO;
        DDLogInfo(@"[TVRecorderAuth] status: OAuth not configured (discovery=%d clientId=%d)",
                  kTVOAuthDiscoveryURL.length > 0, kTVOAuthClientId.length > 0);
        return;
    }
    BOOL usable = [TVRecorderTokenStore hasUsableAccessToken];
    BOOL hasAccess = [TVRecorderTokenStore accessToken].length > 0;
    BOOL hasRefresh = [TVRecorderTokenStore refreshToken].length > 0;
    NSTimeInterval exp = [TVRecorderTokenStore accessTokenExpiry];
    DDLogInfo(@"[TVRecorderAuth] status: usable=%d hasAccess=%d hasRefresh=%d exp=%.0f now=%.0f",
              usable, hasAccess, hasRefresh, exp, [NSDate date].timeIntervalSince1970);

    if (usable) {
        self.statusLabel.text = @"Signed in. Route history will load when you follow a friend.";
    } else if (hasRefresh) {
        self.statusLabel.text = @"Access token expired; refresh will run when needed, or sign in again.";
    } else if (hasAccess) {
        self.statusLabel.text = @"Access token present but expired; sign in again or wait for a route fetch to refresh.";
    } else {
        self.statusLabel.text = @"Not signed in. Use Sign in to show a code on this TV.";
    }
}

- (void)signInTapped {
    __weak typeof(self) weakSelf = self;
    TVRecorderDeviceSignInViewController *vc =
        [[TVRecorderDeviceSignInViewController alloc] initWithCompletion:^(BOOL success, NSError *err) {
            [weakSelf refreshStatus];
            if (!success && err.code != TVRecorderOAuthErrorCancelled) {
                DDLogWarn(@"[TVRecorderAuth] sign-in failed %@", err.localizedDescription);
            }
        }];
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)signOutTapped {
    [TVRecorderTokenStore clear];
    [[TVRecorderOAuthClient shared] resetCachedDiscovery];
    DDLogInfo(@"[TVRecorderAuth] signed out");
    [self refreshStatus];
}

@end
