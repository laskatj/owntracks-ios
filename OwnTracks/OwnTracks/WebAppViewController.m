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
@property (strong, nonatomic, nullable) NSDate *passthroughLastCompletedAt;  // set when passthrough delivers callback to WebView
@end

@implementation WebAppViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    [config.userContentController addScriptMessageHandler:self name:kWebAppMessageHandlerName];

    // Diagnostic script injected at document-start on every page (main frame and iframes).
    // Captures: console output, CSP violations, Worker creation, React Router client-side
    // navigation (pushState/replaceState), unhandled errors/rejections, and a sessionStorage
    // snapshot taken BEFORE any page JS runs — proving whether OIDC user survives navigation.
    NSString *diagJS =
        @"(function(){"
        "function _pm(level,msg){"
        "  try{window.webkit.messageHandlers.owntracks.postMessage({type:'js_console',level:level,message:String(msg).substring(0,600)});}catch(e){}"
        "}"
        // --- storage snapshot at document-start (before React) — checks both SS and LS ---
        "(function(){"
        "  try{"
        "    var ssKeys=[];try{ssKeys=Object.keys(sessionStorage);}catch(e){}"
        "    var lsKeys=[];try{lsKeys=Object.keys(localStorage);}catch(e){}"
        "    var oidcSS=ssKeys.find(function(k){return k.indexOf('oidc.')===0;});"
        "    var oidcLS=lsKeys.find(function(k){return k.indexOf('oidc.')===0;});"
        "    var raw=(oidcSS?sessionStorage.getItem(oidcSS):(oidcLS?localStorage.getItem(oidcLS):null));"
        "    var exp=null;try{exp=raw?JSON.parse(raw).expires_at:null;}catch(e){}"
        "    _pm('docstart','PATH='+location.pathname"
        "      +' SS='+ssKeys.length+' LS='+lsKeys.length"
        "      +' OIDC='+(oidcSS||oidcLS||'NONE')+(exp?' exp='+exp:'')"
        "      +' NOW='+Math.floor(Date.now()/1000));"
        "  }catch(e){_pm('docstart','STORAGE_ERROR: '+e);}"
        "})();"
        // --- console forwarding ---
        "var _orig={};"
        "['log','warn','error','info'].forEach(function(l){"
        "  _orig[l]=console[l].bind(console);"
        "  console[l]=function(){"
        "    var msg=Array.prototype.slice.call(arguments).map(function(a){"
        "      try{return typeof a==='object'?JSON.stringify(a):String(a);}catch(e){return '[obj]';}"
        "    }).join(' ');"
        "    _pm(l,msg);"
        "    _orig[l].apply(console,arguments);"
        "  };"
        "});"
        // --- unhandled JS errors ---
        "window.addEventListener('error',function(e){"
        "  _pm('jserror',e.message+' ('+e.filename+':'+e.lineno+')');"
        "});"
        "window.addEventListener('unhandledrejection',function(e){"
        "  var r=e.reason;"
        "  _pm('rejection',r&&r.message?r.message:String(r));"
        "});"
        // --- CSP violation events ---
        "window.addEventListener('securitypolicyviolation',function(e){"
        "  _pm('csp','violated='+e.violatedDirective+' blocked='+e.blockedURI);"
        "});"
        // --- React Router / history navigation intercept ---
        "(function(){"
        "  function _wrapHistory(method){"
        "    var orig=history[method];"
        "    history[method]=function(state,title,url){"
        "      _pm('nav',method+': '+String(url));"
        "      return orig.apply(this,arguments);"
        "    };"
        "  }"
        "  _wrapHistory('pushState');"
        "  _wrapHistory('replaceState');"
        "  window.addEventListener('popstate',function(e){"
        "    _pm('nav','popstate: '+location.pathname+location.search);"
        "  });"
        "})();"
        // --- Worker construction interception ---
        "var _OW=window.Worker;"
        "if(_OW){"
        "  window.Worker=function(url,opts){"
        "    _pm('worker','new Worker: '+String(url).substring(0,120));"
        "    return new _OW(url,opts);"
        "  };"
        "  window.Worker.prototype=_OW.prototype;"
        "}"
        "})();";
    WKUserScript *diagScript = [[WKUserScript alloc]
        initWithSource:diagJS
         injectionTime:WKUserScriptInjectionTimeAtDocumentStart
      forMainFrameOnly:NO];
    [config.userContentController addUserScript:diagScript];

    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.navigationDelegate = self;
    // Prevent the scroll view from adding automatic content insets for the tab bar and
    // home indicator — the web content handles its own safe-area padding. Without this,
    // iOS adds ~83 pt of bottom inset (tab bar + home indicator) which shows as white
    // space below the map content.
    self.webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
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
    // viewWillAppear always fires immediately after viewDidLoad on first appearance,
    // so we do not call loadWebAppURL here to avoid a concurrent double-load.
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
                if (self.loginButton) self.loginButton.hidden = NO;
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
                    NSLog(@"AUTHDEBUG%@: loadWebAppURL — skipping reload (already on app: %@)", [self _vcLabel], self.webView.URL.absoluteString);
                } else {
                    // Attempt a silent native token refresh before loading so the web app
                    // receives a session cookie via /auth/native-callback immediately, rather
                    // than relying on the React OIDC client's hidden-iframe silent renewal
                    // (which we cannot intercept and which fails silently when there is no
                    // existing Authentik session, leaving the page blank).
                    NSLog(@"AUTHDEBUG%@: loadWebAppURL — attempting proactive native auth before load", [self _vcLabel]);
                    NSURL *webAppURL = self.webAppBaseURL ?: self.webAppOrigin;
                    NSString *clientId = [Settings stringForKey:@"oauth_client_id_preference"
                                                          inMOC:CoreData.sharedInstance.mainMOC];
                    NSURL *capturedFinalURL = finalURL;
                    __weak typeof(self) wself = self;
                    [[WebAppAuthHelper sharedInstance]
                        attemptSilentRefreshForWebAppURL:webAppURL
                                               clientId:clientId.length > 0 ? clientId : nil
                                    tokenPairCompletion:^(NSString *accessToken, NSString *refreshToken, NSError *error) {
                        __strong typeof(wself) sself = wself;
                        if (!sself) return;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (accessToken.length > 0) {
                                NSLog(@"AUTHDEBUG%@: loadWebAppURL — proactive silent refresh OK, loading via native-callback (refresh_token=%@)", [sself _vcLabel], refreshToken.length > 0 ? @"present" : @"none");
                                [sself loadWebViewWithAccessToken:accessToken refreshToken:refreshToken];
                            } else {
                                NSLog(@"AUTHDEBUG%@: loadWebAppURL — no stored token, loading directly (React OIDC or login button will handle auth)", [sself _vcLabel]);
                                NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:capturedFinalURL];
                                [req setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData];
                                [sself.webView loadRequest:req];
                            }
                        });
                    }];
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

