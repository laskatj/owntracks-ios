//
//  WebAppViewController.m
//  OwnTracks
//
//  Web App tab: hosts a WKWebView loading the configured web app URL.
//  Supports postMessage from the web app for provisioning (type: "config").
//  When tag==98 (Map tab), shows a compact header with tracking controls.
//

#import "WebAppViewController.h"
#import "WebAppAuthHelper.h"
#import "Settings.h"
#import "CoreData.h"
#import "OwnTracksAppDelegate.h"
#import "LocationManager.h"
#import "Waypoint+CoreDataClass.h"
#import "StatusTVC.h"
#import "ViewController.h"
#import "NavigationController.h"
#import <WebKit/WebKit.h>
#import <CocoaLumberjack/CocoaLumberjack.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

static void _debugDecide(NSURL *requestURL, BOOL inCooldown, BOOL isIdPHost, NSString *branch) {
    DDLogInfo(@"[WebAppViewController] decidePolicy host=%@ path=%@ inCooldown=%d isIdPHost=%d branch=%@",
              requestURL.host ?: @"", requestURL.path ?: @"", inCooldown, isIdPHost, branch ?: @"allow");
}

static NSString * const kWebAppMessageHandlerName = @"owntracks";
static const CGFloat kMapHeaderHeight = 44.0;
static const CGFloat kMapHeaderPadding = 6.0;
static NSString * const kDefaultNativeCallbackPath = @"/auth/native-callback";
static const NSTimeInterval kNativeCallbackInterceptCooldown = 15.0;  // seconds to not re-intercept IdP after passing token

@interface WebAppViewController () <WKNavigationDelegate, WKScriptMessageHandler>
@property (strong, nonatomic) WKWebView *webView;
@property (strong, nonatomic) UILabel *placeholderLabel;
@property (strong, nonatomic) UIView *mapHeaderView;
@property (strong, nonatomic) UISegmentedControl *modes;
@property (strong, nonatomic) UILabel *accuracyLabel;
@property (strong, nonatomic) NSTimer *accuracyTimer;
@property (nonatomic) BOOL observingMonitoring;
@property (copy, nonatomic) NSURL *webAppOrigin;
@property (copy, nonatomic) NSURL *webAppBaseURL;  // origin + path, for native-callback URL
@property (copy, nonatomic) NSString *discoveryLoginPath;
@property (copy, nonatomic) NSURL *oidcAuthorizationEndpointURL;
@property (strong, nonatomic) UIButton *loginButton;
@property (nonatomic, strong) NSDate *lastNativeCallbackLoadTime;  // cooldown: don't re-intercept IdP right after passing token
@property (nonatomic) BOOL skipNextIdpIntercept;  // after cooldown_reload, allow one IdP nav in web view to break loop when backend didn't set cookie
@end

@implementation WebAppViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    [config.userContentController addScriptMessageHandler:self name:kWebAppMessageHandlerName];

    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.navigationDelegate = self;
    [self.view addSubview:self.webView];

    self.placeholderLabel = [[UILabel alloc] initWithFrame:self.view.bounds];
    self.placeholderLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.placeholderLabel.textAlignment = NSTextAlignmentCenter;
    self.placeholderLabel.numberOfLines = 0;
    self.placeholderLabel.text = NSLocalizedString(@"Configure web app URL in Settings",
                                                   @"Placeholder when Web App URL is not set");
    self.placeholderLabel.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:self.placeholderLabel];

    if (self.tabBarItem.tag == 98) {
        [self setupMapHeader];
    }

    [self loadWebAppURL];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.tabBarItem.tag == 98) {
        [[LocationManager sharedInstance] authorize];
        [self.navigationController setNavigationBarHidden:YES animated:animated];
        [self updateMoveButton];
        [self updateAccuracyLabel];
        [self startAccuracyTimer];
        if (!self.observingMonitoring) {
            [[LocationManager sharedInstance] addObserver:self forKeyPath:@"monitoring" options:NSKeyValueObservingOptionNew context:NULL];
            self.observingMonitoring = YES;
        }
    }
    [self loadWebAppURL];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.tabBarItem.tag == 98) {
        [self.navigationController setNavigationBarHidden:NO animated:animated];
        [self stopAccuracyTimer];
        if (self.observingMonitoring) {
            [[LocationManager sharedInstance] removeObserver:self forKeyPath:@"monitoring"];
            self.observingMonitoring = NO;
        }
    }
}

