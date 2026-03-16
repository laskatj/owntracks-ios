//
//  WebAppViewController.m
//  OwnTracks
//
//  Web App tab: hosts a WKWebView loading the configured web app URL.
//  Supports postMessage from the web app for provisioning (type: "config").
//  When tag==98 (Map tab), shows a compact header with tracking controls.
//
//  Auth flow: ASWebAuthenticationSession (PKCE) → access_token → load
//  /auth/native-callback?access_token=... directly in WKWebView so the
//  WebView receives and owns the session cookie from that response.
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

static NSString * const kWebAppMessageHandlerName = @"owntracks";
static const CGFloat kMapHeaderHeight = 44.0;
static const CGFloat kMapHeaderPadding = 6.0;

@interface WebAppViewController () <WKNavigationDelegate, WKScriptMessageHandler>
@property (strong, nonatomic) WKWebView *webView;
@property (strong, nonatomic) UILabel *placeholderLabel;
@property (strong, nonatomic) UIView *mapHeaderView;
@property (strong, nonatomic) UISegmentedControl *modes;
@property (strong, nonatomic) UILabel *accuracyLabel;
@property (strong, nonatomic) NSTimer *accuracyTimer;
@property (nonatomic) BOOL observingMonitoring;
// OIDC
@property (copy, nonatomic) NSURL *webAppOrigin;
@property (copy, nonatomic) NSURL *webAppBaseURL;
@property (copy, nonatomic) NSString *discoveryLoginPath;
@property (copy, nonatomic) NSURL *oidcAuthorizationEndpointURL;
@property (strong, nonatomic) UIButton *loginButton;
@property (copy, nonatomic) NSString *pendingOIDCRedirectURI;  // React app's redirect_uri captured during passthrough
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

#pragma mark - Web app URL loading

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
                [self setWebAppOriginFromURL:url];
                if (self.loginButton) self.loginButton.hidden = YES;
                else [self updateLogInBarButton];
                [self fetchDiscoveryAndUpdateLoginButton];
                self.placeholderLabel.hidden = YES;
                self.webView.hidden = NO;
                // Skip reload if already on the app host AND not stuck on the native-callback URL.
                // (Prevents disrupting an authenticated session on tab switch, but always
                //  navigates away from native-callback after token exchange.)
                NSString *currentHost = self.webView.URL.host;
                NSString *currentPath = self.webView.URL.path ?: @"";
                BOOL onAppHost = currentHost && [currentHost isEqualToString:url.host];
                BOOL onCallbackURL = [currentPath containsString:@"native-callback"];
                if (onAppHost && !onCallbackURL) {
                    NSLog(@"AUTHDEBUG: loadWebAppURL — skipping reload (already on app: %@)", self.webView.URL.absoluteString);
                } else {
                    NSLog(@"AUTHDEBUG: loadWebAppURL — loading %@", finalURL.absoluteString);
                    [self.webView loadRequest:[NSURLRequest requestWithURL:finalURL]];
                }
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

- (BOOL)appNeedsProvisioning {
    NSString *host = [Settings theHostInMOC:CoreData.sharedInstance.mainMOC];
    if (!host || host.length == 0) return YES;
    if ([host isEqualToString:@"host"]) return YES;
    return NO;
}

#pragma mark - OIDC helpers