/// Short label for log lines so the two VC instances (web app tab vs map tab) are distinguishable.
- (NSString *)_vcLabel {
    return self.tabBarItem.tag == 98 ? @"[map]" : @"[web]";
}

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
                NSLog(@"AUTHDEBUG%@: owntracks-app-auth discovery OK — login_path=%@", [sself _vcLabel], sself.discoveryLoginPath);
            } else {
                sself.discoveryLoginPath = nil;
                NSLog(@"AUTHDEBUG%@: owntracks-app-auth discovery FAILED — %@", [sself _vcLabel], error.localizedDescription);
            }
        });
    }];
    NSString *oidcURLString = [Settings stringForKey:@"oidc_discovery_url_preference" inMOC:CoreData.sharedInstance.mainMOC];
    NSLog(@"AUTHDEBUG%@: oidc_discovery_url_preference=%@", [self _vcLabel], oidcURLString.length > 0 ? oidcURLString : @"(not set)");
    if (oidcURLString.length > 0) {
        NSURL *oidcURL = [NSURL URLWithString:oidcURLString];
        if (oidcURL) {
            [[WebAppAuthHelper sharedInstance] fetchOIDCAuthorizationEndpointFromDiscoveryURL:oidcURL completion:^(NSURL * _Nullable authEndpointURL, NSError * _Nullable error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(wself) sself = wself;
                    if (!sself) return;
                    sself.oidcAuthorizationEndpointURL = authEndpointURL;
                    NSLog(@"AUTHDEBUG%@: oidcAuthorizationEndpointURL set to %@", [sself _vcLabel], authEndpointURL.absoluteString ?: @"(nil — error)");
                });
            }];
        } else {
            self.oidcAuthorizationEndpointURL = nil;
            NSLog(@"AUTHDEBUG%@: oidc_discovery_url is invalid — oidcAuthorizationEndpointURL=nil", [self _vcLabel]);
        }
    } else {
        self.oidcAuthorizationEndpointURL = nil;
        NSLog(@"AUTHDEBUG%@: no oidc_discovery_url — IdP-host interception disabled, login-path only", [self _vcLabel]);
    }
}