- (void)dealloc {
    [self stopAccuracyTimer];
    [self.webView.configuration.userContentController removeScriptMessageHandlerForName:kWebAppMessageHandlerName];
}

#pragma mark - Map header (tag == 98)

- (void)setupMapHeader {
    self.mapHeaderView = [[UIView alloc] initWithFrame:CGRectZero];
    self.mapHeaderView.backgroundColor = [UIColor systemBackgroundColor];
    self.mapHeaderView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.mapHeaderView];

    NSLayoutConstraint *headerTop = [NSLayoutConstraint constraintWithItem:self.mapHeaderView attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual toItem:self.view.safeAreaLayoutGuide attribute:NSLayoutAttributeTop multiplier:1 constant:0];
    NSLayoutConstraint *headerLead = [NSLayoutConstraint constraintWithItem:self.mapHeaderView attribute:NSLayoutAttributeLeading relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeLeading multiplier:1 constant:0];
    NSLayoutConstraint *headerTrail = [NSLayoutConstraint constraintWithItem:self.view attribute:NSLayoutAttributeTrailing relatedBy:NSLayoutRelationEqual toItem:self.mapHeaderView attribute:NSLayoutAttributeTrailing multiplier:1 constant:0];
    NSLayoutConstraint *headerHeight = [NSLayoutConstraint constraintWithItem:self.mapHeaderView attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:kMapHeaderHeight];
    [NSLayoutConstraint activateConstraints:@[headerTop, headerLead, headerTrail, headerHeight]];

    UIButton *infoBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [infoBtn setImage:[UIImage imageNamed:@"Info"] forState:UIControlStateNormal];
    infoBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [infoBtn addTarget:self action:@selector(mapHeaderInfoPressed) forControlEvents:UIControlEventTouchUpInside];
    [self.mapHeaderView addSubview:infoBtn];

    UIButton *mapBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [mapBtn setImage:[UIImage systemImageNamed:@"map"] forState:UIControlStateNormal];
    mapBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [mapBtn addTarget:self action:@selector(mapHeaderAskForMapPressed) forControlEvents:UIControlEventTouchUpInside];
    [self.mapHeaderView addSubview:mapBtn];

    self.loginButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.loginButton setTitle:NSLocalizedString(@"Log in", @"Log in button for native auth") forState:UIControlStateNormal];
    self.loginButton.titleLabel.font = [UIFont systemFontOfSize:12];
    self.loginButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loginButton addTarget:self action:@selector(webAppLoginPressed) forControlEvents:UIControlEventTouchUpInside];
    [self.mapHeaderView addSubview:self.loginButton];
    self.loginButton.hidden = YES;

    self.accuracyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.accuracyLabel.font = [UIFont systemFontOfSize:11];
    self.accuracyLabel.textColor = [UIColor secondaryLabelColor];
    self.accuracyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.mapHeaderView addSubview:self.accuracyLabel];

    UIButton *shareBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [shareBtn setImage:[UIImage systemImageNamed:@"square.and.arrow.up"] forState:UIControlStateNormal];
    shareBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [shareBtn addTarget:self action:@selector(mapHeaderSharePressed) forControlEvents:UIControlEventTouchUpInside];
    [self.mapHeaderView addSubview:shareBtn];

    self.modes = [[UISegmentedControl alloc] initWithItems:@[
        NSLocalizedString(@"Quiet", @"Quiet"),
        NSLocalizedString(@"Manual", @"Manual"),
        NSLocalizedString(@"Significant", @"Significant"),
        NSLocalizedString(@"Move", @"Move")
    ]];
    self.modes.apportionsSegmentWidthsByContent = YES;
    self.modes.translatesAutoresizingMaskIntoConstraints = NO;
    self.modes.backgroundColor = [UIColor colorNamed:@"modesColor"];
    UIFont *smallFont = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    [self.modes setTitleTextAttributes:@{ NSFontAttributeName: smallFont } forState:UIControlStateNormal];
    [self.modes setTitleTextAttributes:@{ NSFontAttributeName: smallFont } forState:UIControlStateSelected];
    [self.modes addTarget:self action:@selector(mapHeaderModesChanged:) forControlEvents:UIControlEventValueChanged];
    [self.mapHeaderView addSubview:self.modes];

    CGFloat pad = kMapHeaderPadding;
    [NSLayoutConstraint activateConstraints:@[
        [NSLayoutConstraint constraintWithItem:infoBtn attribute:NSLayoutAttributeLeading relatedBy:NSLayoutRelationEqual toItem:self.mapHeaderView attribute:NSLayoutAttributeLeading multiplier:1 constant:pad],
        [NSLayoutConstraint constraintWithItem:infoBtn attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:self.mapHeaderView attribute:NSLayoutAttributeCenterY multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:mapBtn attribute:NSLayoutAttributeLeading relatedBy:NSLayoutRelationEqual toItem:infoBtn attribute:NSLayoutAttributeTrailing multiplier:1 constant:6],
        [NSLayoutConstraint constraintWithItem:mapBtn attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:self.mapHeaderView attribute:NSLayoutAttributeCenterY multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:self.loginButton attribute:NSLayoutAttributeLeading relatedBy:NSLayoutRelationEqual toItem:mapBtn attribute:NSLayoutAttributeTrailing multiplier:1 constant:6],
        [NSLayoutConstraint constraintWithItem:self.loginButton attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:self.mapHeaderView attribute:NSLayoutAttributeCenterY multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:self.modes attribute:NSLayoutAttributeLeading relatedBy:NSLayoutRelationEqual toItem:self.loginButton attribute:NSLayoutAttributeTrailing multiplier:1 constant:8],
        [NSLayoutConstraint constraintWithItem:self.modes attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:self.mapHeaderView attribute:NSLayoutAttributeCenterY multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:self.accuracyLabel attribute:NSLayoutAttributeTrailing relatedBy:NSLayoutRelationEqual toItem:shareBtn attribute:NSLayoutAttributeLeading multiplier:1 constant:-6],
        [NSLayoutConstraint constraintWithItem:self.accuracyLabel attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:self.mapHeaderView attribute:NSLayoutAttributeCenterY multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:shareBtn attribute:NSLayoutAttributeTrailing relatedBy:NSLayoutRelationEqual toItem:self.mapHeaderView attribute:NSLayoutAttributeTrailing multiplier:1 constant:-pad],
        [NSLayoutConstraint constraintWithItem:shareBtn attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:self.mapHeaderView attribute:NSLayoutAttributeCenterY multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:self.modes attribute:NSLayoutAttributeTrailing relatedBy:NSLayoutRelationEqual toItem:self.accuracyLabel attribute:NSLayoutAttributeLeading multiplier:1 constant:-8],
    ]];
    [self.accuracyLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.modes setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    NSLayoutConstraint *webTop = [NSLayoutConstraint constraintWithItem:self.webView attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual toItem:self.mapHeaderView attribute:NSLayoutAttributeBottom multiplier:1 constant:0];
    NSLayoutConstraint *webLead = [NSLayoutConstraint constraintWithItem:self.webView attribute:NSLayoutAttributeLeading relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeLeading multiplier:1 constant:0];
    NSLayoutConstraint *webTrail = [NSLayoutConstraint constraintWithItem:self.view attribute:NSLayoutAttributeTrailing relatedBy:NSLayoutRelationEqual toItem:self.webView attribute:NSLayoutAttributeTrailing multiplier:1 constant:0];
    NSLayoutConstraint *webBottom = [NSLayoutConstraint constraintWithItem:self.view attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:self.webView attribute:NSLayoutAttributeBottom multiplier:1 constant:0];
    [NSLayoutConstraint activateConstraints:@[webTop, webLead, webTrail, webBottom]];
    self.placeholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [NSLayoutConstraint constraintWithItem:self.placeholderLabel attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual toItem:self.mapHeaderView attribute:NSLayoutAttributeBottom multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:self.placeholderLabel attribute:NSLayoutAttributeLeading relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeLeading multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:self.view attribute:NSLayoutAttributeTrailing relatedBy:NSLayoutRelationEqual toItem:self.placeholderLabel attribute:NSLayoutAttributeTrailing multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:self.view attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:self.placeholderLabel attribute:NSLayoutAttributeBottom multiplier:1 constant:0],
    ]];
}

