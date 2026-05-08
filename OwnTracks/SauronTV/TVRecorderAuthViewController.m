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

static NSURL *TVRecorderAuthCurrentUserURL(void) {
    if (!kTVWebAppOriginURL.length) return nil;
    NSURL *baseURL = [NSURL URLWithString:kTVWebAppOriginURL];
    if (!baseURL) return nil;
    return [NSURL URLWithString:@"api/authorization/user" relativeToURL:baseURL].absoluteURL;
}

static NSURL *TVRecorderAuthAvatarURLForPath(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || !path.length || !kTVWebAppOriginURL.length) return nil;
    NSURL *baseURL = [NSURL URLWithString:kTVWebAppOriginURL];
    if (!baseURL) return nil;
    return [NSURL URLWithString:path relativeToURL:baseURL].absoluteURL;
}

static UIImage *TVRecorderAuthImageFromPictureDataURI(NSString *dataURI) {
    if (![dataURI isKindOfClass:[NSString class]] || !dataURI.length) return nil;
    NSRange comma = [dataURI rangeOfString:@","];
    if (comma.location == NSNotFound || comma.location + 1 >= dataURI.length) return nil;
    NSString *meta = [dataURI substringToIndex:comma.location].lowercaseString;
    if (![meta containsString:@";base64"]) return nil;
    NSString *encoded = [dataURI substringFromIndex:comma.location + 1];
    NSData *imgData = [[NSData alloc] initWithBase64EncodedString:encoded options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!imgData.length) return nil;
    return [UIImage imageWithData:imgData];
}

@interface TVRecorderAuthViewController ()
@property (strong, nonatomic) UILabel *statusLabel;
@property (strong, nonatomic) UIButton *signInButton;
@property (strong, nonatomic) UIButton *signOutButton;
@property (strong, nonatomic) UIImageView *profileImageView;
@property (strong, nonatomic) UILabel *profileNameLabel;
@property (copy, nonatomic) NSString *profileRequestToken;
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

    _profileImageView = [[UIImageView alloc] init];
    _profileImageView.translatesAutoresizingMaskIntoConstraints = NO;
    _profileImageView.contentMode = UIViewContentModeScaleAspectFill;
    _profileImageView.layer.cornerRadius = 44;
    _profileImageView.layer.borderWidth = 2;
    _profileImageView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    _profileImageView.clipsToBounds = YES;
    _profileImageView.hidden = YES;
    [self.view addSubview:_profileImageView];

    _profileNameLabel = [[UILabel alloc] init];
    _profileNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _profileNameLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    _profileNameLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightSemibold];
    _profileNameLabel.textAlignment = NSTextAlignmentCenter;
    _profileNameLabel.numberOfLines = 1;
    _profileNameLabel.hidden = YES;
    [self.view addSubview:_profileNameLabel];

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
        [_profileImageView.topAnchor constraintEqualToAnchor:g.topAnchor constant:120],
        [_profileImageView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_profileImageView.widthAnchor constraintEqualToConstant:88],
        [_profileImageView.heightAnchor constraintEqualToConstant:88],

        [_profileNameLabel.topAnchor constraintEqualToAnchor:_profileImageView.bottomAnchor constant:12],
        [_profileNameLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:48],
        [_profileNameLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-48],

        [_statusLabel.topAnchor constraintEqualToAnchor:_profileNameLabel.bottomAnchor constant:24],
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
    self.profileRequestToken = nil;
    self.profileImageView.image = nil;
    self.profileImageView.hidden = YES;
    self.profileNameLabel.text = @"";
    self.profileNameLabel.hidden = YES;

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
        self.signInButton.hidden = YES;
        [self fetchProfileUsingToken:[TVRecorderTokenStore accessToken] retryOnUnauthorized:YES];
    } else if (hasRefresh) {
        self.statusLabel.text = @"Access token expired; refresh will run when needed, or sign in again.";
        self.signInButton.hidden = NO;
        __weak typeof(self) weak = self;
        [[TVRecorderOAuthClient shared] refreshAccessTokenWithCompletion:^(NSString * _Nullable accessToken,
                                                                           NSError * _Nullable error) {
            __strong typeof(weak) selfStrong = weak;
            if (!selfStrong || !accessToken.length) return;
            [selfStrong fetchProfileUsingToken:accessToken retryOnUnauthorized:NO];
        }];
    } else if (hasAccess) {
        self.statusLabel.text = @"Access token present but expired; sign in again or wait for a route fetch to refresh.";
        self.signInButton.hidden = NO;
    } else {
        self.statusLabel.text = @"Not signed in. Use Sign in to show a code on this TV.";
        self.signInButton.hidden = NO;
    }
}