// Manual login button — no IdP URL available, use our own PKCE fallback flow.
- (void)webAppLoginPressed {
    [self startNativeAuthFallback];
}

- (void)loadWebViewWithAccessToken:(NSString *)accessToken refreshToken:(nullable NSString *)refreshToken {
    if (!accessToken.length || !self.webAppOrigin) return;
    NSURL *base = self.webAppBaseURL ?: self.webAppOrigin;
    NSString *basePath = (base.path.length > 0 && ![base.path isEqualToString:@"/"]) ? base.path : @"";
    NSString *path = basePath.length > 0
        ? [basePath stringByAppendingPathComponent:@"auth/native-callback"]
        : @"/auth/native-callback";
    NSURLComponents *c = [NSURLComponents componentsWithURL:base resolvingAgainstBaseURL:NO];
    c.path = path;
    NSMutableArray *queryItems = [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"access_token" value:accessToken]];
    if (refreshToken.length > 0) {
        [queryItems addObject:[NSURLQueryItem queryItemWithName:@"refresh_token" value:refreshToken]];
    }
    c.queryItems = queryItems;
    NSURL *callbackURL = c.URL;
    if (!callbackURL) return;
    NSLog(@"AUTHDEBUG%@: loadWebViewWithAccessToken → %@?access_token=<redacted>&refresh_token=%@", [self _vcLabel], [callbackURL.absoluteString componentsSeparatedByString:@"?"].firstObject, refreshToken.length > 0 ? @"<present>" : @"<none>");
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
    if ([type isEqualToString:@"js_console"]) {
        NSString *level = body[@"level"] ?: @"log";
        NSString *jsMsg = body[@"message"] ?: @"";
        NSLog(@"WEBDIAG%@[%@]: %@", [self _vcLabel], level, jsMsg);
        return;
    }
    if ([type isEqualToString:@"native_callback_complete"]) {
        // React's native-callback component has finished calling userManager.storeUser().
        // Safe to navigate to the app URL now — OIDC client state is initialized.
        NSLog(@"AUTHDEBUG%@: native_callback_complete received — navigating to app", [self _vcLabel]);
        [self forceLoadWebAppURL];
        return;
    }
    if ([type isEqualToString:@"auth_tokens"]) {
        NSString *refreshToken = body[@"refresh_token"];
        NSString *tokenEndpoint = body[@"token_endpoint"];
        NSString *clientId = body[@"client_id"];
        NSURL *webAppURL = self.webAppBaseURL ?: self.webAppOrigin;
        if ([refreshToken isKindOfClass:[NSString class]] && refreshToken.length > 0 &&
            [tokenEndpoint isKindOfClass:[NSString class]] && tokenEndpoint.length > 0 &&
            [clientId isKindOfClass:[NSString class]] && clientId.length > 0 &&
            webAppURL) {
            [[WebAppAuthHelper sharedInstance] storeRefreshToken:refreshToken
                                                    tokenEndpoint:tokenEndpoint
                                                         clientId:clientId
                                                    forWebAppURL:webAppURL];
            NSLog(@"AUTHDEBUG: stored web-provided refresh token context for %@%@", webAppURL.host ?: @"(nil)", webAppURL.path ?: @"");
        } else {
            DDLogWarn(@"[WebAppViewController] auth_tokens message missing required fields");
        }
        return;
    }
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

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    NSLog(@"WEBDIAG%@: didStartProvisional url=%@", [self _vcLabel], webView.URL.absoluteString);
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
    NSLog(@"WEBDIAG%@: didCommit url=%@", [self _vcLabel], webView.URL.absoluteString);
}

