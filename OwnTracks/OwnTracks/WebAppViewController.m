//
//  WebAppViewController.m
//  OwnTracks
//
//  Web App tab: hosts a WKWebView loading the configured web app URL.
//  Supports postMessage from the web app for provisioning (type: "config").
//

#import "WebAppViewController.h"
#import "Settings.h"
#import "CoreData.h"
#import "OwnTracksAppDelegate.h"
#import <WebKit/WebKit.h>
#import <CocoaLumberjack/CocoaLumberjack.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

static NSString * const kWebAppMessageHandlerName = @"owntracks";

@interface WebAppViewController () <WKNavigationDelegate, WKScriptMessageHandler>
@property (strong, nonatomic) WKWebView *webView;
@property (strong, nonatomic) UILabel *placeholderLabel;
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

    [self loadWebAppURL];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadWebAppURL];
}

- (void)dealloc {
    [self.webView.configuration.userContentController removeScriptMessageHandlerForName:kWebAppMessageHandlerName];
}

- (void)loadWebAppURL {
    NSString *urlString = [Settings stringForKey:@"webappurl_preference" inMOC:CoreData.sharedInstance.mainMOC];
    if (urlString.length > 0) {
        NSURL *url = [NSURL URLWithString:urlString];
        if (url) {
            NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
            NSMutableArray<NSURLQueryItem *> *queryItems = [NSMutableArray arrayWithArray:components.queryItems ?: @[]];
            [queryItems addObject:[NSURLQueryItem queryItemWithName:@"embedded" value:@"1"]];
            if ([self appNeedsProvisioning]) {
                [queryItems addObject:[NSURLQueryItem queryItemWithName:@"needs_provision" value:@"1"]];
            }
            components.queryItems = queryItems;
            NSURL *finalURL = components.URL;
            if (finalURL) {
                self.placeholderLabel.hidden = YES;
                self.webView.hidden = NO;
                [self.webView loadRequest:[NSURLRequest requestWithURL:finalURL]];
                return;
            }
        }
    }
    self.placeholderLabel.hidden = NO;
    self.webView.hidden = YES;
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

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    DDLogWarn(@"[WebAppViewController] didFailNavigation: %@", error.localizedDescription);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    DDLogWarn(@"[WebAppViewController] didFailProvisionalNavigation: %@", error.localizedDescription);
}

@end
