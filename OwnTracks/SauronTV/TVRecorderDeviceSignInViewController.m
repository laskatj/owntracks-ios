//
//  TVRecorderDeviceSignInViewController.m
//  SauronTV
//

#import "TVRecorderDeviceSignInViewController.h"
#import "TVRecorderOAuthClient.h"
#import "TVRecorderTokenStore.h"
#import "TVHardcodedConfig.h"
#import <CocoaLumberjack/CocoaLumberjack.h>
#import <CoreImage/CoreImage.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

/// RFC 8628 `verification_uri_complete`, or `verification_uri` + `code` (Authentik-style prefilled link).
static NSString *TVRecorderDeviceSignInQRPayload(NSString *verificationURIComplete, NSString *verificationURI,
                                                 NSString *userCode) {
    if ([verificationURIComplete isKindOfClass:[NSString class]] && verificationURIComplete.length) {
        return verificationURIComplete;
    }
    if (!verificationURI.length || !userCode.length) return nil;
    NSURL *base = [NSURL URLWithString:verificationURI];
    if (!base) return nil;
    NSURLComponents *c = [NSURLComponents componentsWithURL:base resolvingAgainstBaseURL:NO];
    NSMutableArray<NSURLQueryItem *> *items = [c.queryItems mutableCopy] ?: [NSMutableArray array];
    BOOL hasCode = NO;
    for (NSURLQueryItem *qi in items) {
        if ([qi.name isEqualToString:@"code"]) {
            hasCode = YES;
            break;
        }
    }
    if (!hasCode) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"code" value:userCode]];
    }
    c.queryItems = items;
    return c.URL.absoluteString;
}

static BOOL TVRecorderDeviceSignInIsTransientURLError(NSError *err) {
    if (![err.domain isEqualToString:NSURLErrorDomain]) return NO;
    switch ((NSInteger)err.code) {
        case NSURLErrorTimedOut:
        case NSURLErrorCannotFindHost:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorDNSLookupFailed:
        case NSURLErrorNotConnectedToInternet:
        case NSURLErrorInternationalRoamingOff:
        case NSURLErrorDataNotAllowed:
            return YES;
        default:
            return NO;
    }
}