- (void)webView:(WKWebView *)webView didReceiveServerRedirectForProvisionalNavigation:(WKNavigation *)navigation {
    NSLog(@"WEBDIAG%@: serverRedirect url=%@", [self _vcLabel], webView.URL.absoluteString);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    NSString *path = webView.URL.path ?: @"";
    NSString *query = webView.URL.query ?: @"";
    NSLog(@"AUTHDEBUG%@: didFinishNavigation url=%@", [self _vcLabel], webView.URL.absoluteString);
    if ([path containsString:@"native-callback"]) {
        // Cookie has been set by the server response. Do NOT navigate immediately — React's
        // native-callback component must first call userManager.storeUser() to initialize the
        // OIDC client's in-memory state before we load /map. React will send a
        // native_callback_complete postMessage when storeUser() has resolved, and we navigate then.
        NSLog(@"AUTHDEBUG%@: native-callback loaded — waiting for React storeUser (native_callback_complete postMessage)", [self _vcLabel]);
    } else if ([path isEqualToString:@"/map"]) {
        // Snapshot page state immediately after /map finishes loading.
        // Returns a value directly to the completionHandler (does NOT use postMessage)
        // so this works even if the message bridge is unavailable on this page.
        NSLog(@"WEBDIAG%@: didFinishNavigation /map — running snapshot evaluateJavaScript", [self _vcLabel]);
        NSString *snapshotJS =
            @"(function(){"
            "function _ssItem(k){try{return k?sessionStorage.getItem(k):null;}catch(e){return null;}}"
            "function _lsItem(k){try{return k?localStorage.getItem(k):null;}catch(e){return null;}}"
            "var ssKeys=[];try{ssKeys=Object.keys(sessionStorage);}catch(e){}"
            "var lsKeys=[];try{lsKeys=Object.keys(localStorage);}catch(e){}"
            "var oidcSS=ssKeys.find(function(k){return k.indexOf('oidc.user:')===0||k.indexOf('oidc.')===0;});"
            "var oidcLS=lsKeys.find(function(k){return k.indexOf('oidc.user:')===0||k.indexOf('oidc.')===0;});"
            "var oidcRaw=_ssItem(oidcSS)||_lsItem(oidcLS);"
            "var oidcUser=null;"
            "try{oidcUser=oidcRaw?JSON.parse(oidcRaw):null;}catch(e){}"
            "var metaCSP=document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]');"
            "return JSON.stringify({"
            "  url:location.href,"
            "  ssKeys:ssKeys.length,"
            "  lsKeys:lsKeys.length,"
            "  oidcKey:oidcSS||oidcLS||null,"
            "  oidcStorage:oidcSS?'session':(oidcLS?'local':'none'),"
            "  oidcUserFound:!!oidcUser,"
            "  oidcExpiresAt:oidcUser?oidcUser.expires_at:null,"
            "  nowEpoch:Math.floor(Date.now()/1000),"
            "  cspMetaTag:metaCSP?metaCSP.getAttribute('content').substring(0,200):'(none)',"
            "  postMessageAvail:!!(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.owntracks)"
            "});"
            "})();";
        __weak typeof(self) wself = self;
        [webView evaluateJavaScript:snapshotJS completionHandler:^(id result, NSError *error) {
            if (error) {
                NSLog(@"WEBDIAG%@: snapshot evalJS FAILED: %@", [wself _vcLabel], error.localizedDescription);
            } else {
                NSLog(@"WEBDIAG%@: snapshot = %@", [wself _vcLabel], result);
            }
        }];
        // 3 seconds after load: inspect the actual rendered DOM to see what React produced.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(wself) sself = wself;
            if (!sself || ![sself.webView.URL.path isEqualToString:@"/map"]) return;
            NSString *domJS =
                @"(function(){"
                "var root=document.getElementById('root')||document.body;"
                "var mapEl=document.querySelector('.maplibregl-map,.mapboxgl-map,[class*=\"map-container\"],[class*=\"MapContainer\"]');"
                "var mapStyle=mapEl?window.getComputedStyle(mapEl):null;"
                "var bodyStyle=window.getComputedStyle(document.body);"
                "var bodyHTML=document.body?document.body.innerHTML.substring(0,600):null;"
                "var scripts=document.querySelectorAll('script');"
                "var scriptSrcs=[];"
                "for(var i=0;i<Math.min(scripts.length,10);i++){"
                "  var s=scripts[i];"
                "  scriptSrcs.push(s.src?s.src.substring(s.src.lastIndexOf('/')+1).substring(0,60):'inline('+s.innerHTML.length+'b)')"
                "}"
                "return JSON.stringify({"
                "  url:location.href,"
                "  bodyChildCount:document.body?document.body.children.length:0,"
                "  rootChildCount:root?root.children.length:0,"
                "  rootHTML:root?root.innerHTML.substring(0,400):null,"
                "  bodyHTML:bodyHTML,"
                "  scriptCount:scripts.length,"
                "  scriptSrcs:scriptSrcs,"
                "  reactHook:typeof window.__REACT_DEVTOOLS_GLOBAL_HOOK__!=='undefined',"
                "  reactRoot:typeof window._reactRootContainer!=='undefined',"
                "  mapFound:!!mapEl,"
                "  mapDisplay:mapStyle?mapStyle.display:null,"
                "  mapWidth:mapEl?mapEl.offsetWidth:null,"
                "  mapHeight:mapEl?mapEl.offsetHeight:null,"
                "  bodyOverflow:bodyStyle.overflow,"
                "  viewportH:window.innerHeight,"
                "  viewportW:window.innerWidth"
                "});"
                "})();";
            [sself.webView evaluateJavaScript:domJS completionHandler:^(id domResult, NSError *domError) {
                if (domError) {
                    NSLog(@"WEBDIAG%@: dom3s evalJS FAILED: %@", [wself _vcLabel], domError.localizedDescription);
                } else {
                    NSLog(@"WEBDIAG%@: dom3s = %@", [wself _vcLabel], domResult);
                }
            }];
        });
    } else if ([query containsString:@"code="] && [query containsString:@"state="]) {
        // React OIDC callback — the React OIDC client will handle this itself. Do nothing.
        NSLog(@"AUTHDEBUG%@: OIDC callback page loaded — React OIDC client will handle token exchange", [self _vcLabel]);
    }
}