- (void)setWebAppOriginFromURL:(NSURL *)url {
    NSURLComponents *c = [NSURLComponents new];
    c.scheme = url.scheme;
    c.host = url.host;
    c.port = url.port;
    self.webAppOrigin = c.URL;
    // Base URL including path prefix so native-callback is constructed on the same path as the web app.
    NSURLComponents *base = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    base.query = nil;
    base.fragment = nil;
    NSString *path = (base.path.length > 0 && ![base.path isEqualToString:@"/"]) ? base.path : @"";
    if (path.length > 0 && [path hasSuffix:@"/"]) path = [path substringToIndex:path.length - 1];
    base.path = path.length > 0 ? path : @"/";
    self.webAppBaseURL = base.URL ?: self.webAppOrigin;
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
                NSLog(@"AUTHDEBUG: owntracks-app-auth discovery OK — login_path=%@", sself.discoveryLoginPath);
            } else {
                sself.discoveryLoginPath = nil;
                NSLog(@"AUTHDEBUG: owntracks-app-auth discovery FAILED — %@", error.localizedDescription);
            }
        });
    }];
    NSString *oidcURLString = [Settings stringForKey:@"oidc_discovery_url_preference" inMOC:CoreData.sharedInstance.mainMOC];
    NSLog(@"AUTHDEBUG: oidc_discovery_url_preference=%@", oidcURLString.length > 0 ? oidcURLString : @"(not set)");
    if (oidcURLString.length > 0) {
        NSURL *oidcURL = [NSURL URLWithString:oidcURLString];
        if (oidcURL) {
            [[WebAppAuthHelper sharedInstance] fetchOIDCAuthorizationEndpointFromDiscoveryURL:oidcURL completion:^(NSURL * _Nullable authEndpointURL, NSError * _Nullable error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(wself) sself = wself;
                    if (!sself) return;
                    sself.oidcAuthorizationEndpointURL = authEndpointURL;
                    NSLog(@"AUTHDEBUG: oidcAuthorizationEndpointURL set to %@", authEndpointURL.absoluteString ?: @"(nil — error)");
                });
            }];
        } else {
            self.oidcAuthorizationEndpointURL = nil;
            NSLog(@"AUTHDEBUG: oidc_discovery_url is invalid — oidcAuthorizationEndpointURL=nil");
        }
    } else {
        self.oidcAuthorizationEndpointURL = nil;
        NSLog(@"AUTHDEBUG: no oidc_discovery_url — IdP-host interception disabled, login-path only");
    }
}

// Manual login button — no IdP URL available, use our own PKCE fallback flow.
- (void)webAppLoginPressed {
    [self startNativeAuthFallback];
}

- (void)loadWebViewWithAccessToken:(NSString *)accessToken {
    if (!accessToken.length || !self.webAppOrigin) return;
    NSURL *base = self.webAppBaseURL ?: self.webAppOrigin;
    NSString *basePath = (base.path.length > 0 && ![base.path isEqualToString:@"/"]) ? base.path : @"";
    NSString *path = basePath.length > 0
        ? [basePath stringByAppendingPathComponent:@"auth/native-callback"]
        : @"/auth/native-callback";
    NSURLComponents *c = [NSURLComponents componentsWithURL:base resolvingAgainstBaseURL:NO];
    c.path = path;
    c.queryItems = @[ [NSURLQueryItem queryItemWithName:@"access_token" value:accessToken] ];
    NSURL *callbackURL = c.URL;
    if (!callbackURL) return;
    NSLog(@"AUTHDEBUG: loadWebViewWithAccessToken → %@?access_token=<redacted>", [callbackURL.absoluteString componentsSeparatedByString:@"?"].firstObject);
    self.placeholderLabel.hidden = YES;
    self.webView.hidden = NO;
    [self.webView loadRequest:[NSURLRequest requestWithURL:callbackURL]];
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

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    NSString *path = webView.URL.path ?: @"";
    NSString *query = webView.URL.query ?: @"";
    NSLog(@"AUTHDEBUG: didFinishNavigation url=%@", webView.URL.absoluteString);
    if ([path containsString:@"native-callback"]) {
        NSLog(@"AUTHDEBUG: native-callback finished — cookie set by response — forcing nav to app");
        [self forceLoadWebAppURL];
    } else if ([query containsString:@"code="] && [query containsString:@"state="]) {
        // React OIDC callback — the React OIDC client will handle this itself. Do nothing.
        NSLog(@"AUTHDEBUG: OIDC callback page loaded — React OIDC client will handle token exchange");
    }
}