- (void)mapHeaderInfoPressed {
    UIViewController *status = [self.storyboard instantiateViewControllerWithIdentifier:@"StatusTVC"];
    if (status) {
        [self.navigationController setNavigationBarHidden:NO animated:NO];
        [self.navigationController pushViewController:status animated:YES];
    }
}

- (void)mapHeaderAskForMapPressed {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Map Interaction", @"Title map interaction")
                                                               message:NSLocalizedString(@"Do you want the map to allow interaction? If you choose yes, the map provider may analyze your tile requests", @"Message map interaction")
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Yes", @"Yes button title") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [[NSUserDefaults standardUserDefaults] setInteger:1 forKey:@"noMap"];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"No", @"No button title") style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [[NSUserDefaults standardUserDefaults] setInteger:-1 forKey:@"noMap"];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)mapHeaderSharePressed {
    ViewController *mapVC = [self nativeMapViewController];
    if (mapVC && [mapVC respondsToSelector:@selector(actionPressed:)]) {
        [mapVC performSelector:@selector(actionPressed:) withObject:nil];
    }
}

- (ViewController *)nativeMapViewController {
    UITabBarController *tbc = self.tabBarController;
    if (!tbc) return nil;
    for (UIViewController *vc in tbc.viewControllers) {
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UIViewController *top = [(UINavigationController *)vc topViewController];
            if ([top isKindOfClass:[ViewController class]]) {
                return (ViewController *)top;
            }
        }
    }
    return nil;
}