static UIImage *TVRecorderDeviceSignInQRImage(NSString *string, CGFloat sidePoints) {
    if (!string.length || sidePoints < 32) return nil;
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return nil;
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:data forKey:@"inputMessage"];
    [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *ci = filter.outputImage;
    if (!ci) return nil;
    CGFloat w = CGRectGetWidth(ci.extent);
    if (w < 1) return nil;
    CGFloat scale = sidePoints / w;
    CIImage *scaled = [ci imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CIContext *ctx = [CIContext context];
    CGImageRef cg = [ctx createCGImage:scaled fromRect:scaled.extent];
    if (!cg) return nil;
    UIImage *img = [UIImage imageWithCGImage:cg scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    return img;
}

static NSURL *TVRecorderDeviceSignInCurrentUserURL(void) {
    if (!kTVWebAppOriginURL.length) return nil;
    NSURL *baseURL = [NSURL URLWithString:kTVWebAppOriginURL];
    if (!baseURL) return nil;
    return [NSURL URLWithString:@"api/authorization/user" relativeToURL:baseURL].absoluteURL;
}

static UIImage *TVRecorderDeviceSignInImageFromPictureDataURI(NSString *dataURI) {
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

static NSURL *TVRecorderDeviceSignInAvatarURLForPath(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || !path.length || !kTVWebAppOriginURL.length) return nil;
    NSURL *baseURL = [NSURL URLWithString:kTVWebAppOriginURL];
    if (!baseURL) return nil;
    return [NSURL URLWithString:path relativeToURL:baseURL].absoluteURL;
}

@interface TVRecorderDeviceSignInViewController ()
@property (copy, nonatomic) void (^finish)(BOOL success, NSError * _Nullable err);
@property (strong, nonatomic) UILabel *titleLabel;
@property (strong, nonatomic) UILabel *instructionLabel;
@property (strong, nonatomic) UIImageView *profileImageView;
@property (strong, nonatomic) UILabel *profileNameLabel;
@property (strong, nonatomic) UIImageView *qrImageView;
@property (strong, nonatomic) NSLayoutConstraint *qrHeightConstraint;
@property (strong, nonatomic) UILabel *uriLabel;
@property (strong, nonatomic) UILabel *codeLabel;
@property (strong, nonatomic) UIButton *cancelButton;
@property (nonatomic, copy) NSString *deviceCode;
@property (nonatomic) NSTimeInterval pollInterval;
@property (nonatomic) NSDate *expiresAt;
@property (nonatomic) BOOL cancelled;
@property (nonatomic, strong) NSTimer *pollTimer;
/// After the first wait we use the server's `interval`; the first wait is longer so the URL/code stays readable.
@property (nonatomic) BOOL didRunFirstPoll;
@property (nonatomic) NSUInteger transientPollFailureCount;
@end

@implementation TVRecorderDeviceSignInViewController

- (instancetype)initWithCompletion:(void (^)(BOOL, NSError * _Nullable))completion {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _finish = [completion copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.text = @"Sign in to Recorder";
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.font = [UIFont systemFontOfSize:36 weight:UIFontWeightBold];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:_titleLabel];

    _instructionLabel = [[UILabel alloc] init];
    _instructionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _instructionLabel.textColor = [UIColor colorWithWhite:0.75 alpha:1];
    _instructionLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightRegular];
    _instructionLabel.textAlignment = NSTextAlignmentCenter;
    _instructionLabel.numberOfLines = 0;
    _instructionLabel.text = @"Scan the QR code with your phone, or open the URL below and enter the code.";
    [self.view addSubview:_instructionLabel];

    _profileImageView = [[UIImageView alloc] init];
    _profileImageView.translatesAutoresizingMaskIntoConstraints = NO;
    _profileImageView.contentMode = UIViewContentModeScaleAspectFill;
    _profileImageView.clipsToBounds = YES;
    _profileImageView.layer.cornerRadius = 52;
    _profileImageView.layer.borderWidth = 2;
    _profileImageView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    _profileImageView.hidden = YES;
    [self.view addSubview:_profileImageView];

    _profileNameLabel = [[UILabel alloc] init];
    _profileNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _profileNameLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    _profileNameLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
    _profileNameLabel.textAlignment = NSTextAlignmentCenter;
    _profileNameLabel.numberOfLines = 1;
    _profileNameLabel.hidden = YES;
    [self.view addSubview:_profileNameLabel];

    _qrImageView = [[UIImageView alloc] init];
    _qrImageView.translatesAutoresizingMaskIntoConstraints = NO;
    _qrImageView.contentMode = UIViewContentModeScaleAspectFit;
    _qrImageView.backgroundColor = UIColor.whiteColor;
    _qrImageView.layer.cornerRadius = 8;
    _qrImageView.clipsToBounds = YES;
    _qrImageView.accessibilityLabel = @"Sign-in link QR code";
    _qrImageView.hidden = YES;
    [self.view addSubview:_qrImageView];

    _uriLabel = [[UILabel alloc] init];
    _uriLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _uriLabel.textColor = [UIColor systemBlueColor];
    _uriLabel.font = [UIFont monospacedSystemFontOfSize:22 weight:UIFontWeightRegular];
    _uriLabel.textAlignment = NSTextAlignmentCenter;
    _uriLabel.numberOfLines = 0;
    _uriLabel.adjustsFontSizeToFitWidth = YES;
    _uriLabel.minimumScaleFactor = 0.5;
    [self.view addSubview:_uriLabel];

    _codeLabel = [[UILabel alloc] init];
    _codeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _codeLabel.textColor = UIColor.whiteColor;
    _codeLabel.font = [UIFont monospacedSystemFontOfSize:48 weight:UIFontWeightBold];
    _codeLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:_codeLabel];

    _cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_cancelButton setTitle:@"Cancel" forState:UIControlStateNormal];
    _cancelButton.titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightMedium];
    [_cancelButton addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventPrimaryActionTriggered];
    [self.view addSubview:_cancelButton];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    _qrHeightConstraint = [_qrImageView.heightAnchor constraintEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.topAnchor constraintEqualToAnchor:g.topAnchor constant:48],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:40],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-40],

        [_instructionLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:20],
        [_instructionLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:40],
        [_instructionLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-40],

        [_profileImageView.topAnchor constraintEqualToAnchor:_instructionLabel.bottomAnchor constant:20],
        [_profileImageView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_profileImageView.heightAnchor constraintEqualToConstant:104],
        [_profileImageView.widthAnchor constraintEqualToConstant:104],

        [_profileNameLabel.topAnchor constraintEqualToAnchor:_profileImageView.bottomAnchor constant:10],
        [_profileNameLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:40],
        [_profileNameLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-40],

        [_qrImageView.topAnchor constraintEqualToAnchor:_profileNameLabel.bottomAnchor constant:24],
        [_qrImageView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_qrImageView.widthAnchor constraintEqualToAnchor:_qrImageView.heightAnchor],
        [_qrImageView.widthAnchor constraintLessThanOrEqualToAnchor:g.widthAnchor multiplier:0.45],
        _qrHeightConstraint,

        [_uriLabel.topAnchor constraintEqualToAnchor:_qrImageView.bottomAnchor constant:24],
        [_uriLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:32],
        [_uriLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-32],

        [_codeLabel.topAnchor constraintEqualToAnchor:_uriLabel.bottomAnchor constant:20],
        [_codeLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:32],
        [_codeLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-32],

        [_cancelButton.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-40],
        [_cancelButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    ]];

    [self fetchCurrentUserProfileIfSignedIn];
    [self startDeviceFlowWithAuthorizationRetries:2];
}