// Loads the configured app URL unconditionally (no same-host guard).
// Used after native-callback so we always navigate to /map even though
// native-callback is on the same host as the web app.
- (void)forceLoadWebAppURL {
    NSString *urlString = [Settings stringForKey:@"webappurl_preference" inMOC:CoreData.sharedInstance.mainMOC];
    NSURL *url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
    if (!url) {
        NSLog(@"AUTHDEBUG%@: forceLoadWebAppURL — no web app URL configured", [self _vcLabel]);
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
    NSLog(@"AUTHDEBUG%@: forceLoadWebAppURL → %@", [self _vcLabel], finalURL.absoluteString);
    if (finalURL) {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:finalURL];
        [req setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData];
        [self.webView loadRequest:req];
    }
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *requestURL = navigationAction.request.URL;

    NSLog(@"AUTHDEBUG%@: decidePolicyForNavigationAction scheme=%@ host=%@ path=%@ mainFrame=%@",
          [self _vcLabel],
          requestURL.scheme ?: @"(nil)", requestURL.host ?: @"(nil)", requestURL.path ?: @"(nil)",
          navigationAction.targetFrame.isMainFrame ? @"YES" : @"NO");
    NSLog(@"AUTHDEBUG%@:   oidcEndpoint=%@ discoveryLoginPath=%@",
          [self _vcLabel],
          self.oidcAuthorizationEndpointURL.absoluteString ?: @"(nil)",
          self.discoveryLoginPath ?: @"(nil)");

    // Only intercept main-frame navigations.  Sub-frame navigations (e.g. hidden iframes
    // used by the React OIDC client for silent token renewal) must be allowed through —
    // intercepting them would cause a jarring full ASWebAuthenticationSession popup instead
    // of a transparent background refresh.
    if (!navigationAction.targetFrame.isMainFrame) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }

    // OIDC callback routes with code/state must never be intercepted by login-path heuristics.
    NSURLComponents *requestComponents = [NSURLComponents componentsWithURL:requestURL resolvingAgainstBaseURL:NO];
    BOOL hasCode = NO;
    BOOL hasState = NO;
    for (NSURLQueryItem *item in requestComponents.queryItems ?: @[]) {
        if ([item.name isEqualToString:@"code"] && item.value.length > 0) hasCode = YES;
        if ([item.name isEqualToString:@"state"] && item.value.length > 0) hasState = YES;
    }
    if (hasCode && hasState) {
        NSLog(@"AUTHDEBUG%@: → ALLOW callback-style navigation with code/state", [self _vcLabel]);
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }

    // Extract the prompt parameter for logging and suppress-window checks.
    NSString *promptValue = nil;
    for (NSURLQueryItem *item in requestComponents.queryItems ?: @[]) {
        if ([item.name isEqualToString:@"prompt"]) { promptValue = item.value; break; }
    }

    // Post-passthrough suppress window: if a passthrough just completed, cancel the next
    // IdP navigation silently instead of starting another passthrough (which would show a
    // second auth prompt). React either retries a silent renewal (prompt=none) — which it
    // can handle via its own fallback — or it retried after a failed code exchange, in which
    // case we avoid the looping double-prompt while we gather log data to diagnose the root cause.
    BOOL inSuppressWindow = self.passthroughLastCompletedAt != nil &&
        [[NSDate date] timeIntervalSinceDate:self.passthroughLastCompletedAt] < 30.0;

    // Intercept navigation to the IdP authorization endpoint. Proxy it through
    // ASWebAuthenticationSession (for SSO) then hand the code back to the React OIDC client.
    // The oidcAuthorizationEndpointURL path is specific to the sauron OIDC application, so
    // the Authentik forward-auth outpost (which uses a different Authentik application and
    // a different path) will not match here.
    if (self.oidcAuthorizationEndpointURL && requestURL.host && requestURL.path.length > 0 &&
        [requestURL.host isEqualToString:self.oidcAuthorizationEndpointURL.host] &&
        (requestURL.scheme.length == 0 || [requestURL.scheme isEqualToString:self.oidcAuthorizationEndpointURL.scheme]) &&
        ([requestURL.path isEqualToString:self.oidcAuthorizationEndpointURL.path] || [requestURL.path hasPrefix:[self.oidcAuthorizationEndpointURL.path stringByAppendingString:@"/"]])) {
        if (inSuppressWindow) {
            NSLog(@"AUTHDEBUG%@: → SUPPRESS IdP endpoint (within 30s post-passthrough window, prompt=%@)", [self _vcLabel], promptValue ?: @"(none)");
            decisionHandler(WKNavigationActionPolicyCancel);
            return;
        }
        NSLog(@"AUTHDEBUG%@: → INTERCEPT IdP endpoint — passthrough via ASWebAuthenticationSession (prompt=%@)", [self _vcLabel], promptValue ?: @"(none)");
        decisionHandler(WKNavigationActionPolicyCancel);
        [self startPassthroughAuthWithIdPURL:requestURL];
        return;
    }

    // Fallback: intercept any main-frame navigation to an external (non-web-app) host
    // that looks like an OIDC authorization request (has response_type=code).
    // Catches the race condition where async discovery hasn't returned yet on first load,
    // so oidcAuthorizationEndpointURL is still nil when the web app redirects to the IdP.
    //
    // Only intercept if client_id matches our configured sauron PKCE client. The Authentik
    // forward-auth outpost uses a different Authentik application (different client_id), so
    // its authorize redirect must NOT be intercepted here — doing so replaces its redirect_uri
    // with owntracks://, which Authentik rejects (not registered for the outpost client),
    // leaving ASWebAuthenticationSession stuck on an error page (spinning wheel).
    NSString *knownClientId = [Settings stringForKey:@"oauth_client_id_preference" inMOC:CoreData.sharedInstance.mainMOC];
    BOOL isOurOIDCClient = NO;
    if (knownClientId.length > 0) {
        for (NSURLQueryItem *item in requestComponents.queryItems ?: @[]) {
            if ([item.name isEqualToString:@"client_id"] &&
                [item.value isEqualToString:knownClientId]) {
                isOurOIDCClient = YES;
                break;
            }
        }
    }
    if (isOurOIDCClient &&
        self.webAppOrigin && requestURL.host &&
        ![requestURL.host isEqualToString:self.webAppOrigin.host]) {
        NSURLComponents *comps = [NSURLComponents componentsWithURL:requestURL resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem *item in comps.queryItems) {
            if ([item.name isEqualToString:@"response_type"] &&
                [item.value isEqualToString:@"code"]) {
                if (inSuppressWindow) {
                    NSLog(@"AUTHDEBUG%@: → SUPPRESS external OIDC request (within 30s post-passthrough window, prompt=%@)", [self _vcLabel], promptValue ?: @"(none)");
                    decisionHandler(WKNavigationActionPolicyCancel);
                    return;
                }
                NSLog(@"AUTHDEBUG%@: → INTERCEPT external OIDC request (fallback, client_id matches sauron, prompt=%@)", [self _vcLabel], promptValue ?: @"(none)");
                decisionHandler(WKNavigationActionPolicyCancel);
                [self startPassthroughAuthWithIdPURL:requestURL];
                return;
            }
        }
    }

    // Intercept navigation to the web app's login path (from owntracks-app-auth discovery).
    // No IdP URL available here, so fall back to our own PKCE flow.
    if (self.webAppOrigin && self.discoveryLoginPath.length > 0 &&
        requestURL.host && [requestURL.host isEqualToString:self.webAppOrigin.host] &&
        ([requestURL.scheme isEqualToString:self.webAppOrigin.scheme] || !requestURL.scheme) &&
        requestURL.path.length > 0) {
        NSString *loginPath = [self.discoveryLoginPath hasPrefix:@"/"] ? self.discoveryLoginPath : [@"/" stringByAppendingString:self.discoveryLoginPath];
        if ([requestURL.path isEqualToString:loginPath]) {
            NSLog(@"AUTHDEBUG%@: → INTERCEPT login path '%@' — fallback native auth", [self _vcLabel], loginPath);
            decisionHandler(WKNavigationActionPolicyCancel);
            [self startNativeAuthFallback];
            return;
        }
    }

    NSLog(@"AUTHDEBUG%@: → ALLOW", [self _vcLabel]);
    decisionHandler(WKNavigationActionPolicyAllow);
}