- (void)mapHeaderModesChanged:(UISegmentedControl *)segmentedControl {
    LocationMonitoring monitoring;
    switch (segmentedControl.selectedSegmentIndex) {
        case 3: monitoring = LocationMonitoringMove; break;
        case 2: monitoring = LocationMonitoringSignificant; break;
        case 1: monitoring = LocationMonitoringManual; break;
        case 0:
        default: monitoring = LocationMonitoringQuiet; break;
    }
    if (monitoring != [LocationManager sharedInstance].monitoring) {
        [LocationManager sharedInstance].monitoring = monitoring;
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"downgraded"];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"adapted"];
        [Settings setInt:(int)[LocationManager sharedInstance].monitoring forKey:@"monitoring_preference" inMOC:CoreData.sharedInstance.mainMOC];
        [CoreData.sharedInstance sync:CoreData.sharedInstance.mainMOC];
        [self updateMoveButton];
    }
}

- (void)updateMoveButton {
    if (!self.modes) return;
    BOOL locked = [Settings theLockedInMOC:CoreData.sharedInstance.mainMOC];
    self.modes.enabled = !locked;
    switch ([LocationManager sharedInstance].monitoring) {
        case LocationMonitoringMove:    self.modes.selectedSegmentIndex = 3; break;
        case LocationMonitoringSignificant: self.modes.selectedSegmentIndex = 2; break;
        case LocationMonitoringManual:  self.modes.selectedSegmentIndex = 1; break;
        case LocationMonitoringQuiet:
        default:                         self.modes.selectedSegmentIndex = 0; break;
    }
    for (NSInteger i = 0; i < self.modes.numberOfSegments; i++) {
        NSString *title = [self.modes titleForSegmentAtIndex:i];
        if ([title hasSuffix:@"#"]) title = [title substringToIndex:title.length - 1];
        if ([title hasSuffix:@"!"]) title = [title substringToIndex:title.length - 1];
        [self.modes setTitle:title forSegmentAtIndex:i];
    }
    NSInteger idx = self.modes.selectedSegmentIndex;
    NSString *title = [self.modes titleForSegmentAtIndex:idx];
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"downgraded"]) {
        if (![title hasSuffix:@"!"]) title = [title stringByAppendingString:@"!"];
    }
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"adapted"]) {
        if (![title hasSuffix:@"#"]) title = [title stringByAppendingString:@"#"];
    }
    [self.modes setTitle:title forSegmentAtIndex:idx];
}