- (void)dealloc {
    [self.pollTimer invalidate];
}

- (void)cancelTapped {
    self.cancelled = YES;
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    NSError *e = [NSError errorWithDomain:TVRecorderOAuthErrorDomain
                                     code:TVRecorderOAuthErrorCancelled
                                 userInfo:@{NSLocalizedDescriptionKey: @"Cancelled"}];
    [self dismissViewControllerAnimated:YES completion:^{
        if (self.finish) self.finish(NO, e);
    }];
}

- (void)startDeviceFlowWithAuthorizationRetries:(NSInteger)retriesLeft {
    __weak typeof(self) weak = self;
    [[TVRecorderOAuthClient shared] requestDeviceAuthorizationWithCompletion:^(NSDictionary *json, NSError *err) {
        __strong typeof(weak) selfStrong = weak;
        if (!selfStrong || selfStrong.cancelled) return;
        if (err || !json) {
            if (retriesLeft > 0 && TVRecorderDeviceSignInIsTransientURLError(err)) {
                DDLogWarn(@"[TVRecorderDeviceSignIn] device authorize transient error %@ %ld — retrying (%ld left)",
                          err.domain, (long)err.code, (long)retriesLeft);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    __strong typeof(weak) s = weak;
                    if (s && !s.cancelled) {
                        [s startDeviceFlowWithAuthorizationRetries:retriesLeft - 1];
                    }
                });
                return;
            }
            [selfStrong failWithError:err];
            return;
        }
        NSString *dc = json[@"device_code"];
        NSString *uc = json[@"user_code"];
        NSString *vu = json[@"verification_uri"];
        id vucObj = json[@"verification_uri_complete"];
        NSString *vuc = [vucObj isKindOfClass:[NSString class]] ? (NSString *)vucObj : nil;
        NSNumber *exp = json[@"expires_in"];
        NSNumber *iv = json[@"interval"];
        if (!dc.length || !uc.length || !vu.length) {
            [selfStrong failWithError:[NSError errorWithDomain:TVRecorderOAuthErrorDomain
                                                            code:TVRecorderOAuthErrorNetwork
                                                        userInfo:@{NSLocalizedDescriptionKey: @"Bad device response"}]];
            return;
        }
        selfStrong.deviceCode = dc;
        selfStrong.transientPollFailureCount = 0;
        selfStrong.uriLabel.text = vu;
        selfStrong.codeLabel.text = uc;

        NSString *qrPayload = TVRecorderDeviceSignInQRPayload(vuc, vu, uc);
        CGFloat qrSide = MIN(420, UIScreen.mainScreen.bounds.size.width * 0.42);
        UIImage *qrImg = TVRecorderDeviceSignInQRImage(qrPayload, qrSide);
        if (qrImg) {
            selfStrong.qrImageView.image = qrImg;
            selfStrong.qrImageView.hidden = NO;
            selfStrong.qrHeightConstraint.constant = qrSide;
        } else {
            selfStrong.qrImageView.image = nil;
            selfStrong.qrImageView.hidden = YES;
            selfStrong.qrHeightConstraint.constant = 0;
            if (qrPayload.length) {
                DDLogWarn(@"[TVRecorderDeviceSignIn] could not build QR image for payload length=%lu",
                          (unsigned long)qrPayload.length);
            }
        }
        NSTimeInterval interval = iv.doubleValue > 0 ? iv.doubleValue : 5.0;
        selfStrong.pollInterval = interval;
        NSInteger ex = exp.integerValue > 0 ? exp.integerValue : 300;
        selfStrong.expiresAt = [NSDate dateWithTimeIntervalSinceNow:ex];

        [selfStrong schedulePoll];
    }];
}