// Primary: proxy the React app's own OIDC redirect through ASWebAuthenticationSession for SSO,
// then return the authorization code to the React OIDC client to complete its own token exchange.
// This path is React-initiated — the web app redirected to the IdP; we proxy through ASWebAuth
// so iOS can use SSO cookies. This is the expected auth flow (not a token refresh failure).
- (void)startPassthroughAuthWithIdPURL:(NSURL *)idpURL {
    NSURLComponents *_dbgComps = [NSURLComponents componentsWithURL:idpURL resolvingAgainstBaseURL:NO];
    NSString *_dbgPrompt = nil;
    for (NSURLQueryItem *item in _dbgComps.queryItems) {
        if ([item.name isEqualToString:@"prompt"]) { _dbgPrompt = item.value; break; }
    }
    NSLog(@"AUTHDEBUG%@: startPassthroughAuth — REACT-INITIATED OIDC redirect (expected flow), prompt=%@", [self _vcLabel], _dbgPrompt ?: @"(not set — likely initial auth or expired session)");
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
        NSLog(@"AUTHDEBUG%@: startPassthroughAuth — no redirect_uri in IdP URL, using fallback", [self _vcLabel]);
        [self startNativeAuthFallback];
        return;
    }
    idpComponents.queryItems = items;
    NSURL *modifiedURL = idpComponents.URL;
    self.pendingOIDCRedirectURI = originalRedirectURI;
    NSLog(@"AUTHDEBUG%@: startPassthroughAuth — originalRedirectURI=%@", [self _vcLabel], originalRedirectURI);

    __weak typeof(self) wself = self;
    [[WebAppAuthHelper sharedInstance] startPassthroughSessionWithURL:modifiedURL
                                                           completion:^(NSURL *callbackURL, NSError *error) {
        __strong typeof(wself) sself = wself;
        if (!sself) return;
        if (error) {
            NSLog(@"AUTHDEBUG%@: passthrough session error: %@", [sself _vcLabel], error.localizedDescription);
            return;
        }
        if (!callbackURL) {
            NSLog(@"AUTHDEBUG%@: passthrough session cancelled by user", [sself _vcLabel]);
            return;
        }
        // callbackURL = owntracks:///auth/callback?code=CODE&state=STATE&...
        // Reconstruct as: {originalRedirectURI}?code=CODE&state=STATE&...
        NSURLComponents *cb = [NSURLComponents componentsWithURL:callbackURL resolvingAgainstBaseURL:NO];
        NSURLComponents *reactCB = [NSURLComponents componentsWithString:sself.pendingOIDCRedirectURI];
        if (!reactCB) {
            NSLog(@"AUTHDEBUG%@: passthrough — invalid pendingOIDCRedirectURI", [sself _vcLabel]);
            return;
        }
        NSMutableArray<NSURLQueryItem *> *reactItems = [NSMutableArray arrayWithArray:reactCB.queryItems ?: @[]];
        for (NSURLQueryItem *item in cb.queryItems) {
            [reactItems addObject:item];
        }
        reactCB.queryItems = reactItems;
        NSURL *reactCallbackURL = reactCB.URL;
        NSLog(@"AUTHDEBUG%@: passthrough complete — loading React OIDC callback URL (code redacted)", [sself _vcLabel]);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(wself) sself2 = wself;
            if (!sself2) return;
            sself2.pendingOIDCRedirectURI = nil;
            sself2.placeholderLabel.hidden = YES;
            sself2.webView.hidden = NO;
            sself2.passthroughLastCompletedAt = [NSDate date];
            [sself2.webView loadRequest:[NSURLRequest requestWithURL:reactCallbackURL]];
        });
    }];
}