- (void)updateAccuracyLabel {
    if (!self.accuracyLabel) return;
    CLLocation *location = [LocationManager sharedInstance].location;
    self.accuracyLabel.text = [Waypoint CLLocationAccuracyText:location];
}

- (void)startAccuracyTimer {
    [self stopAccuracyTimer];
    self.accuracyTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
        [self updateAccuracyLabel];
    }];
}

- (void)stopAccuracyTimer {
    [self.accuracyTimer invalidate];
    self.accuracyTimer = nil;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if ([keyPath isEqualToString:@"monitoring"] && object == [LocationManager sharedInstance]) {
        [self updateMoveButton];
    }
}

- (void)loadWebAppURL {
    NSString *urlString = [Settings stringForKey:@"webappurl_preference" inMOC:CoreData.sharedInstance.mainMOC];
    if (urlString.length > 0) {
        NSURL *url = [NSURL URLWithString:urlString];
        if (url) {
            NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
            NSString *path = components.path ?: @"";
            if (path.length > 0 && [path hasSuffix:@"/"]) {
                path = [path substringToIndex:path.length - 1];
            }
            if (self.tabBarItem.tag == 98) {
                path = path.length > 0 ? [path stringByAppendingPathComponent:@"map"] : @"/map";
            }
            if (path.length == 0) {
                path = @"/";
            }
            components.path = path;

            NSMutableArray<NSURLQueryItem *> *queryItems = [NSMutableArray arrayWithArray:components.queryItems ?: @[]];
            [queryItems addObject:[NSURLQueryItem queryItemWithName:@"embedded" value:@"1"]];
            if ([self appNeedsProvisioning]) {
                [queryItems addObject:[NSURLQueryItem queryItemWithName:@"needs_provision" value:@"1"]];
                NSString *deviceName = [UIDevice currentDevice].name;
                if (deviceName.length > 0) {
                    [queryItems addObject:[NSURLQueryItem queryItemWithName:@"device" value:deviceName]];
                }
            }
            components.queryItems = queryItems;
            NSURL *finalURL = components.URL;
            if (finalURL) {
                self.placeholderLabel.hidden = YES;
                self.webView.hidden = NO;
                [self setWebAppOriginFromURL:url];
                if (self.loginButton) {
                    self.loginButton.hidden = NO;
                } else {
                    [self updateLogInBarButton];
                }
                [self fetchDiscoveryAndUpdateLoginButton];
                [self.webView loadRequest:[NSURLRequest requestWithURL:finalURL]];
                return;
            }
        }
    }
    self.webAppOrigin = nil;
    self.webAppBaseURL = nil;
    self.discoveryLoginPath = nil;
    self.oidcAuthorizationEndpointURL = nil;
    if (self.loginButton) self.loginButton.hidden = YES;
    self.navigationItem.rightBarButtonItem = nil;
    self.placeholderLabel.hidden = NO;
    self.webView.hidden = YES;
}

- (void)updateLogInBarButton {
    if (!self.webAppOrigin) {
        self.navigationItem.rightBarButtonItem = nil;
        return;
    }
    UIBarButtonItem *logInItem = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Log in", @"Log in button for native auth")
                                                                 style:UIBarButtonItemStylePlain
                                                                target:self
                                                                action:@selector(webAppLoginPressed)];
    self.navigationItem.rightBarButtonItem = logInItem;
}

- (void)setWebAppOriginFromURL:(NSURL *)url {
    NSURLComponents *c = [NSURLComponents new];
    c.scheme = url.scheme;
    c.host = url.host;
    c.port = url.port;
    self.webAppOrigin = c.URL;
    // Base URL including path so native-callback is on same path as web app (e.g. /sauron/auth/native-callback)
    NSURLComponents *base = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    base.query = nil;
    base.fragment = nil;
    NSString *path = (base.path.length > 0 && ![base.path isEqualToString:@"/"]) ? base.path : @"";
    if (path.length > 0 && [path hasSuffix:@"/"]) path = [path substringToIndex:path.length - 1];
    base.path = path.length > 0 ? path : @"/";
    self.webAppBaseURL = base.URL ?: self.webAppOrigin;
}