- (void)fetchProfileUsingToken:(NSString *)token retryOnUnauthorized:(BOOL)allowRetry {
    if (!token.length) return;
    NSURL *url = TVRecorderAuthCurrentUserURL();
    if (!url) return;
    self.profileRequestToken = token;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    __weak typeof(self) weak = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        __strong typeof(weak) selfStrong = weak;
        if (!selfStrong || err || !data.length) return;
        if (![selfStrong.profileRequestToken isEqualToString:token]) return;
        NSHTTPURLResponse *http = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;
        if (http.statusCode == 401 && allowRetry && [TVRecorderTokenStore refreshToken].length) {
            [[TVRecorderOAuthClient shared] refreshAccessTokenWithCompletion:^(NSString * _Nullable freshToken,
                                                                               NSError * _Nullable refreshErr) {
                __strong typeof(weak) retrySelf = weak;
                if (!retrySelf || !freshToken.length) return;
                [retrySelf fetchProfileUsingToken:freshToken retryOnUnauthorized:NO];
            }];
            return;
        }
        if (http.statusCode < 200 || http.statusCode >= 300) return;

        NSError *jsonErr = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
        if (jsonErr || ![obj isKindOfClass:[NSDictionary class]]) return;
        NSDictionary *user = (NSDictionary *)obj;
        NSString *displayName = [user[@"displayName"] isKindOfClass:[NSString class]] ? user[@"displayName"] : nil;
        NSString *picture = [user[@"picture"] isKindOfClass:[NSString class]] ? user[@"picture"] : nil;
        UIImage *avatar = TVRecorderAuthImageFromPictureDataURI(picture);
        NSString *userImagePath = [user[@"userImage"] isKindOfClass:[NSString class]] ? user[@"userImage"] : nil;

        void (^applyProfile)(UIImage *) = ^(UIImage *img) {
            if (!img) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weak) applySelf = weak;
                if (!applySelf) return;
                if (![applySelf.profileRequestToken isEqualToString:token]) return;
                applySelf.profileImageView.image = img;
                applySelf.profileImageView.hidden = NO;
                applySelf.profileNameLabel.text = displayName.length ? displayName : @"Signed in";
                applySelf.profileNameLabel.hidden = NO;
            });
        };

        if (avatar) {
            applyProfile(avatar);
            return;
        }
        NSURL *avatarURL = TVRecorderAuthAvatarURLForPath(userImagePath);
        if (!avatarURL) return;
        NSMutableURLRequest *imgReq = [NSMutableURLRequest requestWithURL:avatarURL];
        imgReq.HTTPMethod = @"GET";
        [imgReq setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
        [[[NSURLSession sharedSession] dataTaskWithRequest:imgReq
                                         completionHandler:^(NSData *imgData, NSURLResponse *imgResp, NSError *imgErr) {
            if (imgErr || !imgData.length) return;
            NSHTTPURLResponse *imgHTTP = [imgResp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)imgResp : nil;
            if (imgHTTP.statusCode < 200 || imgHTTP.statusCode >= 300) return;
            applyProfile([UIImage imageWithData:imgData]);
        }] resume];
    }] resume];
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