// Fallback: try a silent refresh first; only fall through to the full PKCE OAuth flow
// (which shows UI) if there is no stored refresh token or the refresh has expired.
- (void)startNativeAuthFallback {
    if (!self.webAppOrigin) return;
    NSURL *webAppURL = self.webAppBaseURL ?: self.webAppOrigin;
    NSString *clientId = [Settings stringForKey:@"oauth_client_id_preference" inMOC:CoreData.sharedInstance.mainMOC];
    NSLog(@"AUTHDEBUG%@: startNativeAuthFallback — webAppURL=%@, checking for stored refresh token first", [self _vcLabel], webAppURL.absoluteString);
    __weak typeof(self) wself = self;
    [[WebAppAuthHelper sharedInstance] attemptSilentRefreshForWebAppURL:webAppURL
                                                               clientId:clientId.length > 0 ? clientId : nil
                                                             completion:^(NSString *accessToken, NSError *error) {
        __strong typeof(wself) sself = wself;
        if (!sself) return;
        if (accessToken.length > 0) {
            NSLog(@"AUTHDEBUG%@: startNativeAuthFallback — silent refresh succeeded, skipping OAuth prompt", [sself _vcLabel]);
            [sself loadWebViewWithAccessToken:accessToken refreshToken:nil];
            return;
        }
        // See [WebAppAuthHelper] REAUTH REASON log above for why silent refresh returned nil.
        NSLog(@"AUTHDEBUG%@: startNativeAuthFallback — silent refresh returned nil (see REAUTH REASON above), starting full OAuth flow", [sself _vcLabel]);
        [sself startFullNativeAuth];
    }];
}