- (void)fetchDiscoveryAndUpdateLoginButton {
    if (!self.webAppOrigin) return;
    __weak typeof(self) wself = self;
    [[WebAppAuthHelper sharedInstance] fetchDiscoveryFromOrigin:self.webAppOrigin completion:^(NSDictionary * _Nullable config, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(wself) sself = wself;
            if (!sself) return;
            if (config) {
                id loginPath = config[@"login_path"];
                sself.discoveryLoginPath = [loginPath isKindOfClass:[NSString class]] && [(NSString *)loginPath length] > 0 ? (NSString *)loginPath : @"/login";
            } else {
                sself.discoveryLoginPath = nil;
            }
        });
    }];
    NSString *oidcURLString = [Settings stringForKey:@"oidc_discovery_url_preference" inMOC:CoreData.sharedInstance.mainMOC];
    if (oidcURLString.length > 0) {
        NSURL *oidcURL = [NSURL URLWithString:oidcURLString];
        if (oidcURL) {
            [[WebAppAuthHelper sharedInstance] fetchOIDCAuthorizationEndpointFromDiscoveryURL:oidcURL completion:^(NSURL * _Nullable authEndpointURL, NSError * _Nullable error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(wself) sself = wself;
                    if (!sself) return;
                    sself.oidcAuthorizationEndpointURL = authEndpointURL;
                });
            }];
        } else {
            self.oidcAuthorizationEndpointURL = nil;
        }
    } else {
        self.oidcAuthorizationEndpointURL = nil;
    }
}

- (void)webAppLoginPressed {
    if (!self.webAppOrigin) return;
    NSURL *oidcURL = nil;
    NSString *clientId = [Settings stringForKey:@"oauth_client_id_preference" inMOC:CoreData.sharedInstance.mainMOC];
    NSString *oidcURLString = [Settings stringForKey:@"oidc_discovery_url_preference" inMOC:CoreData.sharedInstance.mainMOC];
    if (oidcURLString.length > 0) {
        oidcURL = [NSURL URLWithString:oidcURLString];
    }
    __weak typeof(self) wself = self;
    [[WebAppAuthHelper sharedInstance] startAuthWithWebAppOrigin:self.webAppOrigin
                                                 oidcDiscoveryURL:oidcURL
                                                         clientId:clientId.length > 0 ? clientId : nil
                                          presentingViewController:self
                                                       completion:^(NSString * _Nullable accessToken, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(wself) sself = wself;
            if (!sself) return;
            if (error) {
                DDLogWarn(@"[WebAppViewController] Native auth failed: %@", error.localizedDescription);
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Sign-in unavailable", @"Native auth failed title")
                                                                               message:error.localizedDescription
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", @"OK") style:UIAlertActionStyleDefault handler:nil]];
                [sself presentViewController:alert animated:YES completion:nil];
                return;
            }
            [sself loadWebViewWithAccessToken:accessToken];
        });
    }];
}

- (void)loadWebViewWithAccessToken:(NSString *)accessToken {
    // Load the native-callback endpoint directly inside the WKWebView.
    //
    // Why not NSURLSession + WKHTTPCookieStore injection?
    // WKWebView splits across two OS processes: the UI process (your app) and the
    // WebContent process (where HTTP requests run). Cookies written via
    // WKHTTPCookieStore from the UI process are synced to the WebContent process
    // asynchronously — there is no callback for when that sync finishes.
    // Navigating immediately after setCookie: therefore races the sync and the
    // WebContent process sends the very next request without the cookie.
    //
    // By loading the native-callback URL *inside* the WebView, the WebContent
    // process receives the Set-Cookie response header directly and stores the
    // cookie in its own store. The backend's redirect (302 or JS/meta-refresh)
    // to /map is then executed by the same process, so the cookie is guaranteed
    // to be present on the /map request.
    if (!accessToken.length || !self.webAppOrigin) return;
    NSURL *base = self.webAppBaseURL ?: self.webAppOrigin;
    NSString *basePath = (base.path.length > 0 && ![base.path isEqualToString:@"/"]) ? base.path : @"";
    NSString *callbackPath = basePath.length > 0
        ? [basePath stringByAppendingPathComponent:@"auth/native-callback"]
        : kDefaultNativeCallbackPath;
    NSURLComponents *c = [NSURLComponents componentsWithURL:base resolvingAgainstBaseURL:NO];
    c.path = callbackPath;
    c.queryItems = @[ [NSURLQueryItem queryItemWithName:@"access_token" value:accessToken] ];
    NSURL *callbackURL = c.URL;
    if (!callbackURL) return;

    DDLogInfo(@"[WebAppViewController] Loading native-callback in WebView for token exchange");
    self.placeholderLabel.hidden = YES;
    self.webView.hidden = NO;
    if (self.loginButton) self.loginButton.hidden = NO;
    else [self updateLogInBarButton];
    self.lastNativeCallbackLoadTime = [NSDate date];
    [self.webView loadRequest:[NSURLRequest requestWithURL:callbackURL]];
}