// Loads the configured app URL unconditionally (no same-host guard).
// Used after native-callback so we always navigate to /map even though
// native-callback is on the same host as the web app.
- (void)forceLoadWebAppURL {
    NSString *urlString = [Settings stringForKey:@"webappurl_preference" inMOC:CoreData.sharedInstance.mainMOC];
    NSURL *url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
    if (!url) {
        NSLog(@"AUTHDEBUG: forceLoadWebAppURL — no web app URL configured");
        return;
    }
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *path = components.path ?: @"";
    if ([path hasSuffix:@"/"]) path = [path substringToIndex:path.length - 1];
    if (self.tabBarItem.tag == 98) {
        path = path.length > 0 ? [path stringByAppendingPathComponent:@"map"] : @"/map";
    }
    if (path.length == 0) path = @"/";
    components.path = path;
    components.queryItems = @[ [NSURLQueryItem queryItemWithName:@"embedded" value:@"1"] ];
    NSURL *finalURL = components.URL;
    NSLog(@"AUTHDEBUG: forceLoadWebAppURL → %@", finalURL.absoluteString);
    if (finalURL) {
        [self.webView loadRequest:[NSURLRequest requestWithURL:finalURL]];
    }
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *requestURL = navigationAction.request.URL;

    NSLog(@"AUTHDEBUG: decidePolicyForNavigationAction scheme=%@ host=%@ path=%@",
          requestURL.scheme ?: @"(nil)", requestURL.host ?: @"(nil)", requestURL.path ?: @"(nil)");
    NSLog(@"AUTHDEBUG:   oidcEndpoint=%@ discoveryLoginPath=%@",
          self.oidcAuthorizationEndpointURL.absoluteString ?: @"(nil)",
          self.discoveryLoginPath ?: @"(nil)");

    // Intercept navigation to the IdP authorization endpoint. Proxy it through
    // ASWebAuthenticationSession (for SSO) then hand the code back to the React OIDC client.
    if (self.oidcAuthorizationEndpointURL && requestURL.host && requestURL.path.length > 0 &&
        [requestURL.host isEqualToString:self.oidcAuthorizationEndpointURL.host] &&
        (requestURL.scheme.length == 0 || [requestURL.scheme isEqualToString:self.oidcAuthorizationEndpointURL.scheme]) &&
        ([requestURL.path isEqualToString:self.oidcAuthorizationEndpointURL.path] || [requestURL.path hasPrefix:[self.oidcAuthorizationEndpointURL.path stringByAppendingString:@"/"]])) {
        NSLog(@"AUTHDEBUG: → INTERCEPT IdP endpoint — passthrough via ASWebAuthenticationSession");
        decisionHandler(WKNavigationActionPolicyCancel);
        [self startPassthroughAuthWithIdPURL:requestURL];
        return;
    }

    // Intercept navigation to the web app's login path (from owntracks-app-auth discovery).
    // No IdP URL available here, so fall back to our own PKCE flow.
    if (self.webAppOrigin && self.discoveryLoginPath.length > 0 &&
        requestURL.host && [requestURL.host isEqualToString:self.webAppOrigin.host] &&
        ([requestURL.scheme isEqualToString:self.webAppOrigin.scheme] || !requestURL.scheme) &&
        requestURL.path.length > 0) {
        NSString *loginPath = [self.discoveryLoginPath hasPrefix:@"/"] ? self.discoveryLoginPath : [@"/" stringByAppendingString:self.discoveryLoginPath];
        if ([requestURL.path isEqualToString:loginPath] || [requestURL.path hasPrefix:[loginPath stringByAppendingString:@"/"]]) {
            NSLog(@"AUTHDEBUG: → INTERCEPT login path '%@' — fallback native auth", loginPath);
            decisionHandler(WKNavigationActionPolicyCancel);
            [self startNativeAuthFallback];
            return;
        }
    }

    NSLog(@"AUTHDEBUG: → ALLOW");
    decisionHandler(WKNavigationActionPolicyAllow);
}

