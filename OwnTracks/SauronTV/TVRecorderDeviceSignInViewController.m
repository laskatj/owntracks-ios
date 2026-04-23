//
//  TVRecorderDeviceSignInViewController.m
//  SauronTV
//

#import "TVRecorderDeviceSignInViewController.h"
#import "TVRecorderOAuthClient.h"
#import "TVRecorderTokenStore.h"
#import <CocoaLumberjack/CocoaLumberjack.h>

static const DDLogLevel ddLogLevel = DDLogLevelInfo;

@interface TVRecorderDeviceSignInViewController ()
@property (copy, nonatomic) void (^finish)(BOOL success, NSError * _Nullable err);
@property (strong, nonatomic) UILabel *titleLabel;
@property (strong, nonatomic) UILabel *instructionLabel;
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
    _instructionLabel.text = @"On your phone or computer, open the URL below and enter the code.";
    [self.view addSubview:_instructionLabel];

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
    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.topAnchor constraintEqualToAnchor:g.topAnchor constant:60],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:40],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-40],

        [_instructionLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:24],
        [_instructionLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:40],
        [_instructionLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-40],

        [_uriLabel.topAnchor constraintEqualToAnchor:_instructionLabel.bottomAnchor constant:32],
        [_uriLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:32],
        [_uriLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-32],

        [_codeLabel.topAnchor constraintEqualToAnchor:_uriLabel.bottomAnchor constant:24],
        [_codeLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],

        [_cancelButton.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-40],
        [_cancelButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    ]];

    [self startDeviceFlow];
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

- (void)startDeviceFlow {
    __weak typeof(self) weak = self;
    [[TVRecorderOAuthClient shared] requestDeviceAuthorizationWithCompletion:^(NSDictionary *json, NSError *err) {
        __strong typeof(weak) selfStrong = weak;
        if (!selfStrong || selfStrong.cancelled) return;
        if (err || !json) {
            [selfStrong failWithError:err];
            return;
        }
        NSString *dc = json[@"device_code"];
        NSString *uc = json[@"user_code"];
        NSString *vu = json[@"verification_uri"];
        NSNumber *exp = json[@"expires_in"];
        NSNumber *iv = json[@"interval"];
        if (!dc.length || !uc.length || !vu.length) {
            [selfStrong failWithError:[NSError errorWithDomain:TVRecorderOAuthErrorDomain
                                                            code:TVRecorderOAuthErrorNetwork
                                                        userInfo:@{NSLocalizedDescriptionKey: @"Bad device response"}]];
            return;
        }
        selfStrong.deviceCode = dc;
        selfStrong.uriLabel.text = vu;
        selfStrong.codeLabel.text = uc;
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
    NSTimeInterval delay = self.didRunFirstPoll ? self.pollInterval : MAX(self.pollInterval, 15.0);
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
            [selfStrong failWithError:err];
            return;
        }
        if (pending) {
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
        [TVRecorderTokenStore saveAccessToken:at refreshToken:rt expiresIn:expSec];
        DDLogInfo(@"[TVRecorderDeviceSignIn] Keychain save requested");
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

@end