- (BOOL)appNeedsProvisioning {
    NSString *host = [Settings theHostInMOC:CoreData.sharedInstance.mainMOC];
    if (!host || host.length == 0) return YES;
    if ([host isEqualToString:@"host"]) return YES;
    return NO;
}

#pragma mark - WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:kWebAppMessageHandlerName]) return;

    id body = message.body;
    if (![body isKindOfClass:[NSDictionary class]]) {
        DDLogWarn(@"[WebAppViewController] postMessage body not a dictionary: %@", body);
        return;
    }

    NSString *type = body[@"type"];
    if (![type isEqualToString:@"config"]) {
        DDLogVerbose(@"[WebAppViewController] postMessage type ignored: %@", type);
        return;
    }

    OwnTracksAppDelegate *appDelegate = (OwnTracksAppDelegate *)[UIApplication sharedApplication].delegate;

    NSDictionary *configuration = body[@"configuration"];
    if ([configuration isKindOfClass:[NSDictionary class]]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [appDelegate terminateSession];
            [appDelegate configFromDictionary:configuration];
            appDelegate.configLoad = [NSDate date];
            [appDelegate reconnect];
        });
        return;
    }

    NSString *urlString = body[@"url"];
    if ([urlString isKindOfClass:[NSString class]] && urlString.length > 0) {
        NSURL *url = [NSURL URLWithString:urlString];
        if (url) {
            [appDelegate processNSURL:url];
        }
    }
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *requestURL = navigationAction.request.URL;
    // #region agent log
    {
        BOOL inCooldown = (self.lastNativeCallbackLoadTime != nil);
        BOOL isIdPHost = (self.oidcAuthorizationEndpointURL && requestURL.host && [requestURL.host isEqualToString:self.oidcAuthorizationEndpointURL.host]);
        _debugDecide(requestURL, inCooldown, isIdPHost, @"entry");
        NSDictionary<NSString *, NSString *> *headers = navigationAction.request.allHTTPHeaderFields;
        if (headers.count > 0) {
            NSString *cookieVal = headers[@"Cookie"];
            if (!cookieVal) cookieVal = headers[@"cookie"];
            if (cookieVal.length > 0) {
                DDLogInfo(@"[WebAppViewController] request headers: Cookie <present length=%lu>", (unsigned long)cookieVal.length);
            } else {
                DDLogInfo(@"[WebAppViewController] request headers: Cookie <absent> (allHeaderFields count=%lu)", (unsigned long)headers.count);
            }
        } else {
            DDLogInfo(@"[WebAppViewController] request headers: (nil or empty — WKWebView may not expose headers to app)");
        }
    }
    // #endregion
    // Cooldown: if we see IdP navigation right after token handoff, cancel and reload web app (cookie may not have been sent).
    if (self.lastNativeCallbackLoadTime && [[NSDate date] timeIntervalSinceDate:self.lastNativeCallbackLoadTime] < kNativeCallbackInterceptCooldown) {
        if (self.oidcAuthorizationEndpointURL && requestURL.host && [requestURL.host isEqualToString:self.oidcAuthorizationEndpointURL.host]) {
            DDLogInfo(@"[WebAppViewController] Reloading web app after native-callback (skip IdP page)");
            self.lastNativeCallbackLoadTime = nil;
            self.skipNextIdpIntercept = YES;
            decisionHandler(WKNavigationActionPolicyCancel);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self loadWebAppURL];
            });
            return;
        }
    }
    // If we just did cooldown_reload but backend didn't set cookie, /map redirects to IdP again; allow that one IdP load in web view to stop re-intercept loop.
    if (self.skipNextIdpIntercept && self.oidcAuthorizationEndpointURL && requestURL.host && [requestURL.host isEqualToString:self.oidcAuthorizationEndpointURL.host]) {
        self.skipNextIdpIntercept = NO;
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    if (self.oidcAuthorizationEndpointURL && requestURL.host && requestURL.path.length > 0 &&
        [requestURL.host isEqualToString:self.oidcAuthorizationEndpointURL.host] &&
        (requestURL.scheme.length == 0 || [requestURL.scheme isEqualToString:self.oidcAuthorizationEndpointURL.scheme]) &&
        ([requestURL.path isEqualToString:self.oidcAuthorizationEndpointURL.path] || [requestURL.path hasPrefix:self.oidcAuthorizationEndpointURL.path])) {
        DDLogInfo(@"[WebAppViewController] Intercepting IdP navigation, launching native auth");
        decisionHandler(WKNavigationActionPolicyCancel);
        NSURL *oidcURL = nil;
        NSString *clientId = [Settings stringForKey:@"oauth_client_id_preference" inMOC:CoreData.sharedInstance.mainMOC];
        NSString *oidcURLString = [Settings stringForKey:@"oidc_discovery_url_preference" inMOC:CoreData.sharedInstance.mainMOC];
        if (oidcURLString.length > 0) oidcURL = [NSURL URLWithString:oidcURLString];
        __weak typeof(self) wself = self;
        [[WebAppAuthHelper sharedInstance] startAuthWithWebAppOrigin:self.webAppOrigin
                                                     oidcDiscoveryURL:oidcURL
                                                             clientId:clientId.length > 0 ? clientId : nil
                                              presentingViewController:self
                                                           completion:^(NSString * _Nullable accessToken, NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(wself) sself = wself;
                if (!sself) return;
                if (accessToken.length > 0) {
                    [sself loadWebViewWithAccessToken:accessToken];
                }
            });
        }];
        return;
    }
    if (self.webAppOrigin && self.discoveryLoginPath.length > 0 &&
        requestURL.host && [requestURL.host isEqualToString:self.webAppOrigin.host] &&
        ([requestURL.scheme isEqualToString:self.webAppOrigin.scheme] || (!requestURL.scheme && self.webAppOrigin.scheme)) &&
        requestURL.path.length > 0) {
        NSString *path = requestURL.path;
        NSString *loginPath = [self.discoveryLoginPath hasPrefix:@"/"] ? self.discoveryLoginPath : [@"/" stringByAppendingString:self.discoveryLoginPath];
        if ([path isEqualToString:loginPath] || [path hasPrefix:[loginPath stringByAppendingString:@"/"]]) {
            DDLogInfo(@"[WebAppViewController] Intercepting login path, launching native auth");
            decisionHandler(WKNavigationActionPolicyCancel);
            NSURL *oidcURL = nil;
            NSString *clientId = [Settings stringForKey:@"oauth_client_id_preference" inMOC:CoreData.sharedInstance.mainMOC];
            NSString *oidcURLString = [Settings stringForKey:@"oidc_discovery_url_preference" inMOC:CoreData.sharedInstance.mainMOC];
            if (oidcURLString.length > 0) oidcURL = [NSURL URLWithString:oidcURLString];
            __weak typeof(self) wself = self;
            [[WebAppAuthHelper sharedInstance] startAuthWithWebAppOrigin:self.webAppOrigin
                                                         oidcDiscoveryURL:oidcURL
                                                                 clientId:clientId.length > 0 ? clientId : nil
                                                  presentingViewController:self
                                                               completion:^(NSString * _Nullable accessToken, NSError * _Nullable error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(wself) sself = wself;
                    if (!sself) return;
                    if (accessToken.length > 0) {
                        [sself loadWebViewWithAccessToken:accessToken];
                    }
                });
            }];
            return;
        }
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    DDLogWarn(@"[WebAppViewController] didFailNavigation: %@", error.localizedDescription);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    DDLogWarn(@"[WebAppViewController] didFailProvisionalNavigation: %@", error.localizedDescription);
}

@end