// Primary: proxy the React app's own OIDC redirect through ASWebAuthenticationSession for SSO,
// then return the authorization code to the React OIDC client to complete its own token exchange.
- (void)startPassthroughAuthWithIdPURL:(NSURL *)idpURL {
    NSURLComponents *idpComponents = [NSURLComponents componentsWithURL:idpURL resolvingAgainstBaseURL:NO];
    NSString *originalRedirectURI = nil;
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    for (NSURLQueryItem *item in idpComponents.queryItems) {
        if ([item.name isEqualToString:@"redirect_uri"]) {
            originalRedirectURI = item.value;
            [items addObject:[NSURLQueryItem queryItemWithName:@"redirect_uri" value:@"owntracks:///auth/callback"]];
        } else {
            [items addObject:item];
        }
    }
    if (!originalRedirectURI) {
        NSLog(@"AUTHDEBUG: startPassthroughAuth — no redirect_uri in IdP URL, using fallback");
        [self startNativeAuthFallback];
        return;
    }
    idpComponents.queryItems = items;
    NSURL *modifiedURL = idpComponents.URL;
    self.pendingOIDCRedirectURI = originalRedirectURI;
    NSLog(@"AUTHDEBUG: startPassthroughAuth — originalRedirectURI=%@", originalRedirectURI);

    __weak typeof(self) wself = self;
    [[WebAppAuthHelper sharedInstance] startPassthroughSessionWithURL:modifiedURL
                                                           completion:^(NSURL *callbackURL, NSError *error) {
        __strong typeof(wself) sself = wself;
        if (!sself) return;
        if (error) {
            NSLog(@"AUTHDEBUG: passthrough session error: %@", error.localizedDescription);
            return;
        }
        if (!callbackURL) {
            NSLog(@"AUTHDEBUG: passthrough session cancelled by user");
            return;
        }
        // callbackURL = owntracks:///auth/callback?code=CODE&state=STATE&...
        // Reconstruct as: {originalRedirectURI}?code=CODE&state=STATE&...
        NSURLComponents *cb = [NSURLComponents componentsWithURL:callbackURL resolvingAgainstBaseURL:NO];
        NSURLComponents *reactCB = [NSURLComponents componentsWithString:sself.pendingOIDCRedirectURI];
        if (!reactCB) {
            NSLog(@"AUTHDEBUG: passthrough — invalid pendingOIDCRedirectURI");
            return;
        }
        NSMutableArray<NSURLQueryItem *> *reactItems = [NSMutableArray arrayWithArray:reactCB.queryItems ?: @[]];
        for (NSURLQueryItem *item in cb.queryItems) {
            [reactItems addObject:item];
        }
        reactCB.queryItems = reactItems;
        NSURL *reactCallbackURL = reactCB.URL;
        NSLog(@"AUTHDEBUG: passthrough complete — loading React OIDC callback URL (code redacted)");
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(wself) sself2 = wself;
            if (!sself2) return;
            sself2.pendingOIDCRedirectURI = nil;
            sself2.placeholderLabel.hidden = YES;
            sself2.webView.hidden = NO;
            [sself2.webView loadRequest:[NSURLRequest requestWithURL:reactCallbackURL]];
        });
    }];
}

// Fallback: our own PKCE flow (used from login button, or when login-path is intercepted).
- (void)startNativeAuthFallback {
    if (!self.webAppOrigin) return;
    NSLog(@"AUTHDEBUG: startNativeAuthFallback — origin=%@", self.webAppOrigin.absoluteString);
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
            if (!sself || !accessToken.length) return;
            [sself loadWebViewWithAccessToken:accessToken];
        });
    }];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    DDLogWarn(@"[WebAppViewController] didFailNavigation: %@", error.localizedDescription);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    DDLogWarn(@"[WebAppViewController] didFailProvisionalNavigation: %@", error.localizedDescription);
}

@end