- (void)schedulePoll {
    [self.pollTimer invalidate];
    if (self.cancelled) return;
    if ([NSDate date].timeIntervalSince1970 >= self.expiresAt.timeIntervalSince1970) {
        [self failWithError:[NSError errorWithDomain:TVRecorderOAuthErrorDomain
                                                  code:TVRecorderOAuthErrorNetwork
                                              userInfo:@{NSLocalizedDescriptionKey: @"Device code expired"}]];
        return;
    }
    NSTimeInterval untilExpire = self.expiresAt.timeIntervalSinceNow;
    NSTimeInterval minSpacing = self.pollInterval > 0 ? self.pollInterval : 5.0;
    NSTimeInterval targetDelay = self.didRunFirstPoll ? minSpacing : MAX(minSpacing, 15.0);
    NSTimeInterval delay = MAX(minSpacing, MIN(targetDelay, untilExpire - 2.0));
    __weak typeof(self) weak = self;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO
                                                       block:^(NSTimer *t) {
        [weak pollOnce];
    }];
}

- (void)pollOnce {
    if (self.cancelled) return;
    self.didRunFirstPoll = YES;
    __weak typeof(self) weak = self;
    [[TVRecorderOAuthClient shared] pollTokenWithDeviceCode:self.deviceCode
                                                 completion:^(NSDictionary *tokens, BOOL pending, BOOL slowDown,
                                                              NSError *err) {
        __strong typeof(weak) selfStrong = weak;
        if (!selfStrong || selfStrong.cancelled) return;
        if (err) {
            if (TVRecorderDeviceSignInIsTransientURLError(err) && selfStrong.transientPollFailureCount < 12) {
                selfStrong.transientPollFailureCount++;
                DDLogWarn(@"[TVRecorderDeviceSignIn] token poll transient error %@ %ld — retrying (%lu)",
                          err.domain, (long)err.code, (unsigned long)selfStrong.transientPollFailureCount);
                [selfStrong schedulePoll];
                return;
            }
            [selfStrong failWithError:err];
            return;
        }
        if (pending) {
            selfStrong.transientPollFailureCount = 0;
            if (slowDown) {
                selfStrong.pollInterval = MIN(selfStrong.pollInterval + 5.0, 60.0);
            }
            [selfStrong schedulePoll];
            return;
        }
        id atObj = tokens[@"access_token"];
        NSString *at = [atObj isKindOfClass:[NSString class]] ? (NSString *)atObj : nil;
        if (!at.length) {
            DDLogWarn(@"[TVRecorderDeviceSignIn] success path but no string access_token; keys=%@",
                      tokens.allKeys);
            [selfStrong failWithError:[NSError errorWithDomain:TVRecorderOAuthErrorDomain
                                                            code:TVRecorderOAuthErrorNetwork
                                                        userInfo:@{NSLocalizedDescriptionKey: @"No access_token"}]];
            return;
        }
        id rtObj = tokens[@"refresh_token"];
        NSString *rt = [rtObj isKindOfClass:[NSString class]] ? (NSString *)rtObj : nil;
        NSInteger expSec = 3600;
        id ei = tokens[@"expires_in"];
        if ([ei isKindOfClass:[NSNumber class]]) {
            expSec = [(NSNumber *)ei integerValue];
        } else if ([ei isKindOfClass:[NSString class]]) {
            expSec = [(NSString *)ei integerValue];
        }
        DDLogInfo(@"[TVRecorderDeviceSignIn] token response keys=%@ expires_in=%ld access_len=%lu refresh=%d",
                  tokens.allKeys, (long)expSec, (unsigned long)at.length, rt.length > 0);
        if (![TVRecorderTokenStore saveAccessToken:at refreshToken:rt expiresIn:expSec]) {
            [selfStrong failWithError:[NSError errorWithDomain:TVRecorderOAuthErrorDomain
                                                           code:TVRecorderOAuthErrorNetwork
                                                       userInfo:@{NSLocalizedDescriptionKey:
                                                                      @"Could not save sign-in to Keychain"}]];
            return;
        }
        selfStrong.transientPollFailureCount = 0;
        DDLogInfo(@"[TVRecorderDeviceSignIn] Keychain save OK");
        [selfStrong.pollTimer invalidate];
        selfStrong.pollTimer = nil;
        [selfStrong dismissViewControllerAnimated:YES completion:^{
            if (selfStrong.finish) selfStrong.finish(YES, nil);
        }];
    }];
}