- (void)startFullNativeAuth {
    if (!self.webAppOrigin) return;
    NSLog(@"AUTHDEBUG%@: startFullNativeAuth — PRESENTING PROVIDER LOGIN UI (ASWebAuthenticationSession PKCE)", [self _vcLabel]);
    NSURL *oidcURL = nil;
    NSString *clientId = [Settings stringForKey:@"oauth_client_id_preference" inMOC:CoreData.sharedInstance.mainMOC];
    NSString *oidcURLString = [Settings stringForKey:@"oidc_discovery_url_preference" inMOC:CoreData.sharedInstance.mainMOC];
    if (oidcURLString.length > 0) oidcURL = [NSURL URLWithString:oidcURLString];
    __weak typeof(self) wself = self;
    NSURL *webAppURL = self.webAppBaseURL ?: self.webAppOrigin;
    [[WebAppAuthHelper sharedInstance] startAuthWithWebAppOrigin:webAppURL
                                                 oidcDiscoveryURL:oidcURL
                                                         clientId:clientId.length > 0 ? clientId : nil
                                          presentingViewController:self
                                                       completion:^(NSString * _Nullable accessToken, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(wself) sself = wself;
            if (!sself) return;
            if (!accessToken.length) {
                // Auth failed or cancelled — force-reload to recover from any blank/stuck state.
                NSLog(@"AUTHDEBUG%@: startFullNativeAuth — auth failed/cancelled, reloading web app", [sself _vcLabel]);
                [sself forceLoadWebAppURL];
                return;
            }
            [sself loadWebViewWithAccessToken:accessToken refreshToken:nil];
        });
    }];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    NSLog(@"WEBDIAG%@: didFailNavigation url=%@ error=%@", [self _vcLabel], webView.URL.absoluteString, error.localizedDescription);
    DDLogWarn(@"[WebAppViewController] didFailNavigation: %@", error.localizedDescription);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    NSLog(@"WEBDIAG%@: didFailProvisional url=%@ error=%@", [self _vcLabel], webView.URL.absoluteString, error.localizedDescription);
    DDLogWarn(@"[WebAppViewController] didFailProvisionalNavigation: %@", error.localizedDescription);
}

// Called when iOS kills the WKWebView content process (e.g. due to memory pressure).
// After termination webView.URL still holds the last URL but the page is blank.
// We must reload; without this the user sees a blank screen that never recovers.
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    NSLog(@"AUTHDEBUG%@: webViewWebContentProcessDidTerminate — reloading web app", [self _vcLabel]);
    [self forceLoadWebAppURL];
}

@end