- (void)failWithError:(NSError *)err {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    __weak typeof(self) weak = self;
    [self dismissViewControllerAnimated:YES completion:^{
        if (weak.finish) weak.finish(NO, err);
    }];
}

- (void)fetchCurrentUserProfileIfSignedIn {
    NSString *token = [TVRecorderTokenStore accessToken];
    if ([TVRecorderTokenStore hasUsableAccessToken] && token.length) {
        [self fetchCurrentUserProfileUsingToken:token retryOnUnauthorized:YES];
        return;
    }
    if (![TVRecorderTokenStore refreshToken].length) return;
    __weak typeof(self) weak = self;
    [[TVRecorderOAuthClient shared] refreshAccessTokenWithCompletion:^(NSString * _Nullable accessToken,
                                                                       NSError * _Nullable error) {
        if (!accessToken.length) {
            DDLogInfo(@"[TVRecorderDeviceSignIn] profile refresh skipped: %@", error.localizedDescription ?: @"unknown");
            return;
        }
        __strong typeof(weak) selfStrong = weak;
        if (!selfStrong || selfStrong.cancelled) return;
        [selfStrong fetchCurrentUserProfileUsingToken:accessToken retryOnUnauthorized:NO];
    }];
}

- (void)fetchCurrentUserProfileUsingToken:(NSString *)token retryOnUnauthorized:(BOOL)allowRetry {
    NSURL *url = TVRecorderDeviceSignInCurrentUserURL();
    if (!url) return;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    __weak typeof(self) weak = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data.length) return;
        NSHTTPURLResponse *http = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;
        if (http.statusCode == 401 && allowRetry && [TVRecorderTokenStore refreshToken].length) {
            [[TVRecorderOAuthClient shared] refreshAccessTokenWithCompletion:^(NSString * _Nullable freshToken,
                                                                               NSError * _Nullable refreshErr) {
                if (!freshToken.length) {
                    DDLogInfo(@"[TVRecorderDeviceSignIn] profile 401 refresh failed: %@",
                              refreshErr.localizedDescription ?: @"unknown");
                    return;
                }
                __strong typeof(weak) selfStrong = weak;
                if (!selfStrong || selfStrong.cancelled) return;
                [selfStrong fetchCurrentUserProfileUsingToken:freshToken retryOnUnauthorized:NO];
            }];
            return;
        }
        if (http.statusCode < 200 || http.statusCode >= 300) return;
        NSError *jsonErr = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
        if (jsonErr || ![obj isKindOfClass:[NSDictionary class]]) return;
        NSDictionary *user = (NSDictionary *)obj;
        NSString *picture = [user[@"picture"] isKindOfClass:[NSString class]] ? user[@"picture"] : nil;
        UIImage *avatar = TVRecorderDeviceSignInImageFromPictureDataURI(picture);
        NSString *displayName = [user[@"displayName"] isKindOfClass:[NSString class]] ? user[@"displayName"] : nil;
        NSString *userImagePath = [user[@"userImage"] isKindOfClass:[NSString class]] ? user[@"userImage"] : nil;

        void (^applyAvatar)(UIImage *) = ^(UIImage *img) {
            if (!img) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weak) selfStrong = weak;
                if (!selfStrong || selfStrong.cancelled) return;
                selfStrong.profileImageView.image = img;
                selfStrong.profileImageView.hidden = NO;
                selfStrong.profileNameLabel.text = displayName.length ? displayName : @"Signed in";
                selfStrong.profileNameLabel.hidden = NO;
            });
        };

        if (avatar) {
            applyAvatar(avatar);
            return;
        }

        NSURL *avatarURL = TVRecorderDeviceSignInAvatarURLForPath(userImagePath);
        if (!avatarURL) return;
        NSMutableURLRequest *imgReq = [NSMutableURLRequest requestWithURL:avatarURL];
        imgReq.HTTPMethod = @"GET";
        [imgReq setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
        [[[NSURLSession sharedSession] dataTaskWithRequest:imgReq
                                         completionHandler:^(NSData *imgData, NSURLResponse *imgResp, NSError *imgErr) {
            if (imgErr || !imgData.length) return;
            NSHTTPURLResponse *imgHTTP = [imgResp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)imgResp : nil;
            if (imgHTTP.statusCode < 200 || imgHTTP.statusCode >= 300) return;
            UIImage *remoteAvatar = [UIImage imageWithData:imgData];
            applyAvatar(remoteAvatar);
        }] resume];
    }] resume];
}

@end
