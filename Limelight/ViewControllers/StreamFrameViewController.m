//
//  StreamFrameViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/18/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "StreamFrameViewController.h"
#import "MainFrameViewController.h"
#import "VideoDecoderRenderer.h"
#import "StreamManager.h"
#import "ControllerSupport.h"
#import "DataManager.h"
#import "Connection.h"
#import "Utils.h"
#import "RelativeTouchHandler.h"

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>
#include <ifaddrs.h>
#include <net/if.h>

static NSString *const BUREAU_MUTED_KEY = @"MoonlightBureauMuted";
static NSString *const BUREAU_DATA_KEY = @"MoonlightBureauDataUsage2";
static NSString *const BUREAU_SHOW_DATA_KEY = @"MoonlightBureauShowData";

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <Limelight.h>

#if TARGET_OS_TV
#import <AVFoundation/AVDisplayCriteria.h>
#import <AVKit/AVDisplayManager.h>
#import <AVKit/UIWindow.h>
#endif

@interface AVDisplayCriteria()
@property(readonly) int videoDynamicRange;
@property(readonly, nonatomic) float refreshRate;
- (id)initWithRefreshRate:(float)arg1 videoDynamicRange:(int)arg2;
@end

#if !TARGET_OS_TV
// Moonlight Bureau: in Chrome Remote Desktop (Chromium remoting/ios/client_gestures.mm and
// client/gesture_interpreter.cc) a two-finger scroll only sends the wheel: the view never
// moves during it, and zoom and scroll exclude each other. Here the zoomed image lives in a
// UIScrollView whose own pinch and pan also moved it with the fingers; disabling them was
// not enough (UIKit turns its pinch back on when zooming is possible), the image followed
// the fingers and our re-centering on the cursor pulled it back ("bug danse"). This scroll
// view refuses its built-in gestures for good: only bureauWheel: zooms, only the cursor moves
// the view.
@interface BureauStreamScrollView : UIScrollView
@property (nonatomic) BOOL bureauNoBuiltInGestures;
@end

@implementation BureauStreamScrollView
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (self.bureauNoBuiltInGestures &&
        (gestureRecognizer == self.pinchGestureRecognizer || gestureRecognizer == self.panGestureRecognizer)) {
        return NO;
    }
    return [super gestureRecognizerShouldBegin:gestureRecognizer];
}
@end

// Direct typing, as Chrome Remote Desktop (remoting/ios/client_keyboard.mm): an invisible view
// takes the iOS keyboard and every key goes to the PC at once. No text field, no correction,
// no suggestion bar: the keyboard is as small as iOS makes it. The default keyboard type is
// kept (accents, French layout) instead of their ASCII one.
@interface BureauKeyInput : UIView <UIKeyInput>
@property (nonatomic) UITextAutocorrectionType autocorrectionType;
@property (nonatomic) UITextAutocapitalizationType autocapitalizationType;
@property (nonatomic) UITextSpellCheckingType spellCheckingType;
@property (nonatomic) UITextSmartQuotesType smartQuotesType;
@property (nonatomic) UITextSmartDashesType smartDashesType;
@property (nonatomic) UITextSmartInsertDeleteType smartInsertDeleteType;
@property (nonatomic) UIKeyboardType keyboardType;
@property (nonatomic) UIKeyboardAppearance keyboardAppearance;
@property (nonatomic, strong) UIView *bureauAccessory;
@property (nonatomic, copy) void (^onText)(NSString *text);
@property (nonatomic, copy) void (^onBackspace)(void);
@end

@implementation BureauKeyInput
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _autocorrectionType = UITextAutocorrectionTypeNo;
        _autocapitalizationType = UITextAutocapitalizationTypeNone;
        _spellCheckingType = UITextSpellCheckingTypeNo;
        _smartQuotesType = UITextSmartQuotesTypeNo;
        _smartDashesType = UITextSmartDashesTypeNo;
        _smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
        _keyboardType = UIKeyboardTypeDefault;
        _keyboardAppearance = UIKeyboardAppearanceDark;
    }
    return self;
}
- (BOOL)canBecomeFirstResponder {
    return YES;
}
// Always "has text", so the delete key always reaches the PC
- (BOOL)hasText {
    return YES;
}
- (void)insertText:(NSString *)text {
    if (self.onText != nil) {
        self.onText(text);
    }
}
- (void)deleteBackward {
    if (self.onBackspace != nil) {
        self.onBackspace();
    }
}
- (UIView *)inputAccessoryView {
    return self.bureauAccessory;
}
@end

// Paste in one go: the whole text goes to the PC's clipboard helper
// (Client - Téléphone\Presse-Papiers-Tel.ps1 on the PC, port = Sunshine HTTP port - 2), which
// answers "OK"; the app then presses Ctrl+V. Typing it key by key was slow and could mix up.
// Raw TCP with a fixed first line, so a web page cannot imitate it. Background thread only.
static int BureauHelperConnect(NSString *address, unsigned short port) {
    struct addrinfo hints = {0};
    struct addrinfo *res = NULL;
    hints.ai_socktype = SOCK_STREAM;
    char portString[8];
    snprintf(portString, sizeof(portString), "%u", port);
    if (getaddrinfo(address.UTF8String, portString, &hints, &res) != 0 || res == NULL) {
        return -1;
    }
    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) {
        freeaddrinfo(res);
        return -1;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int rc = connect(fd, res->ai_addr, res->ai_addrlen);
    freeaddrinfo(res);
    if (rc != 0 && errno != EINPROGRESS) {
        close(fd);
        return -1;
    }
    if (rc != 0) {
        fd_set writable;
        FD_ZERO(&writable);
        FD_SET(fd, &writable);
        struct timeval wait = { 2, 0 };
        int err = 0;
        socklen_t len = sizeof(err);
        if (select(fd + 1, NULL, &writable, NULL, &wait) <= 0 ||
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) != 0 || err != 0) {
            close(fd);
            return -1;
        }
    }
    fcntl(fd, F_SETFL, flags);
    struct timeval timeout = { 5, 0 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    return fd;
}

static BOOL BureauHelperSend(int fd, NSData *data) {
    const uint8_t *bytes = data.bytes;
    size_t sent = 0;
    while (sent < data.length) {
        ssize_t n = send(fd, bytes + sent, data.length - sent, 0);
        if (n <= 0) {
            return NO;
        }
        sent += (size_t)n;
    }
    return YES;
}

static BOOL BureauHelperRead(int fd, void *buffer, size_t length) {
    size_t got = 0;
    while (got < length) {
        ssize_t n = recv(fd, (uint8_t *)buffer + got, length - got, 0);
        if (n <= 0) {
            return NO;
        }
        got += (size_t)n;
    }
    return YES;
}

// iPhone -> PC: the helper sets the PC clipboard and answers "OK"
static BOOL BureauSendToPCClipboard(NSString *address, unsigned short port, NSData *data) {
    int fd = BureauHelperConnect(address, port);
    if (fd < 0) {
        return NO;
    }
    NSMutableData *message = [[[NSString stringWithFormat:@"MBCLIP1 %lu\n", (unsigned long)data.length]
                               dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [message appendData:data];
    char reply[3];
    BOOL ok = BureauHelperSend(fd, message) && BureauHelperRead(fd, reply, 3) && memcmp(reply, "OK\n", 3) == 0;
    close(fd);
    return ok;
}

// PC -> iPhone: "MBCOPY1", the helper answers "MBTEXT <bytes>" and the PC clipboard text.
// nil if the PC did not answer, @"" if its clipboard holds no text.
static NSString *BureauFetchPCClipboard(NSString *address, unsigned short port) {
    int fd = BureauHelperConnect(address, port);
    if (fd < 0) {
        return nil;
    }
    NSString *result = nil;
    if (BureauHelperSend(fd, [@"MBCOPY1\n" dataUsingEncoding:NSUTF8StringEncoding])) {
        char line[40];
        size_t used = 0;
        BOOL complete = NO;
        while (used < sizeof(line) - 1 && BureauHelperRead(fd, line + used, 1)) {
            if (line[used] == '\n') {
                complete = YES;
                break;
            }
            used++;
        }
        line[used] = 0;
        unsigned long length = 0;
        if (complete && sscanf(line, "MBTEXT %lu", &length) == 1 && length <= 4 * 1024 * 1024) {
            NSMutableData *data = [NSMutableData dataWithLength:length];
            if (length == 0 || BureauHelperRead(fd, data.mutableBytes, length)) {
                result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            }
        }
    }
    close(fd);
    return result;
}

// All keys and text leave in typing order (a concurrent queue could swap two fast keys)
static dispatch_queue_t BureauInputQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("moonlight.bureau.input", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    });
    return queue;
}
#endif

@implementation StreamFrameViewController {
    ControllerSupport *_controllerSupport;
    StreamManager *_streamMan;
    TemporarySettings *_settings;
    NSTimer *_inactivityTimer;
    NSTimer *_statsUpdateTimer;
    UITapGestureRecognizer *_menuTapGestureRecognizer;
    UITapGestureRecognizer *_menuDoubleTapGestureRecognizer;
    UITapGestureRecognizer *_playPauseTapGestureRecognizer;
    UITextView *_overlayView;
    UILabel *_stageLabel;
    UILabel *_tipLabel;
    UIActivityIndicatorView *_spinner;
    StreamView *_streamView;
    UIScrollView *_scrollView;
    BOOL _userIsInteracting;
    CGSize _keyboardSize;
    
#if !TARGET_OS_TV
    UIScreenEdgePanGestureRecognizer *_exitSwipeRecognizer;

    // Moonlight Bureau toolbar
    UIButton *_bureauHandle;
    UIVisualEffectView *_bureauBar;
    UIScrollView *_bureauKeysRow;
    UIView *_bureauDataPill;
    UILabel *_bureauDataLabel;
    CGFloat _bureauWheelStartDistance;
    CGFloat _bureauWheelStartZoom;
    CGPoint _bureauWheelTravel;
    int _bureauWheelMode; // 0 = undecided, 1 = scroll, 2 = zoom
    CADisplayLink *_bureauWheelFling;
    CGPoint _bureauWheelVelocity;   // screen points per second, after the fingers lift
    CFTimeInterval _bureauWheelLastTick;
    CGPoint _bureauWheelRemainder;  // sub-unit wheel amounts carried to the next event
    UIButton *_bureauMuteButton;
    NSTimer *_bureauDataTimer;
    NSMutableDictionary<NSString *, NSNumber *> *_bureauIfLast; // last counter per interface
    UIButton *_bureauDataButton;
    UIButton *_bureauPinButton;
    UIView *_bureauComposer;
    UITextView *_bureauTextView;
    NSLayoutConstraint *_bureauTextHeight;
    UILabel *_bureauPlaceholder;
    NSTimer *_bureauHideTimer;
    BOOL _bureauPinned;
    CGPoint _bureauCursor;
    BOOL _bureauCursorKnown;
    CGPoint _bureauZoomAnchor;
    BOOL _bureauZoomAnchored;
    BOOL _bureauInBackground;
    NSDate *_bureauForegroundAt;
    CGFloat _bureauKeyboardOverlap; // height of the desktop hidden by the keyboard (+ composer)
    BOOL _bureauKeyboardShown;
    CGRect _bureauKeyboardFrame;    // in self.view coordinates, from the keyboard notifications
    UIButton *_bureauRotationButton;
    BureauKeyInput *_bureauKeyInput;
    UIButton *_bureauFab;
    NSLayoutConstraint *_bureauFabLeft;
    NSLayoutConstraint *_bureauFabRight;
    UIView *_bureauPrivacyBlur;
    UIView *_bureauDragRing;
    UIView *_bureauKeyRow;          // thin key row above the keyboard (nil accessory when folded)
    UIButton *_bureauKeyRowButton;  // small button above the menu button, unfolds the row
#endif
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
#if !TARGET_OS_TV
    [self.navigationController setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    [self.navigationController setNeedsUpdateOfHomeIndicatorAutoHidden];
    [self.navigationController.parentViewController setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    [self.navigationController.parentViewController setNeedsUpdateOfHomeIndicatorAutoHidden];
#endif
    
#if !TARGET_OS_TV
    [[self revealViewController] setPrimaryViewController:self];
#endif
}

#if TARGET_OS_TV
- (void)controllerPauseButtonPressed:(id)sender { }
- (void)controllerPauseButtonDoublePressed:(id)sender {
    Log(LOG_I, @"Menu double-pressed -- backing out of stream");
    [self returnToMainFrame];
}
- (void)controllerPlayPauseButtonPressed:(id)sender {
    Log(LOG_I, @"Play/Pause button pressed -- backing out of stream");
    [self returnToMainFrame];
}
#endif


- (void)viewDidLoad
{
    [super viewDidLoad];
    
    [self.navigationController setNavigationBarHidden:YES animated:YES];
    
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    
    _settings = [[[DataManager alloc] init] getSettings];
    
    _stageLabel = [[UILabel alloc] init];
    [_stageLabel setUserInteractionEnabled:NO];
#if TARGET_OS_TV
    [_stageLabel setText:[NSString stringWithFormat:@"Starting %@...", self.streamConfig.appName]];
#else
    // Moonlight Bureau: same night-blue as the main screen, French text
    self.view.backgroundColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.11 alpha:1];
    [_stageLabel setText:@"Connexion au PC…"];
    _stageLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
#endif
    [_stageLabel sizeToFit];
    _stageLabel.textAlignment = NSTextAlignmentCenter;
    _stageLabel.textColor = [UIColor whiteColor];
    _stageLabel.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2);
    
    _spinner = [[UIActivityIndicatorView alloc] init];
    [_spinner setUserInteractionEnabled:NO];
#if TARGET_OS_TV
    [_spinner setActivityIndicatorViewStyle:UIActivityIndicatorViewStyleWhiteLarge];
#else
    [_spinner setActivityIndicatorViewStyle:UIActivityIndicatorViewStyleWhite];
#endif
    [_spinner sizeToFit];
    [_spinner startAnimating];
    _spinner.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2 - _stageLabel.frame.size.height - _spinner.frame.size.height);
    
    _controllerSupport = [[ControllerSupport alloc] initWithConfig:self.streamConfig delegate:self];
    _inactivityTimer = nil;
    
    _streamView = [[StreamView alloc] initWithFrame:self.view.frame];
    [_streamView setupStreamView:_controllerSupport interactionDelegate:self config:self.streamConfig];
    
#if TARGET_OS_TV
    if (!_menuTapGestureRecognizer || !_menuDoubleTapGestureRecognizer || !_playPauseTapGestureRecognizer) {
        _menuTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPauseButtonPressed:)];
        _menuTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];

        _playPauseTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPlayPauseButtonPressed:)];
        _playPauseTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypePlayPause)];
        
        _menuDoubleTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPauseButtonDoublePressed:)];
        _menuDoubleTapGestureRecognizer.numberOfTapsRequired = 2;
        [_menuTapGestureRecognizer requireGestureRecognizerToFail:_menuDoubleTapGestureRecognizer];
        _menuDoubleTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];
    }
    
    [self.view addGestureRecognizer:_menuTapGestureRecognizer];
    [self.view addGestureRecognizer:_menuDoubleTapGestureRecognizer];
    [self.view addGestureRecognizer:_playPauseTapGestureRecognizer];

#else
    _exitSwipeRecognizer = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(edgeSwiped)];
    _exitSwipeRecognizer.edges = UIRectEdgeLeft;
    _exitSwipeRecognizer.delaysTouchesBegan = NO;
    _exitSwipeRecognizer.delaysTouchesEnded = NO;
    
    // Moonlight Bureau: no left-edge swipe to disconnect (too easy to trigger by mistake);
    // disconnecting goes through the toolbar button, with a confirmation.
    // [self.view addGestureRecognizer:_exitSwipeRecognizer];
#endif
    
    _tipLabel = [[UILabel alloc] init];
    [_tipLabel setUserInteractionEnabled:NO];
    
#if TARGET_OS_TV
    [_tipLabel setText:@"Tip: Tap the Play/Pause button on the Apple TV Remote to disconnect from your PC"];
#else
    [_tipLabel setText:@"Astuce : la poignée en haut ouvre la barre, la croix rouge déconnecte"];
    _tipLabel.font = [UIFont systemFontOfSize:14];
    _tipLabel.numberOfLines = 0;
#endif
    
    [_tipLabel sizeToFit];
    _tipLabel.textColor = [UIColor whiteColor];
    _tipLabel.textAlignment = NSTextAlignmentCenter;
    _tipLabel.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height * 0.9);
    
    _streamMan = [[StreamManager alloc] initWithConfig:self.streamConfig
                                            renderView:_streamView
                                   connectionCallbacks:self];
    NSOperationQueue* opQueue = [[NSOperationQueue alloc] init];
    [opQueue addOperation:_streamMan];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(applicationDidBecomeActive:)
                                                 name: UIApplicationDidBecomeActiveNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(applicationDidEnterBackground:)
                                                 name: UIApplicationDidEnterBackgroundNotification
                                               object: nil];

#if 0
    // FIXME: This doesn't work reliably on iPad for some reason. Showing and hiding the keyboard
    // several times in a row will not correctly restore the state of the UIScrollView.
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(keyboardWillShow:)
                                                 name: UIKeyboardWillShowNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(keyboardWillHide:)
                                                 name: UIKeyboardWillHideNotification
                                               object: nil];
#endif
    
    // Scroll and zoom in absolute touch mode.
    // Moonlight Bureau: also pinch-to-zoom in trackpad mode on iOS. There, two-finger
    // dragging stays the mouse wheel (no manual pan) and the zoomed view follows the
    // cursor tracked by RelativeTouchHandler.
    if (_settings.absoluteTouchMode || !TARGET_OS_TV) {
#if !TARGET_OS_TV
        BureauStreamScrollView *bureauScroll = [[BureauStreamScrollView alloc] initWithFrame:self.view.frame];
        bureauScroll.bureauNoBuiltInGestures = !_settings.absoluteTouchMode;
        _scrollView = bureauScroll;
#else
        _scrollView = [[UIScrollView alloc] initWithFrame:self.view.frame];
#endif
#if !TARGET_OS_TV
        // Moonlight Bureau: no automatic insets for the notch / home bar. They differ between
        // portrait and landscape and shifted the image (with some play) after each rotation.
        // The only inset is ours, for the keyboard (bureauUpdateKeyboardOverlap).
        _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        _scrollView.bounces = NO;
        _scrollView.alwaysBounceVertical = NO;
        _scrollView.alwaysBounceHorizontal = NO;
        [_scrollView.panGestureRecognizer setMinimumNumberOfTouches:2];
        if (!_settings.absoluteTouchMode) {
            _scrollView.panGestureRecognizer.enabled = NO;
            // No 150 ms delay before touches reach the trackpad handler
            _scrollView.delaysContentTouches = NO;
            [_scrollView setMaximumZoomScale:5.0f];
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(trackpadCursorMoved:)
                                                         name:@"MoonlightBureauCursorMoved"
                                                       object:nil];
        }
#endif
        [_scrollView setShowsHorizontalScrollIndicator:NO];
        [_scrollView setShowsVerticalScrollIndicator:NO];
        [_scrollView setDelegate:self];
        if (_settings.absoluteTouchMode) {
            [_scrollView setMaximumZoomScale:10.0f];
        }
        
        // Add StreamView inside a UIScrollView for absolute mode
        [_scrollView addSubview:_streamView];
        [self.view addSubview:_scrollView];
    }
    else {
        // Add StreamView directly in relative mode
        [self.view addSubview:_streamView];
    }
    
    [self.view addSubview:_stageLabel];
    [self.view addSubview:_spinner];
    [self.view addSubview:_tipLabel];

#if !TARGET_OS_TV
    for (UIView *v in @[_stageLabel, _spinner, _tipLabel]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
    }
    _stageLabel.numberOfLines = 0;
    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_spinner.centerXAnchor constraintEqualToAnchor:safeArea.centerXAnchor],
        [_spinner.bottomAnchor constraintEqualToAnchor:_stageLabel.topAnchor constant:-14],
        [_stageLabel.centerXAnchor constraintEqualToAnchor:safeArea.centerXAnchor],
        [_stageLabel.centerYAnchor constraintEqualToAnchor:safeArea.centerYAnchor],
        [_stageLabel.widthAnchor constraintLessThanOrEqualToAnchor:safeArea.widthAnchor constant:-48],
        [_tipLabel.centerXAnchor constraintEqualToAnchor:safeArea.centerXAnchor],
        [_tipLabel.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-24],
        [_tipLabel.widthAnchor constraintLessThanOrEqualToAnchor:safeArea.widthAnchor constant:-48],
    ]];
    _tipLabel.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    [self setupBureauToolbar];
#endif
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return _streamView;
}

#if !TARGET_OS_TV
// Moonlight Bureau: viewport behaviour of Chrome Remote Desktop's trackpad mode
// (Chromium remoting/client/input/trackpad_input_strategy.cc, ui/desktop_viewport.cc):
// - the view is kept centered on the cursor, so the image moves under a still cursor;
// - the center is clamped to the desktop: at an edge the image stops and the cursor
//   moves on to the edge;
// - pinch-zoom uses the cursor as pivot, then re-centers on it.
// Finger movement is already divided by the zoom (StreamView points), as in CRD.
- (void)bureauCenterOnCursor {
    if (_scrollView == nil || !_bureauCursorKnown) {
        return;
    }
    // Unzoomed and no keyboard: the whole desktop is on screen, nothing to follow
    if (_scrollView.zoomScale <= 1.01f && _bureauKeyboardOverlap <= 0) {
        if (_scrollView.contentOffset.x != 0 || _scrollView.contentOffset.y != 0) {
            [_scrollView setContentOffset:CGPointZero animated:NO];
        }
        return;
    }
    CGPoint p = [_streamView convertPoint:_bureauCursor toView:_scrollView];
    if (_scrollView.zoomScale <= 1.01f) {
        // Keyboard up, not zoomed: the desktop stays still and only slides up when the
        // cursor would go under the keyboard, just enough to keep it in sight (and back down
        // when it comes back up). Centering on it made the whole image follow every move.
        CGFloat visibleHeight = MAX(_scrollView.bounds.size.height - _bureauKeyboardOverlap, 1);
        CGFloat margin = MIN(48, visibleHeight / 4);
        CGFloat y = _scrollView.contentOffset.y;
        if (p.y - y > visibleHeight - margin) {
            y = p.y - visibleHeight + margin;
        }
        if (p.y - y < margin) {
            y = p.y - margin;
        }
        y = MIN(MAX(y, 0), _bureauKeyboardOverlap);
        if (_scrollView.contentOffset.x != 0 || fabs(y - _scrollView.contentOffset.y) > 0.5) {
            [_scrollView setContentOffset:CGPointMake(0, y) animated:NO];
        }
        return;
    }
    CGSize visible = _scrollView.bounds.size;
    // With the keyboard up, only the part above it is visible: the desktop slides up
    // with the cursor (like Chrome Remote Desktop) and can go up to the keyboard's height
    visible.height = MAX(visible.height - _bureauKeyboardOverlap, 1);
    CGFloat x = MIN(MAX(p.x - visible.width / 2, 0), MAX(_scrollView.contentSize.width - visible.width, 0));
    CGFloat y = MIN(MAX(p.y - visible.height / 2, 0), MAX(_scrollView.contentSize.height - visible.height, 0));
    if (x != _scrollView.contentOffset.x || y != _scrollView.contentOffset.y) {
        [_scrollView setContentOffset:CGPointMake(x, y) animated:NO];
    }
}

- (void)scrollViewWillBeginZooming:(UIScrollView *)scrollView withView:(UIView *)view {
    _bureauZoomAnchored = (scrollView == _scrollView && !_settings.absoluteTouchMode && _bureauCursorKnown);
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    if (scrollView == _scrollView && _bureauZoomAnchored) {
        [self bureauCenterOnCursor];
    }
}

- (void)scrollViewDidEndZooming:(UIScrollView *)scrollView withView:(UIView *)view atScale:(CGFloat)scale {
    if (_bureauZoomAnchored) {
        [self bureauCenterOnCursor];
    }
    _bureauZoomAnchored = NO;
}

- (void)trackpadCursorMoved:(NSNotification *)notification {
    _bureauCursor = [[notification.userInfo objectForKey:@"point"] CGPointValue];
    _bureauCursorKnown = YES;
    // As in Chrome Remote Desktop, the view stays still while two fingers scroll
    if (_bureauWheelMode != 1) {
        [self bureauCenterOnCursor];
    }
    [self bureauPlaceDragRing];
}
#endif

- (void)willMoveToParentViewController:(UIViewController *)parent {
    // Only cleanup when we're being destroyed
    if (parent == nil) {
#if !TARGET_OS_TV
        [_bureauDataTimer invalidate];
        _bureauDataTimer = nil;
        [self bureauStopWheelFling];
        [self bureauFlushDataUsage];
#endif
        [_controllerSupport cleanup];
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        [_streamMan stopStream];
        if (_inactivityTimer != nil) {
            [_inactivityTimer invalidate];
            _inactivityTimer = nil;
        }
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }
}

#if 0
- (void)keyboardWillShow:(NSNotification *)notification {
    _keyboardSize = [[[notification userInfo] objectForKey:UIKeyboardFrameBeginUserInfoKey] CGRectValue].size;

    [UIView animateWithDuration:0.3 animations:^{
        CGRect frame = self->_scrollView.frame;
        frame.size.height -= self->_keyboardSize.height;
        self->_scrollView.frame = frame;
    }];
}

-(void)keyboardWillHide:(NSNotification *)notification {
    // NOTE: UIKeyboardFrameEndUserInfoKey returns a different keyboard size
    // than UIKeyboardFrameBeginUserInfoKey, so it's unsuitable for use here
    // to undo the changes made by keyboardWillShow.
    
    [UIView animateWithDuration:0.3 animations:^{
        CGRect frame = self->_scrollView.frame;
        frame.size.height += self->_keyboardSize.height;
        self->_scrollView.frame = frame;
    }];
}
#endif

- (void)updateStatsOverlay {
    NSString* overlayText = [self->_streamMan getStatsOverlayText];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateOverlayText:overlayText];
    });
}

- (void)updateOverlayText:(NSString*)text {
    if (_overlayView == nil) {
        _overlayView = [[UITextView alloc] init];
#if !TARGET_OS_TV
        [_overlayView setEditable:NO];
#endif
        [_overlayView setUserInteractionEnabled:NO];
        [_overlayView setSelectable:NO];
        [_overlayView setScrollEnabled:NO];
        
        // HACK: If not using stats overlay, center the text
        if (_statsUpdateTimer == nil) {
            [_overlayView setTextAlignment:NSTextAlignmentCenter];
        }
        
        [_overlayView setTextColor:[UIColor lightGrayColor]];
        [_overlayView setBackgroundColor:[UIColor blackColor]];
#if TARGET_OS_TV
        [_overlayView setFont:[UIFont systemFontOfSize:24]];
#else
        [_overlayView setFont:[UIFont systemFontOfSize:12]];
#endif
        [_overlayView setAlpha:0.5];
        [self.view addSubview:_overlayView];
    }
    
    if (text != nil) {
        // We set our bounds to the maximum width in order to work around a bug where
        // sizeToFit interacts badly with the UITextView's line breaks, causing the
        // width to get smaller and smaller each time as more line breaks are inserted.
        [_overlayView setBounds:CGRectMake(self.view.frame.origin.x,
                                           _overlayView.frame.origin.y,
                                           self.view.frame.size.width,
                                           _overlayView.frame.size.height)];
        [_overlayView setText:text];
        [_overlayView sizeToFit];
        [_overlayView setCenter:CGPointMake(self.view.frame.size.width / 2, _overlayView.frame.size.height / 2)];
        [_overlayView setHidden:NO];
    }
    else {
        [_overlayView setHidden:YES];
    }
}

- (void) returnToMainFrame {
    // Reset display mode back to default
    [self updatePreferredDisplayMode:NO];
    
    [_statsUpdateTimer invalidate];
    _statsUpdateTimer = nil;
    
    [self.navigationController popToRootViewControllerAnimated:YES];
}

// This will fire if the user opens control center or gets a low battery message
- (void)applicationWillResignActive:(NSNotification *)notification {
    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
    }
    
#if !TARGET_OS_TV
    // Moonlight Bureau: the session stays open while inactive or in the background
    // (see applicationDidEnterBackground:), no 60-second limit
    [self bureauShowPrivacyBlur];
    if (YES) {
        return;
    }
    // Terminate the stream if the app is inactive for 60 seconds
    Log(LOG_I, @"Starting inactivity termination timer");
    _inactivityTimer = [NSTimer scheduledTimerWithTimeInterval:60
                                                      target:self
                                                    selector:@selector(inactiveTimerExpired:)
                                                    userInfo:nil
                                                     repeats:NO];
#endif
}

- (void)inactiveTimerExpired:(NSTimer*)timer {
    Log(LOG_I, @"Terminating stream after inactivity");

    [self returnToMainFrame];
    
    _inactivityTimer = nil;
}

#if !TARGET_OS_TV
- (void)bureauBackgroundExpired {
    Log(LOG_I, @"Moonlight Bureau: 30 minutes in the background, closing the session");
    _inactivityTimer = nil;
    [MainFrameViewController bureauRequestResume]; // coming back later still reconnects
    [self returnToMainFrame];
}
#endif

- (void)applicationDidBecomeActive:(NSNotification *)notification {
#if !TARGET_OS_TV
    [self bureauHidePrivacyBlur];
    if (_bureauInBackground) {
        _bureauInBackground = NO;
        _bureauForegroundAt = [NSDate date];
        [MainFrameViewController bureauCancelResume];
        // Fresh display layer and full picture right away (VideoDecoderRenderer)
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MoonlightBureauVideoReset" object:nil];
        LiRequestIdrFrame();
        // Someone may have moved the mouse on the PC meanwhile
        [self bureauSyncCursorSoon];
    }
#endif
    // Stop the background timer, since we're foregrounded again
    if (_inactivityTimer != nil) {
        Log(LOG_I, @"Stopping inactivity timer after becoming active again");
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }
}

// This fires when the home button is pressed
- (void)applicationDidEnterBackground:(UIApplication *)application {
#if !TARGET_OS_TV
    // Moonlight Bureau: the stream stays connected in the background (UIBackgroundModes
    // audio: iOS keeps an app running while it plays sound; the PC's sound, or silence
    // when muted, keeps playing). Back in the app, the PC screen is still there.
    // After 30 minutes in the background the session is closed to save data and battery;
    // coming back then reconnects automatically. If iOS stops the app anyway (call,
    // another app taking the audio), the reconnection also happens on return.
    Log(LOG_I, @"Moonlight Bureau: staying connected in the background");
    _bureauInBackground = YES;
    [MainFrameViewController bureauRequestResume];
    [_inactivityTimer invalidate];
    _inactivityTimer = [NSTimer scheduledTimerWithTimeInterval:30 * 60
                                                        target:self
                                                      selector:@selector(bureauBackgroundExpired)
                                                      userInfo:nil
                                                       repeats:NO];
    if (YES) {
        return;
    }
#endif
    Log(LOG_I, @"Terminating stream immediately for backgrounding");

    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }

#if !TARGET_OS_TV
    // Moonlight Bureau: coming back to the app reconnects to the PC session
    [MainFrameViewController bureauRequestResume];
#endif
    [self returnToMainFrame];
}

- (void)edgeSwiped {
    Log(LOG_I, @"User swiped to end stream");
    
    [self returnToMainFrame];
}

- (void) connectionStarted {
    Log(LOG_I, @"Connection started");
    dispatch_async(dispatch_get_main_queue(), ^{
        // Leave the spinner spinning until it's obscured by
        // the first frame of video.
        self->_stageLabel.hidden = YES;
        self->_tipLabel.hidden = YES;
#if !TARGET_OS_TV
        [self bureauSyncCursorSoon];
        [MainFrameViewController bureauUpdateQuitShortcut:YES];
        if ([MainFrameViewController bureauSessionInDataMode]) {
            [self bureauShowToast:@"Mode données : image à 60 i/s, consommation réduite"];
        }
#endif

        [self->_streamView showOnScreenControls];
        
        [self->_controllerSupport connectionEstablished];
        
        if (self->_settings.statsOverlay) {
            self->_statsUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0f
                                                                       target:self
                                                                     selector:@selector(updateStatsOverlay)
                                                                     userInfo:nil
                                                                      repeats:YES];
        }
    });
}

- (void)connectionTerminated:(int)errorCode {
    Log(LOG_I, @"Connection terminated: %d", errorCode);
    
    unsigned int portFlags = LiGetPortFlagsFromTerminationErrorCode(errorCode);
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portFlags);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;

#if !TARGET_OS_TV
        BOOL justBack = self->_bureauForegroundAt != nil && -[self->_bureauForegroundAt timeIntervalSinceNow] < 20;
        if (errorCode != ML_ERROR_GRACEFUL_TERMINATION && (self->_bureauInBackground || justBack)) {
            Log(LOG_I, @"Moonlight Bureau: connection lost while away, reconnecting");
            [MainFrameViewController bureauRequestResume];
            [self returnToMainFrame];
            return;
        }
#endif
        
        NSString* title;
        NSString* message;
        
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            title = @"Erreur de connexion";
            message = @"Le réseau du téléphone bloque Moonlight : la session risque de ne pas marcher sur ce réseau.";
        }
        else {
            switch (errorCode) {
                case ML_ERROR_GRACEFUL_TERMINATION:
                    [self returnToMainFrame];
                    return;
                    
                case ML_ERROR_NO_VIDEO_TRAFFIC:
                    title = @"Erreur de connexion";
                    message = @"Aucune image reçue du PC.";
                    if (portFlags != 0) {
                        char failingPorts[256];
                        LiStringifyPortFlags(portFlags, "\n", failingPorts, sizeof(failingPorts));
                        message = [message stringByAppendingString:[NSString stringWithFormat:@"\n\nPorts à vérifier (pare-feu, Tailscale) :\n%s", failingPorts]];
                    }
                    break;
                    
                case ML_ERROR_NO_VIDEO_FRAME:
                    title = @"Erreur de connexion";
                    message = @"La connexion est trop faible. Baisser le débit dans les réglages ou changer de réseau.";
                    break;
                    
                case ML_ERROR_UNEXPECTED_EARLY_TERMINATION:
                case ML_ERROR_PROTECTED_CONTENT:
                    title = @"Erreur de connexion";
                    message = @"Le PC n'a pas pu démarrer la session. Fermer un contenu protégé (DRM) ouvert sur le PC, ou redémarrer le PC.";
                    break;
                    
                case ML_ERROR_FRAME_CONVERSION:
                    title = @"Erreur de connexion";
                    message = @"Le PC n'arrive plus à encoder l'image. Essayer une autre définition ou désactiver le HDR.";
                    break;
                    
                default:
                {
                    NSString* errorString;
                    if (abs(errorCode) > 1000) {
                        // We'll assume large errors are hex values
                        errorString = [NSString stringWithFormat:@"%08X", (uint32_t)errorCode];
                    }
                    else {
                        // Smaller values will just be printed as decimal (probably errno.h values)
                        errorString = [NSString stringWithFormat:@"%d", errorCode];
                    }
                    
                    title = @"Connexion interrompue";
                    message = [NSString stringWithFormat: @"La connexion a été coupée.\n\nCode d'erreur : %@", errorString];
                    break;
                }
            }
        }
        
        UIAlertController* conTermAlert = [UIAlertController alertControllerWithTitle:title
                                                                              message:message
                                                                       preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:conTermAlert];
        [conTermAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:conTermAlert animated:YES completion:nil];
    });

    [_streamMan stopStream];
}

- (void) stageStarting:(const char*)stageName {
    Log(LOG_I, @"Starting %s", stageName);
    dispatch_async(dispatch_get_main_queue(), ^{
#if TARGET_OS_TV
        NSString* lowerCase = [NSString stringWithFormat:@"%s in progress...", stageName];
        NSString* titleCase = [[[lowerCase substringToIndex:1] uppercaseString] stringByAppendingString:[lowerCase substringFromIndex:1]];
        [self->_stageLabel setText:titleCase];
        [self->_stageLabel sizeToFit];
        self->_stageLabel.center = CGPointMake(self.view.frame.size.width / 2, self->_stageLabel.center.y);
#endif
    });
}

- (void) stageComplete:(const char*)stageName {
}

- (void) stageFailed:(const char*)stageName withError:(int)errorCode portTestFlags:(int)portTestFlags {
    Log(LOG_I, @"Stage %s failed: %d", stageName, errorCode);
    
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portTestFlags);

    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        NSString* message = [NSString stringWithFormat:@"%s failed with error %d", stageName, errorCode];
        if (portTestFlags != 0) {
            char failingPorts[256];
            LiStringifyPortFlags(portTestFlags, "\n", failingPorts, sizeof(failingPorts));
            message = [message stringByAppendingString:[NSString stringWithFormat:@"\n\nPorts à vérifier (pare-feu, Tailscale) :\n%s", failingPorts]];
        }
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            message = [message stringByAppendingString:@"\n\nLe réseau du téléphone bloque Moonlight : la session risque de ne pas marcher sur ce réseau."];
        }
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Connexion impossible"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
    
    [_streamMan stopStream];
}

- (void) launchFailed:(NSString*)message {
    Log(LOG_I, @"Launch failed: %@", message);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Erreur de connexion"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor {
    Log(LOG_I, @"Rumble on gamepad %d: %04x %04x", controllerNumber, lowFreqMotor, highFreqMotor);
    
    [_controllerSupport rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
}

- (void) rumbleTriggers:(uint16_t)controllerNumber leftTrigger:(uint16_t)leftTrigger rightTrigger:(uint16_t)rightTrigger {
    Log(LOG_I, @"Trigger rumble on gamepad %d: %04x %04x", controllerNumber, leftTrigger, rightTrigger);
    
    [_controllerSupport rumbleTriggers:controllerNumber leftTrigger:leftTrigger rightTrigger:rightTrigger];
}

- (void) setMotionEventState:(uint16_t)controllerNumber motionType:(uint8_t)motionType reportRateHz:(uint16_t)reportRateHz {
    Log(LOG_I, @"Set motion state on gamepad %d: %02x %u Hz", controllerNumber, motionType, reportRateHz);
    
    [_controllerSupport setMotionEventState:controllerNumber motionType:motionType reportRateHz:reportRateHz];
}

- (void) setControllerLed:(uint16_t)controllerNumber r:(uint8_t)r g:(uint8_t)g b:(uint8_t)b {
    Log(LOG_I, @"Set controller LED on gamepad %d: l%02x%02x%02x", controllerNumber, r, g, b);
    
    [_controllerSupport setControllerLed:controllerNumber r:r g:g b:b];
}

- (void)connectionStatusUpdate:(int)status {
    Log(LOG_W, @"Connection status update: %d", status);

    // The stats overlay takes precedence over these warnings
    if (_statsUpdateTimer != nil) {
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        switch (status) {
            case CONN_STATUS_OKAY:
                [self updateOverlayText:nil];
                break;
                
            case CONN_STATUS_POOR:
                if (self->_streamConfig.bitRate > 5000) {
                    [self updateOverlayText:@"Slow connection to PC\nReduce your bitrate"];
                }
                else {
                    [self updateOverlayText:@"Poor connection to PC"];
                }
                break;
        }
    });
}

- (void) updatePreferredDisplayMode:(BOOL)streamActive {
#if TARGET_OS_TV
    if (@available(tvOS 11.2, *)) {
        UIWindow* window = [[[UIApplication sharedApplication] delegate] window];
        AVDisplayManager* displayManager = [window avDisplayManager];
        
        // This logic comes from Kodi and MrMC
        if (streamActive) {
            int dynamicRange;
            
            if (LiGetCurrentHostDisplayHdrMode()) {
                dynamicRange = 2; // HDR10
            }
            else {
                dynamicRange = 0; // SDR
            }
            
            AVDisplayCriteria* displayCriteria = [[AVDisplayCriteria alloc] initWithRefreshRate:[_settings.framerate floatValue]
                                                                              videoDynamicRange:dynamicRange];
            displayManager.preferredDisplayCriteria = displayCriteria;
        }
        else {
            // Switch back to the default display mode
            displayManager.preferredDisplayCriteria = nil;
        }
    }
#endif
}

- (void) setHdrMode:(bool)enabled {
    Log(LOG_I, @"HDR is now: %s", enabled ? "active" : "inactive");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updatePreferredDisplayMode:YES];
    });
}

- (void) videoContentShown {
    [_spinner stopAnimating];
    [self.view setBackgroundColor:[UIColor blackColor]];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)gamepadPresenceChanged {
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)mousePresenceChanged {
#if !TARGET_OS_TV
    if (@available(iOS 14.0, *)) {
        [self setNeedsUpdateOfPrefersPointerLocked];
    }
#endif
}

- (void) streamExitRequested {
    Log(LOG_I, @"Gamepad combo requested stream exit");
    
    [self returnToMainFrame];
}

- (void)userInteractionBegan {
    // Disable hiding home bar when user is interacting.
    // iOS will force it to be shown anyway, but it will
    // also discard our edges deferring system gestures unless
    // we willingly give up home bar hiding preference.
    _userIsInteracting = YES;
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)userInteractionEnded {
    // Enable home bar hiding again if conditions allow
    _userIsInteracting = NO;
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

#if !TARGET_OS_TV
// Require a confirmation when streaming to activate a system gesture
// All edges: a swipe from an edge (home at the bottom, notifications at the top) first goes to
// the PC as a mouse move; the system gesture needs a second swipe. Moonlight Bureau: this only
// works since the navigation and reveal controllers forward it to this screen (end of file).
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return UIRectEdgeAll;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    if ([_controllerSupport getConnectedGamepadCount] > 0 &&
        [_streamView getCurrentOscState] == OnScreenControlsLevelOff &&
        _userIsInteracting == NO) {
        // Autohide the home bar when a gamepad is connected
        // and the on-screen controls are disabled. We can't
        // do this all the time because any touch on the display
        // will cause the home indicator to reappear, and our
        // preferredScreenEdgesDeferringSystemGestures will also
        // be suppressed (leading to possible errant exits of the
        // stream).
        return YES;
    }
    
    return NO;
}

- (BOOL)shouldAutorotate {
    return YES;
}

// Moonlight Bureau: the stream follows the phone (portrait or landscape, like Chrome Remote
// Desktop), or stays locked in the orientation chosen with the toolbar's lock button.
static NSString *const BUREAU_ORIENTATION_LOCK_KEY = @"MoonlightBureauOrientationLock";

- (UIInterfaceOrientationMask)bureauOrientationLock {
    return (UIInterfaceOrientationMask)[[NSUserDefaults standardUserDefaults] integerForKey:BUREAU_ORIENTATION_LOCK_KEY];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    UIInterfaceOrientationMask lock = [self bureauOrientationLock];
    return lock != 0 ? lock : UIInterfaceOrientationMaskAllButUpsideDown;
}

- (void)bureauApplyOrientationLock {
    UIInterfaceOrientationMask lock = [self bureauOrientationLock];
    [self bureauSetIcon:_bureauRotationButton symbol:(lock != 0 ? @"lock.rotation" : @"lock.rotation.open")
                   tint:(lock != 0 ? UIColor.systemYellowColor : UIColor.whiteColor)];
    if (@available(iOS 16.0, *)) {
        [self setNeedsUpdateOfSupportedInterfaceOrientations];
        [self.navigationController setNeedsUpdateOfSupportedInterfaceOrientations];
        if (lock != 0) {
            UIWindowSceneGeometryPreferencesIOS *prefs = [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:lock];
            [self.view.window.windowScene requestGeometryUpdateWithPreferences:prefs errorHandler:nil];
        }
    }
}

// Lock in the current orientation, or unlock
- (void)bureauToggleOrientationLock {
    UIInterfaceOrientationMask lock = 0;
    if ([self bureauOrientationLock] == 0) {
        UIInterfaceOrientation current = self.view.window.windowScene.interfaceOrientation;
        lock = UIInterfaceOrientationIsPortrait(current) ? UIInterfaceOrientationMaskPortrait : UIInterfaceOrientationMaskLandscape;
    }
    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)lock forKey:BUREAU_ORIENTATION_LOCK_KEY];
    [self bureauApplyOrientationLock];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [_scrollView setZoomScale:1.0 animated:NO];
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        [self bureauFitStreamView];
    }];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self bureauFitStreamView];
    [self bureauUpdateKeyboardOverlap];
}

- (void)bureauKeyboardChanged:(NSNotification *)notification {
    [self bureauUpdateKeyRowButton];
    CGRect screenFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    UIScreen *screen = self.view.window.screen ?: UIScreen.mainScreen;
    CGRect frame = [self.view convertRect:screenFrame fromCoordinateSpace:screen.coordinateSpace];
    // Shown = on screen with a real height (an undocked/floating or hidden keyboard does not count)
    _bureauKeyboardShown = frame.size.height > 60 && CGRectGetMinY(frame) < self.view.bounds.size.height - 1
                           && CGRectGetMaxY(frame) >= self.view.bounds.size.height - 1;
    _bureauKeyboardFrame = frame;
    [self bureauWithKeyboardAnimation:notification changes:^{
        [self bureauUpdateKeyboardOverlap];
    }];
}

// As Chrome Remote Desktop (host_view_controller.mm), the desktop slides with the keyboard
// itself: same duration and curve, instead of jumping once the keyboard is in place
- (void)bureauWithKeyboardAnimation:(NSNotification *)notification changes:(void (^)(void))changes {
    double duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    NSInteger curve = [notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    if (duration <= 0) {
        changes();
        return;
    }
    [UIView animateWithDuration:duration
                          delay:0
                        options:((UIViewAnimationOptions)curve << 16) | UIViewAnimationOptionBeginFromCurrentState
                     animations:changes
                     completion:nil];
}

- (void)bureauKeyboardHidden:(NSNotification *)notification {
    [self bureauUpdateKeyRowButton];
    _bureauKeyboardShown = NO;
    [self bureauWithKeyboardAnimation:notification changes:^{
        [self bureauUpdateKeyboardOverlap];
    }];
}

// Part of the screen covered by the iOS keyboard and, when shown, the composer above it
- (void)bureauUpdateKeyboardOverlap {
    if (_scrollView == nil || _settings.absoluteTouchMode) {
        return;
    }
    CGFloat overlap = 0;
    if (_bureauKeyboardShown) {
        CGFloat top = CGRectGetMinY(_bureauKeyboardFrame);
        if (_bureauComposer != nil && !_bureauComposer.hidden) {
            top = MIN(top, _bureauComposer.frame.origin.y);
        }
        overlap = MAX(0, CGRectGetMaxY([_scrollView convertRect:_scrollView.bounds toView:self.view]) - top);
    }
    if (fabs(overlap - _bureauKeyboardOverlap) < 0.5) {
        return;
    }
    _bureauKeyboardOverlap = overlap;
    UIEdgeInsets insets = _scrollView.contentInset;
    insets.bottom = overlap;
    _scrollView.contentInset = insets;
    [self bureauCenterOnCursor];
}

// Stream view = whole screen at zoom 1 (the scroll view was sized once at creation)
- (void)bureauFitStreamView {
    if (_scrollView == nil) {
        _streamView.frame = self.view.bounds;
        return;
    }
    if (!CGRectEqualToRect(_scrollView.frame, self.view.bounds)) {
        _scrollView.frame = self.view.bounds;
    }
    CGSize size = _scrollView.bounds.size;
    if (_scrollView.zoomScale <= 1.001f &&
        (!CGSizeEqualToSize(_streamView.frame.size, size) || !CGSizeEqualToSize(_scrollView.contentSize, size))) {
        // New size (rotation): whole desktop on screen, no leftover offset from the other
        // orientation, then follow the cursor again if the keyboard covers part of it
        _streamView.frame = CGRectMake(0, 0, size.width, size.height);
        _scrollView.contentSize = size;
        _scrollView.contentOffset = CGPointZero;
        [_streamView setNeedsLayout];
        [self bureauCenterOnCursor];
    }
}

- (BOOL)prefersPointerLocked {
    // Pointer lock breaks the UIKit mouse APIs, which is a problem because
    // GCMouse is horribly broken on iOS 14.0 for certain mice. Only lock
    // the cursor if there is a GCMouse present.
    return [GCMouse mice].count > 0;
}
#endif

#if !TARGET_OS_TV
#pragma mark - Moonlight Bureau toolbar
// Translucent toolbar in the spirit of Chrome Remote Desktop: a small handle at the top
// shows/hides it, it hides itself after a few seconds unless pinned. It gives a text
// composer above the iOS keyboard (accents, dictation and autocorrect are composed on the
// phone and sent as Unicode, so the PC keyboard layout and dead keys don't matter), common
// keys and shortcuts, paste from the iPhone, zoom reset and disconnect.

static const short BUREAU_VK_BACK = 0x08, BUREAU_VK_TAB = 0x09, BUREAU_VK_RETURN = 0x0D,
                   BUREAU_VK_ESCAPE = 0x1B, BUREAU_VK_LEFT = 0x25, BUREAU_VK_UP = 0x26,
                   BUREAU_VK_RIGHT = 0x27, BUREAU_VK_DOWN = 0x28, BUREAU_VK_DELETE = 0x2E,
                   BUREAU_VK_LWIN = 0x5B, BUREAU_VK_LSHIFT = 0xA0, BUREAU_VK_LCONTROL = 0xA2,
                   BUREAU_VK_LMENU = 0xA4, BUREAU_VK_V = 0x56, BUREAU_VK_C = 0x43;
static NSString *const BUREAU_KEYROW_FOLDED_KEY = @"MoonlightBureauKeyRowFolded";

- (UIButton *)bureauButtonWithSymbol:(NSString *)symbol title:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    if (symbol != nil) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium];
        [button setImage:[UIImage systemImageNamed:symbol withConfiguration:config] forState:UIControlStateNormal];
    }
    if (title != nil && symbol == nil) {
        [button setTitle:title forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    }
    button.accessibilityLabel = title;
    button.tintColor = UIColor.whiteColor;
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 10);
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:40].active = YES;
    [button.widthAnchor constraintGreaterThanOrEqualToConstant:40].active = YES;
    return button;
}

- (void)setupBureauToolbar {
    // Like Chrome Remote Desktop (remoting/ios/app/host_view_controller.mm): one small round
    // button in a bottom corner, which rides above the keyboard; everything else is in its menu,
    // so almost nothing covers the PC screen. Side (left/right) chosen in the menu, remembered.
    _bureauFab = [UIButton buttonWithType:UIButtonTypeSystem];
    _bureauFab.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *fabConfig = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
    [_bureauFab setImage:[UIImage systemImageNamed:@"ellipsis" withConfiguration:fabConfig] forState:UIControlStateNormal];
    _bureauFab.tintColor = UIColor.whiteColor;
    _bureauFab.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.55];
    _bureauFab.layer.cornerRadius = 22;
    _bureauFab.layer.borderWidth = 0.5;
    _bureauFab.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    _bureauFab.accessibilityLabel = @"Menu";
    __weak typeof(self) weakSelf = self;
    // Built at each opening, so every title says the current state
    _bureauFab.menu = [UIMenu menuWithChildren:@[[UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        StreamFrameViewController *strongSelf = weakSelf;
        completion(strongSelf != nil ? [strongSelf bureauMenuElements] : @[]);
    }]]];
    _bureauFab.showsMenuAsPrimaryAction = YES;
    if (@available(iOS 16.0, *)) {
        _bureauFab.preferredMenuElementOrder = UIContextMenuConfigurationElementOrderFixed;
    }
    [self.view addSubview:_bureauFab];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    _bureauFabLeft = [_bureauFab.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12];
    _bureauFabRight = [_bureauFab.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12];
    [NSLayoutConstraint activateConstraints:@[
        [_bureauFab.widthAnchor constraintEqualToConstant:44],
        [_bureauFab.heightAnchor constraintEqualToConstant:44],
        // Above the keyboard (and its key row) when it is open, else above the home bar
        [_bureauFab.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-12],
    ]];
    [self bureauPlaceFab];

    [self setupBureauKeyInput];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(bureauToggleKeyboard)
                                                 name:@"MoonlightBureauToggleKeyboard" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(bureauDragStarted)
                                                 name:@"MoonlightBureauDragStarted" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(bureauDragEnded)
                                                 name:@"MoonlightBureauDragEnded" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(bureauNetworkCostChanged)
                                                 name:@"MoonlightBureauNetworkCostChanged" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(bureauStopForQuit)
                                                 name:@"MoonlightBureauStopStreamForQuit" object:nil];

    // Phone-side mute, remembered between sessions
    BureauSetAudioMuted([[NSUserDefaults standardUserDefaults] boolForKey:BUREAU_MUTED_KEY]);
    [self bureauRefreshMuteTile];

    // Data counter: first reading = starting point, then saved every 15 s and at the end
    [self bureauFlushDataUsage];
    _bureauDataTimer = [NSTimer scheduledTimerWithTimeInterval:15 target:self selector:@selector(bureauFlushDataUsage) userInfo:nil repeats:YES];

    // Two-finger drag = mouse wheel (vertical and horizontal), measured on screen
    UIPanGestureRecognizer *wheel = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(bureauWheel:)];
    wheel.minimumNumberOfTouches = 2;
    wheel.maximumNumberOfTouches = 2;
    wheel.cancelsTouchesInView = NO;
    wheel.delaysTouchesBegan = NO;
    wheel.delaysTouchesEnded = NO;
    wheel.delegate = (id<UIGestureRecognizerDelegate>)self;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(bureauTouchBegan:)
                                                 name:@"MoonlightBureauTouchBegan" object:nil];
    // Keyboard position from iOS's own notifications (Apple: UIKeyboardWillChangeFrame /
    // UIKeyboardWillHide). keyboardLayoutGuide kept a height without any keyboard (home bar,
    // notch), so the desktop moved up with an empty strip and followed the mouse.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(bureauKeyboardChanged:)
                                                 name:UIKeyboardWillChangeFrameNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(bureauKeyboardHidden:)
                                                 name:UIKeyboardWillHideNotification object:nil];
    if (!_settings.absoluteTouchMode) {
        // A UIView created in code accepts a single finger by default (multipleTouchEnabled = NO):
        // the second finger never reached the stream view, so neither this wheel nor the old
        // two-finger scroll could work. The recognizer sits on the scroll view (multi-touch).
        _streamView.multipleTouchEnabled = YES;
        _scrollView.multipleTouchEnabled = YES;
        // The scroll view's own pinch started on any two-finger move and dragged / rubber-banded
        // the whole image while scrolling. Zoom is done by bureauWheel: instead, only when the
        // fingers clearly spread apart or come together, pivoting on the cursor.
        _scrollView.pinchGestureRecognizer.enabled = NO;
        _scrollView.bouncesZoom = NO;
        [(_scrollView ?: _streamView) addGestureRecognizer:wheel];
    }

    [self setupBureauComposer];
    [self bureauApplyOrientationLock];
}

- (UIButton *)bureauDisconnectButton {
    UIButton *button = [self bureauButtonWithSymbol:@"xmark.circle.fill" title:@"Déconnecter" action:@selector(bureauDisconnect)];
    button.tintColor = UIColor.systemRedColor;
    return button;
}

- (void)bureauSetIcon:(UIButton *)button symbol:(NSString *)symbol tint:(UIColor *)tint {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:config] forState:UIControlStateNormal];
    button.tintColor = tint;
}

#pragma mark Mute (phone only)

- (void)bureauToggleMute {
    BOOL muted = ![[NSUserDefaults standardUserDefaults] boolForKey:BUREAU_MUTED_KEY];
    [[NSUserDefaults standardUserDefaults] setBool:muted forKey:BUREAU_MUTED_KEY];
    BureauSetAudioMuted(muted);
    [self bureauRefreshMuteTile];
}

- (void)bureauRefreshMuteTile {
    BOOL muted = [[NSUserDefaults standardUserDefaults] boolForKey:BUREAU_MUTED_KEY];
    [self bureauSetIcon:_bureauMuteButton symbol:(muted ? @"speaker.slash.fill" : @"speaker.wave.2")
                   tint:(muted ? UIColor.systemRedColor : UIColor.whiteColor)];
    _bureauMuteButton.accessibilityLabel = muted ? @"Remettre le son sur l'iPhone" : @"Couper le son sur l'iPhone";
}

#pragma mark Data used

// What the phone really exchanged on its network interfaces while a session is open:
// cellular (pdp_ip*) and Wi-Fi (en*), received + sent, headers, error correction and
// VPN included. Tunnels (utun*, Tailscale) are skipped, their traffic is already counted
// on the real interface. Includes the little that other apps exchange during the session.
// The system counters are 32-bit: read every 15 s, so they cannot wrap twice in between.
- (void)bureauReadInterfaces:(unsigned long long *)cellular wifi:(unsigned long long *)wifi {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) {
        Log(LOG_W, @"Moonlight Bureau: getifaddrs failed (%d)", errno);
        return;
    }
    if (_bureauIfLast == nil) {
        _bureauIfLast = [NSMutableDictionary dictionary];
    }
    BOOL baseline = _bureauIfLast.count == 0;
    for (struct ifaddrs *ifa = list; ifa != NULL; ifa = ifa->ifa_next) {
        if (ifa->ifa_addr == NULL || ifa->ifa_addr->sa_family != AF_LINK || ifa->ifa_data == NULL) {
            continue;
        }
        BOOL isCell = strncmp(ifa->ifa_name, "pdp_ip", 6) == 0;
        BOOL isWifi = strncmp(ifa->ifa_name, "en", 2) == 0;
        if (!isCell && !isWifi) {
            continue;
        }
        const struct if_data *d = (const struct if_data *)ifa->ifa_data;
        uint32_t now = d->ifi_ibytes + d->ifi_obytes; // wraps like the counters themselves
        NSString *name = [NSString stringWithUTF8String:ifa->ifa_name];
        NSNumber *last = _bureauIfLast[name];
        _bureauIfLast[name] = @(now);
        if (baseline || last == nil) {
            continue;
        }
        uint32_t delta = now - (uint32_t)last.unsignedIntValue;
        if (isCell) {
            *cellular += delta;
        } else {
            *wifi += delta;
        }
    }
    freeifaddrs(list);
}

// Saved per hour, 31 days kept: { hour: { "c": cellular, "w": wifi } }
- (void)bureauFlushDataUsage {
    unsigned long long cellular = 0, wifi = 0;
    [self bureauReadInterfaces:&cellular wifi:&wifi];
    if (cellular == 0 && wifi == 0) {
        return;
    }
    NSMutableDictionary *usage = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:BUREAU_DATA_KEY] mutableCopy] ?: [NSMutableDictionary dictionary];
    long long hour = (long long)floor([[NSDate date] timeIntervalSince1970] / 3600);
    NSString *key = [NSString stringWithFormat:@"%lld", hour];
    NSDictionary *old = usage[key];
    usage[key] = @{
        @"c": @([old[@"c"] unsignedLongLongValue] + cellular),
        @"w": @([old[@"w"] unsignedLongLongValue] + wifi),
    };
    for (NSString *k in usage.allKeys) {
        if (hour - [k longLongValue] > 31 * 24) {
            [usage removeObjectForKey:k];
        }
    }
    [[NSUserDefaults standardUserDefaults] setObject:usage forKey:BUREAU_DATA_KEY];
}

- (NSString *)bureauDataSummary {
    [self bureauFlushDataUsage];
    NSDictionary *usage = [[NSUserDefaults standardUserDefaults] dictionaryForKey:BUREAU_DATA_KEY];
    long long hour = (long long)floor([[NSDate date] timeIntervalSince1970] / 3600);
    unsigned long long cell[3] = {0, 0, 0}, wifi[3] = {0, 0, 0};
    long long limits[3] = {24, 7 * 24, 30 * 24};
    for (NSString *k in usage) {
        long long age = hour - [k longLongValue];
        for (int i = 0; i < 3; i++) {
            if (age < limits[i]) {
                cell[i] += [usage[k][@"c"] unsignedLongLongValue];
                wifi[i] += [usage[k][@"w"] unsignedLongLongValue];
            }
        }
    }
    NSByteCountFormatter *f = [[NSByteCountFormatter alloc] init];
    f.countStyle = NSByteCountFormatterCountStyleDecimal;
    return [NSString stringWithFormat:@"Réseau mobile  24 h : %@  ·  7 j : %@  ·  30 j : %@\nWi-Fi  24 h : %@  ·  7 j : %@  ·  30 j : %@",
            [f stringFromByteCount:(long long)cell[0]], [f stringFromByteCount:(long long)cell[1]], [f stringFromByteCount:(long long)cell[2]],
            [f stringFromByteCount:(long long)wifi[0]], [f stringFromByteCount:(long long)wifi[1]], [f stringFromByteCount:(long long)wifi[2]]];
}

- (void)bureauShowDataUsage {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Données consommées"
                                                                    message:[self bureauDataSummary]
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark Two-finger wheel

// One finger already drives the cursor: a second finger landing must not start the wheel or
// the zoom (the cursor and the view jumped)
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if ([gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]] &&
        ((UIPanGestureRecognizer *)gestureRecognizer).minimumNumberOfTouches == 2 &&
        BureauTrackpadSingleFingerLock) {
        return NO;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

static CGFloat BureauTouchDistance(UIGestureRecognizer *g) {
    if (g.numberOfTouches < 2) {
        return 0;
    }
    CGPoint a = [g locationOfTouch:0 inView:nil];
    CGPoint b = [g locationOfTouch:1 inView:nil];
    return hypot(a.x - b.x, a.y - b.y);
}

// Like Chrome Remote Desktop (remoting/client/ui/gesture_interpreter.cc): the finger movement
// is mapped to the desktop (divided by the zoom) and sent as wheel; after the fingers lift,
// the scroll goes on with a fling that slows down exponentially (time constant 250 ms).
static const CGFloat BUREAU_WHEEL_PER_POINT = 10;       // 120 = one notch every 12 points
static const CFTimeInterval BUREAU_SCROLL_FLING_T = 0.25;
static const CGFloat BUREAU_SCROLL_FLING_MIN = 40;       // points per second

- (void)bureauSendWheel:(CGPoint)screenDelta {
    CGFloat zoom = MAX(_scrollView.zoomScale, 1);
    CGFloat dy = screenDelta.y / zoom * BUREAU_WHEEL_PER_POINT + _bureauWheelRemainder.y;
    CGFloat dx = -screenDelta.x / zoom * BUREAU_WHEEL_PER_POINT + _bureauWheelRemainder.x;
    short vertical = (short)MAX(MIN(trunc(dy), 32767), -32767);
    short horizontal = (short)MAX(MIN(trunc(dx), 32767), -32767);
    _bureauWheelRemainder = CGPointMake(dx - horizontal, dy - vertical);
    if (vertical != 0) {
        LiSendHighResScrollEvent(vertical);
    }
    if (horizontal != 0) {
        LiSendHighResHScrollEvent(horizontal);
    }
}

- (void)bureauStopWheelFling {
    [_bureauWheelFling invalidate];
    _bureauWheelFling = nil;
}

// A new touch stops the wheel fling (and tells the trackpad not to click)
- (void)bureauTouchBegan:(NSNotification *)notification {
    if (_bureauWheelFling != nil) {
        [self bureauStopWheelFling];
        ((NSMutableDictionary *)notification.userInfo)[@"stopped"] = @YES;
    }
}

// The video size is known a moment after the first frame; until then the position is unknown
- (void)bureauSyncCursorSoon {
    if (_settings.absoluteTouchMode) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    for (NSNumber *delay in @[@0.3, @1.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            StreamFrameViewController *strongSelf = weakSelf;
            if (strongSelf != nil) {
                [strongSelf->_streamView bureauSyncCursor];
            }
        });
    }
}

- (void)bureauWheelFlingTick:(CADisplayLink *)link {
    CFTimeInterval now = link.timestamp;
    CFTimeInterval dt = MIN(now - _bureauWheelLastTick, 0.05);
    _bureauWheelLastTick = now;
    CGFloat decay = exp(-dt / BUREAU_SCROLL_FLING_T);
    // Distance covered during dt by v(t) = v0 * e^(-t/T)
    CGPoint step = CGPointMake(_bureauWheelVelocity.x * BUREAU_SCROLL_FLING_T * (1 - decay),
                               _bureauWheelVelocity.y * BUREAU_SCROLL_FLING_T * (1 - decay));
    _bureauWheelVelocity = CGPointMake(_bureauWheelVelocity.x * decay, _bureauWheelVelocity.y * decay);
    [self bureauSendWheel:step];
    if (hypot(_bureauWheelVelocity.x, _bureauWheelVelocity.y) < BUREAU_SCROLL_FLING_MIN) {
        [self bureauStopWheelFling];
    }
}

- (void)bureauWheel:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateBegan) {
        [self bureauStopWheelFling];
        _bureauWheelMode = 0;
        _bureauWheelStartDistance = BureauTouchDistance(pan);
        _bureauWheelStartZoom = _scrollView.zoomScale;
        _bureauWheelTravel = CGPointZero;
        _bureauWheelRemainder = CGPointZero;
        [pan setTranslation:CGPointZero inView:nil];
        return;
    }
    if (pan.state != UIGestureRecognizerStateChanged) {
        if (_bureauWheelMode == 1) {
            if (pan.state == UIGestureRecognizerStateEnded) {
                CGPoint v = [pan velocityInView:nil];
                // Keep only the main direction, like the wheel itself
                v = fabs(v.y) >= fabs(v.x) ? CGPointMake(0, v.y) : CGPointMake(v.x, 0);
                if (hypot(v.x, v.y) > BUREAU_SCROLL_FLING_MIN * 4) {
                    _bureauWheelVelocity = v;
                    _bureauWheelFling = [CADisplayLink displayLinkWithTarget:self selector:@selector(bureauWheelFlingTick:)];
                    _bureauWheelLastTick = CACurrentMediaTime();
                    [_bureauWheelFling addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
                }
            }
        }
        _bureauWheelMode = 0;
        return;
    }
    CGPoint t = [pan translationInView:nil];
    [pan setTranslation:CGPointZero inView:nil];

    if (_bureauWheelMode == 0) {
        _bureauWheelTravel.x += t.x;
        _bureauWheelTravel.y += t.y;
        CGFloat travel = hypot(_bureauWheelTravel.x, _bureauWheelTravel.y);
        CGFloat spread = fabs(BureauTouchDistance(pan) - _bureauWheelStartDistance);
        if (spread > 30 && spread > travel * 1.5) {
            _bureauWheelMode = 2; // fingers move apart/together: zoom
            _bureauWheelStartDistance = BureauTouchDistance(pan); // no jump when zoom starts
        } else if (travel > 8 && travel > spread * 1.5) {
            _bureauWheelMode = 1; // fingers move together: wheel
            t = _bureauWheelTravel;
        } else {
            return; // nothing moves until the gesture is clear
        }
    }
    if (_bureauWheelMode == 2) {
        // Zoom = finger spread ratio, pivot on the cursor (the view follows it)
        CGFloat distance = BureauTouchDistance(pan);
        if (distance > 1 && _bureauWheelStartDistance > 1) {
            CGFloat target = _bureauWheelStartZoom * distance / _bureauWheelStartDistance;
            target = MAX(_scrollView.minimumZoomScale, MIN(_scrollView.maximumZoomScale, target));
            // Smoothed, and ignores the finger jitter of a few points: no trembling
            CGFloat zoom = _scrollView.zoomScale + (target - _scrollView.zoomScale) * 0.5;
            if (fabs(target - _scrollView.zoomScale) > 0.01) {
                [_scrollView setZoomScale:zoom animated:NO];
                [self bureauCenterOnCursor];
            }
        }
        return;
    }
    if (_bureauWheelMode != 1) {
        return;
    }
    // Main direction only, so a vertical scroll does not drift sideways
    [self bureauSendWheel:(fabs(t.y) >= fabs(t.x) ? CGPointMake(0, t.y) : CGPointMake(t.x, 0))];
}

- (void)setupBureauComposer {
    // Composer pinned on top of the iOS keyboard (keyboardLayoutGuide, iOS 15+), same look as
    // the toolbar (dark blur), one compact line that grows with the text up to 3 lines
    UIVisualEffectView *composer = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    composer.translatesAutoresizingMaskIntoConstraints = NO;
    composer.hidden = YES;
    _bureauComposer = composer;
    [self.view addSubview:_bureauComposer];

    UIButton *hideKeyboard = [self bureauButtonWithSymbol:@"keyboard.chevron.compact.down" title:@"Fermer le clavier" action:@selector(bureauHideComposer)];
    UIButton *backspace = [self bureauButtonWithSymbol:@"delete.left" title:@"Retour arrière sur le PC" action:@selector(bureauSendBackspace)];
    UIButton *enter = [self bureauButtonWithSymbol:@"return" title:@"Envoyer puis Entrée" action:@selector(bureauSendWithEnter)];
    UIButton *send = [self bureauButtonWithSymbol:@"paperplane.fill" title:@"Envoyer" action:@selector(bureauSendText)];
    send.tintColor = UIColor.systemBlueColor;

    _bureauTextView = [[UITextView alloc] init];
    _bureauTextView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    _bureauTextView.layer.cornerRadius = 17;
    _bureauTextView.layer.cornerCurve = kCACornerCurveContinuous;
    _bureauTextView.textColor = UIColor.whiteColor;
    _bureauTextView.tintColor = UIColor.whiteColor;
    _bureauTextView.font = [UIFont systemFontOfSize:16];
    _bureauTextView.keyboardAppearance = UIKeyboardAppearanceDark;
    _bureauTextView.scrollEnabled = YES;
    _bureauTextView.textContainerInset = UIEdgeInsetsMake(8, 10, 8, 10);
    _bureauTextView.textContainer.lineFragmentPadding = 0;
    _bureauTextView.delegate = (id<UITextViewDelegate>)self;
    if (@available(iOS 17.0, *)) {
        _bureauTextView.inlinePredictionType = UITextInlinePredictionTypeNo;
    }
    _bureauPlaceholder = [[UILabel alloc] init];
    _bureauPlaceholder.text = @"Texte à envoyer…";
    _bureauPlaceholder.textColor = [UIColor colorWithWhite:1 alpha:0.4];
    _bureauPlaceholder.font = [UIFont systemFontOfSize:16];
    _bureauPlaceholder.translatesAutoresizingMaskIntoConstraints = NO;
    [_bureauTextView addSubview:_bureauPlaceholder];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[hideKeyboard, _bureauTextView, backspace, enter, send]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 2;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [composer.contentView addSubview:row];

    // Fixed height that follows the text (a scrolling text view has no height of its own:
    // between a minimum and a maximum, Auto Layout gave it the maximum)
    _bureauTextHeight = [_bureauTextView.heightAnchor constraintEqualToConstant:34];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_bureauComposer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_bureauComposer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_bureauComposer.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [row.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:4],
        [row.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-4],
        [row.topAnchor constraintEqualToAnchor:composer.contentView.topAnchor constant:2],
        [row.bottomAnchor constraintEqualToAnchor:composer.contentView.bottomAnchor constant:-2],
        _bureauTextHeight,
        [_bureauPlaceholder.leadingAnchor constraintEqualToAnchor:_bureauTextView.leadingAnchor constant:10],
        [_bureauPlaceholder.centerYAnchor constraintEqualToAnchor:_bureauTextView.topAnchor constant:17],
    ]];
    [_bureauTextView setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
}

- (void)bureauFitComposerHeight {
    CGFloat width = _bureauTextView.bounds.size.width;
    if (width < 10) {
        return;
    }
    CGFloat fit = [_bureauTextView sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)].height;
    CGFloat height = MIN(MAX(ceil(fit), 34), 84); // 1 to 3 lines, then it scrolls
    if (fabs(_bureauTextHeight.constant - height) > 0.5) {
        _bureauTextHeight.constant = height;
        [self.view layoutIfNeeded];
        [self bureauUpdateKeyboardOverlap];
    }
}

#pragma mark Menu

- (void)bureauPlaceFab {
    BOOL left = [[NSUserDefaults standardUserDefaults] boolForKey:@"MoonlightBureauFabLeft"];
    _bureauFabLeft.active = left;
    _bureauFabRight.active = !left;
}

- (UIAction *)bureauAction:(NSString *)title symbol:(NSString *)symbol handler:(void (^)(void))handler {
    return [UIAction actionWithTitle:title
                               image:(symbol != nil ? [UIImage systemImageNamed:symbol] : nil)
                          identifier:nil
                             handler:^(__kindof UIAction *action) {
        handler();
    }];
}

- (UIAction *)bureauShortcut:(NSString *)title symbol:(NSString *)symbol key:(short)vk modifiers:(char)modifiers {
    __weak typeof(self) weakSelf = self;
    return [self bureauAction:title symbol:symbol handler:^{
        [weakSelf bureauSendKey:vk modifiers:modifiers];
    }];
}

- (NSArray<UIMenuElement *> *)bureauMenuElements {
    __weak typeof(self) weakSelf = self;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    BOOL keyboardOpen = _bureauKeyInput.isFirstResponder;
    UIMenu *typing = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[
        [self bureauAction:(keyboardOpen ? @"Fermer le clavier" : @"Clavier")
                    symbol:(keyboardOpen ? @"keyboard.chevron.compact.down" : @"keyboard")
                   handler:^{ [weakSelf bureauToggleKeyboard]; }],
        [self bureauAction:@"Écrire avec correction" symbol:@"text.cursor" handler:^{ [weakSelf bureauShowComposer]; }],
        [self bureauAction:@"Coller le texte de l'iPhone" symbol:@"doc.on.clipboard" handler:^{ [weakSelf bureauPasteFromPhone]; }],
        [self bureauAction:@"Copier la sélection vers l'iPhone" symbol:@"arrow.down.doc" handler:^{ [weakSelf bureauCopyFromPC:YES]; }],
        [self bureauAction:@"Récupérer le presse-papiers du PC" symbol:@"doc.on.doc" handler:^{ [weakSelf bureauCopyFromPC:NO]; }],
        [self bureauAction:([defaults boolForKey:BUREAU_KEYROW_FOLDED_KEY] ? @"Afficher la barre de touches" : @"Réduire la barre de touches")
                    symbol:([defaults boolForKey:BUREAU_KEYROW_FOLDED_KEY] ? @"chevron.up" : @"chevron.down")
                   handler:^{ [weakSelf bureauSetKeyRowFolded:![defaults boolForKey:BUREAU_KEYROW_FOLDED_KEY]]; }],
    ]];

    UIMenu *shortcuts = [UIMenu menuWithTitle:@"Raccourcis" image:[UIImage systemImageNamed:@"command"] identifier:nil options:0 children:@[
        [self bureauShortcut:@"Copier" symbol:@"doc.on.doc" key:'C' modifiers:MODIFIER_CTRL],
        [self bureauShortcut:@"Coller" symbol:@"doc.on.clipboard" key:'V' modifiers:MODIFIER_CTRL],
        [self bureauShortcut:@"Couper" symbol:@"scissors" key:'X' modifiers:MODIFIER_CTRL],
        [self bureauShortcut:@"Annuler" symbol:@"arrow.uturn.backward" key:'Z' modifiers:MODIFIER_CTRL],
        [self bureauShortcut:@"Tout sélectionner" symbol:@"checklist" key:'A' modifiers:MODIFIER_CTRL],
        [self bureauShortcut:@"Rechercher" symbol:@"magnifyingglass" key:'F' modifiers:MODIFIER_CTRL],
        [self bureauShortcut:@"Changer de fenêtre (Alt+Tab)" symbol:@"rectangle.on.rectangle" key:BUREAU_VK_TAB modifiers:MODIFIER_ALT],
        [self bureauShortcut:@"Afficher le bureau" symbol:@"menubar.dock.rectangle" key:'D' modifiers:MODIFIER_META],
        [self bureauShortcut:@"Fermer la fenêtre (Alt+F4)" symbol:@"xmark.square" key:0x73 modifiers:MODIFIER_ALT],
        [self bureauShortcut:@"Gestionnaire des tâches" symbol:@"cpu" key:BUREAU_VK_ESCAPE modifiers:(MODIFIER_CTRL | MODIFIER_SHIFT)],
        [self bureauShortcut:@"Capture d'écran" symbol:@"camera.viewfinder" key:'S' modifiers:(MODIFIER_META | MODIFIER_SHIFT)],
        [self bureauShortcut:@"Menu Démarrer" symbol:@"square.grid.2x2" key:BUREAU_VK_LWIN modifiers:0],
    ]];

    NSMutableArray<UIMenuElement *> *viewItems = [NSMutableArray array];
    if (_scrollView.zoomScale > 1.01f) {
        [viewItems addObject:[self bureauAction:@"Zoom 100 %" symbol:@"arrow.down.right.and.arrow.up.left" handler:^{ [weakSelf bureauResetZoom]; }]];
    }
    BOOL muted = [defaults boolForKey:BUREAU_MUTED_KEY];
    [viewItems addObject:[self bureauAction:(muted ? @"Remettre le son" : @"Couper le son de l'iPhone")
                                     symbol:(muted ? @"speaker.wave.2" : @"speaker.slash")
                                    handler:^{ [weakSelf bureauToggleMute]; }]];
    BOOL locked = [self bureauOrientationLock] != 0;
    [viewItems addObject:[self bureauAction:(locked ? @"Déverrouiller l'orientation" : @"Verrouiller l'orientation")
                                     symbol:(locked ? @"lock.rotation.open" : @"lock.rotation")
                                    handler:^{ [weakSelf bureauToggleOrientationLock]; }]];
    [viewItems addObject:[self bureauAction:@"Données consommées" symbol:@"chart.bar" handler:^{ [weakSelf bureauShowDataUsage]; }]];
    if ([MainFrameViewController bureauSessionInDataMode]) {
        [viewItems addObject:[self bureauAction:@"Mode données : activé" symbol:@"antenna.radiowaves.left.and.right"
                                        handler:^{ [weakSelf bureauAskDisableDataMode]; }]];
    } else if ([MainFrameViewController bureauOnMobileData]) {
        [viewItems addObject:[self bureauAction:@"Mode données : désactivé" symbol:@"antenna.radiowaves.left.and.right.slash"
                                        handler:^{ [weakSelf bureauEnableDataMode]; }]];
    }
    BOOL left = [defaults boolForKey:@"MoonlightBureauFabLeft"];
    [viewItems addObject:[self bureauAction:(left ? @"Mettre ce bouton à droite" : @"Mettre ce bouton à gauche")
                                     symbol:(left ? @"arrow.right.to.line" : @"arrow.left.to.line")
                                    handler:^{
        [[NSUserDefaults standardUserDefaults] setBool:!left forKey:@"MoonlightBureauFabLeft"];
        StreamFrameViewController *strongSelf = weakSelf;
        [strongSelf bureauPlaceFab];
        [UIView animateWithDuration:0.25 animations:^{
            [strongSelf.view layoutIfNeeded];
        }];
    }]];
    UIMenu *view = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:viewItems];

    UIAction *disconnect = [self bureauAction:@"Se déconnecter" symbol:@"xmark.circle" handler:^{ [weakSelf bureauDisconnect]; }];
    disconnect.attributes = UIMenuElementAttributesDestructive;
    UIMenu *end = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[disconnect]];

    return @[typing, shortcuts, view, end];
}

#pragma mark Direct keyboard

- (void)setupBureauKeyInput {
    _bureauKeyInput = [[BureauKeyInput alloc] initWithFrame:CGRectZero];
    __weak typeof(self) weakSelf = self;
    _bureauKeyInput.onText = ^(NSString *text) {
        [weakSelf bureauTypeText:text];
    };
    _bureauKeyInput.onBackspace = ^{
        [weakSelf bureauSendKey:BUREAU_VK_BACK modifiers:0];
    };
    [self.view addSubview:_bureauKeyInput];

    // One thin row above the keyboard: close, keys the iPhone keyboard lacks, paste, and the
    // switch to typing with correction. It scrolls sideways on a narrow screen.
    UIVisualEffectView *row = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    row.frame = CGRectMake(0, 0, MAX(self.view.bounds.size.width, 320), 40);
    row.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UIButton *close = [self bureauButtonWithSymbol:@"keyboard.chevron.compact.down" title:@"Fermer le clavier" action:@selector(bureauHideKeyboard)];
    UIButton *corrected = [self bureauButtonWithSymbol:@"text.cursor" title:@"Écrire avec correction" action:@selector(bureauShowComposer)];
    UIButton *paste = [self bureauButtonWithSymbol:@"doc.on.clipboard" title:@"Coller le texte de l'iPhone" action:@selector(bureauPasteFromPhone)];
    NSArray *keys = @[
        @[@"Échap", @(BUREAU_VK_ESCAPE), @0], @[@"Tab", @(BUREAU_VK_TAB), @0], @[@"⊞", @(BUREAU_VK_LWIN), @0],
        @[@"←", @(BUREAU_VK_LEFT), @0], @[@"↑", @(BUREAU_VK_UP), @0], @[@"↓", @(BUREAU_VK_DOWN), @0], @[@"→", @(BUREAU_VK_RIGHT), @0],
        @[@"Suppr", @(BUREAU_VK_DELETE), @0],
    ];
    UIStackView *keysStack = [[UIStackView alloc] init];
    keysStack.axis = UILayoutConstraintAxisHorizontal;
    keysStack.spacing = 0;
    keysStack.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSArray *key in keys) {
        UIButton *b = [self bureauButtonWithSymbol:nil title:key[0] action:@selector(bureauKeyButton:)];
        b.tag = ([key[1] intValue] & 0xFF) | ([key[2] intValue] << 8);
        [keysStack addArrangedSubview:b];
    }
    [keysStack addArrangedSubview:paste];
    UIScrollView *keysScroll = [[UIScrollView alloc] init];
    keysScroll.showsHorizontalScrollIndicator = NO;
    keysScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [keysScroll addSubview:keysStack];

    UIButton *fold = [self bureauButtonWithSymbol:@"chevron.down" title:@"Réduire la barre de touches" action:@selector(bureauFoldKeyRow)];
    UIStackView *line = [[UIStackView alloc] initWithArrangedSubviews:@[close, keysScroll, corrected, fold]];
    line.axis = UILayoutConstraintAxisHorizontal;
    line.alignment = UIStackViewAlignmentCenter;
    line.spacing = 2;
    line.translatesAutoresizingMaskIntoConstraints = NO;
    [row.contentView addSubview:line];
    [NSLayoutConstraint activateConstraints:@[
        [keysStack.leadingAnchor constraintEqualToAnchor:keysScroll.contentLayoutGuide.leadingAnchor],
        [keysStack.trailingAnchor constraintEqualToAnchor:keysScroll.contentLayoutGuide.trailingAnchor],
        [keysStack.topAnchor constraintEqualToAnchor:keysScroll.contentLayoutGuide.topAnchor],
        [keysStack.bottomAnchor constraintEqualToAnchor:keysScroll.contentLayoutGuide.bottomAnchor],
        [keysStack.heightAnchor constraintEqualToAnchor:keysScroll.frameLayoutGuide.heightAnchor],
        [keysScroll.heightAnchor constraintEqualToConstant:40],
        [line.leadingAnchor constraintEqualToAnchor:row.contentView.safeAreaLayoutGuide.leadingAnchor constant:2],
        [line.trailingAnchor constraintEqualToAnchor:row.contentView.safeAreaLayoutGuide.trailingAnchor constant:-2],
        [line.topAnchor constraintEqualToAnchor:row.contentView.topAnchor],
        [line.bottomAnchor constraintEqualToAnchor:row.contentView.bottomAnchor],
    ]];
    [keysScroll setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    _bureauKeyRow = row;

    // Folded: no row at all (the keyboard takes the least room), only a small round button
    // above the menu button to bring the row back
    _bureauKeyRowButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _bureauKeyRowButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
    [_bureauKeyRowButton setImage:[UIImage systemImageNamed:@"chevron.up" withConfiguration:config] forState:UIControlStateNormal];
    _bureauKeyRowButton.tintColor = UIColor.whiteColor;
    _bureauKeyRowButton.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.55];
    _bureauKeyRowButton.layer.cornerRadius = 18;
    _bureauKeyRowButton.layer.borderWidth = 0.5;
    _bureauKeyRowButton.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    _bureauKeyRowButton.accessibilityLabel = @"Afficher la barre de touches";
    _bureauKeyRowButton.hidden = YES;
    [_bureauKeyRowButton addTarget:self action:@selector(bureauUnfoldKeyRow) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_bureauKeyRowButton];
    [NSLayoutConstraint activateConstraints:@[
        [_bureauKeyRowButton.widthAnchor constraintEqualToConstant:36],
        [_bureauKeyRowButton.heightAnchor constraintEqualToConstant:36],
        [_bureauKeyRowButton.centerXAnchor constraintEqualToAnchor:_bureauFab.centerXAnchor],
        [_bureauKeyRowButton.bottomAnchor constraintEqualToAnchor:_bureauFab.topAnchor constant:-10],
    ]];
    [self bureauSetKeyRowFolded:[[NSUserDefaults standardUserDefaults] boolForKey:BUREAU_KEYROW_FOLDED_KEY]];
}

- (void)bureauFoldKeyRow {
    [self bureauSetKeyRowFolded:YES];
}

- (void)bureauUnfoldKeyRow {
    [self bureauSetKeyRowFolded:NO];
}

// Remembered between sessions. The keyboard redraws at once, the picture follows it.
- (void)bureauSetKeyRowFolded:(BOOL)folded {
    [[NSUserDefaults standardUserDefaults] setBool:folded forKey:BUREAU_KEYROW_FOLDED_KEY];
    _bureauKeyInput.bureauAccessory = folded ? nil : _bureauKeyRow;
    if (_bureauKeyInput.isFirstResponder) {
        [_bureauKeyInput reloadInputViews];
    }
    [self bureauUpdateKeyRowButton];
}

- (void)bureauUpdateKeyRowButton {
    BOOL folded = [[NSUserDefaults standardUserDefaults] boolForKey:BUREAU_KEYROW_FOLDED_KEY];
    _bureauKeyRowButton.hidden = !(folded && _bureauKeyInput.isFirstResponder && !_bureauFab.hidden);
    if (!_bureauKeyRowButton.hidden) {
        [self.view bringSubviewToFront:_bureauKeyRowButton];
    }
}

// One typed key or a dictated / pasted string
- (void)bureauTypeText:(NSString *)text {
    if ([text isEqualToString:@"\n"]) {
        [self bureauSendKey:BUREAU_VK_RETURN modifiers:0];
    } else if ([text isEqualToString:@"\t"]) {
        [self bureauSendKey:BUREAU_VK_TAB modifiers:0];
    } else if (text.length > 0) {
        [self bureauSendTextToPC:text];
    }
}

- (void)bureauToggleKeyboard {
    if (_bureauKeyInput.isFirstResponder) {
        [self bureauHideKeyboard];
    } else {
        [self bureauShowKeyboard];
    }
}

- (void)bureauShowKeyboard {
    if (!_bureauComposer.hidden) {
        _bureauComposer.hidden = YES;
        _bureauFab.hidden = NO;
    }
    [_bureauKeyInput becomeFirstResponder];
    [self bureauUpdateKeyRowButton];
}

// The stream view takes the focus back, so a Bluetooth keyboard keeps typing on the PC
- (void)bureauHideKeyboard {
    [_bureauKeyInput resignFirstResponder];
    [_streamView becomeFirstResponder];
    [self bureauUpdateKeyRowButton];
}

#pragma mark Drag feedback

// Like Chrome Remote Desktop (trackpad_input_strategy.cc, kDragFeedbackRadius): a small ring
// on the cursor while a long press drags, so it is clear the button is held
- (void)bureauDragStarted {
    if (_bureauDragRing == nil) {
        _bureauDragRing = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
        _bureauDragRing.userInteractionEnabled = NO;
        _bureauDragRing.layer.cornerRadius = 15;
        _bureauDragRing.layer.borderWidth = 2;
        _bureauDragRing.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.9].CGColor;
        _bureauDragRing.backgroundColor = [UIColor colorWithWhite:1 alpha:0.15];
        [self.view addSubview:_bureauDragRing];
    }
    [self bureauPlaceDragRing];
    _bureauDragRing.alpha = 0;
    _bureauDragRing.transform = CGAffineTransformMakeScale(1.6, 1.6);
    [self.view bringSubviewToFront:_bureauDragRing];
    [UIView animateWithDuration:0.15 animations:^{
        self->_bureauDragRing.alpha = 1;
        self->_bureauDragRing.transform = CGAffineTransformIdentity;
    }];
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

- (void)bureauDragEnded {
    [UIView animateWithDuration:0.2 animations:^{
        self->_bureauDragRing.alpha = 0;
    }];
}

- (void)bureauPlaceDragRing {
    if (_bureauDragRing == nil || !_bureauCursorKnown) {
        return;
    }
    _bureauDragRing.center = [_streamView convertPoint:_bureauCursor toView:self.view];
}

#pragma mark Privacy in the app switcher

// Like Chrome Remote Desktop: when the app leaves the screen, the PC picture is blurred, so
// the app switcher does not show the desktop
- (void)bureauShowPrivacyBlur {
    if (_bureauPrivacyBlur != nil) {
        return;
    }
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleRegular]];
    blur.frame = self.view.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:blur];
    _bureauPrivacyBlur = blur;
}

- (void)bureauHidePrivacyBlur {
    [_bureauPrivacyBlur removeFromSuperview];
    _bureauPrivacyBlur = nil;
}

#pragma mark Actions

- (void)bureauResetZoom {
    [_scrollView setZoomScale:1.0 animated:YES];
}

// Confirmation against mis-taps, then the app closes (not back to the PC list)
- (void)bureauDisconnect {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Se déconnecter ?"
                                                                    message:@"La connexion s'arrête et l'appli se ferme. Ta session reste ouverte sur le PC."
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Se déconnecter" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self bureauQuitApp];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// The stream stops cleanly (returnToMainFrame -> stopStream), then the app goes to the home
// screen with the usual animation and ends. Nothing to resume at the next opening.
- (void)bureauQuitApp {
    Log(LOG_I, @"Moonlight Bureau: disconnect and quit the app");
    [MainFrameViewController bureauCancelResume];
    [self returnToMainFrame];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIApplication *app = UIApplication.sharedApplication;
        SEL suspend = NSSelectorFromString(@"suspend");
        if ([app respondsToSelector:suspend]) {
            ((void (*)(id, SEL))[app methodForSelector:suspend])(app, suspend);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            exit(0);
        });
    });
}

- (void)bureauKeyButton:(UIButton *)sender {
    short vk = sender.tag & 0xFF;
    char modifiers = (char)((sender.tag >> 8) & 0xFF);
    [self bureauSendKey:vk modifiers:modifiers];
}

// Paste: the whole text at once (PC clipboard + Ctrl+V), line breaks kept as they are. A
// paste inserts them as new lines in a text field: they never act as Enter, so a chat app
// does not send the message halfway. Only final blank lines are dropped.
- (void)bureauPasteFromPhone {
    NSString *text = UIPasteboard.generalPasteboard.string ?: @"";
    text = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
            stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSRange last = [text rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet].invertedSet
                                         options:NSBackwardsSearch];
    if (last.location == NSNotFound) {
        UIAlertController *empty = [UIAlertController alertControllerWithTitle:@"Rien à coller"
                                                                        message:@"Copie d'abord un texte sur l'iPhone."
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        [empty addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:empty animated:YES completion:nil];
        return;
    }
    text = [text substringToIndex:NSMaxRange(last)];
    [self bureauPasteText:text];
}

- (void)bureauPasteText:(NSString *)text {
    unsigned short port = 0;
    NSString *address = [self bureauHelperAddress:&port];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    dispatch_async(BureauInputQueue(), ^{
        if (address.length > 0 && BureauSendToPCClipboard(address, port, data)) {
            usleep(50 * 1000);
            [self bureauKeyPressSync:BUREAU_VK_V modifiers:MODIFIER_CTRL];
            return;
        }
        Log(LOG_W, @"Moonlight Bureau: PC clipboard helper unreachable on %@:%u", address, port);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self bureauOfferTypedPaste:text];
        });
    });
}

// PC -> iPhone. With the selection: Ctrl+C on the PC first, then its clipboard is fetched.
- (void)bureauCopyFromPC:(BOOL)copySelection {
    unsigned short port = 0;
    NSString *address = [self bureauHelperAddress:&port];
    dispatch_async(BureauInputQueue(), ^{
        if (copySelection) {
            [self bureauKeyPressSync:BUREAU_VK_C modifiers:MODIFIER_CTRL];
            usleep(300 * 1000); // let the PC app fill its clipboard
        }
        NSString *text = address.length > 0 ? BureauFetchPCClipboard(address, port) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (text == nil) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Copie indisponible"
                                                                               message:@"Le PC n'a pas répondu : le service de copier-coller n'y est pas lancé."
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            } else if (text.length == 0) {
                [self bureauShowToast:(copySelection ? @"Rien de sélectionné sur le PC" : @"Le presse-papiers du PC est vide")];
            } else {
                UIPasteboard.generalPasteboard.string = text;
                [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
                [self bureauShowToast:[NSString stringWithFormat:@"Copié sur l'iPhone (%lu caractères)", (unsigned long)text.length]];
            }
        });
    });
}

// Short message at the top, gone by itself
- (void)bureauShowToast:(NSString *)text {
    UIVisualEffectView *box = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    box.layer.cornerRadius = 14;
    box.clipsToBounds = YES;
    box.userInteractionEnabled = NO;
    box.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [box.contentView addSubview:label];
    [self.view addSubview:box];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:box.contentView.leadingAnchor constant:14],
        [label.trailingAnchor constraintEqualToAnchor:box.contentView.trailingAnchor constant:-14],
        [label.topAnchor constraintEqualToAnchor:box.contentView.topAnchor constant:9],
        [label.bottomAnchor constraintEqualToAnchor:box.contentView.bottomAnchor constant:-9],
        [box.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [box.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [box.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-40],
    ]];
    box.alpha = 0;
    [UIView animateWithDuration:0.2 animations:^{
        box.alpha = 1;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.3 delay:2.2 options:0 animations:^{
            box.alpha = 0;
        } completion:^(BOOL done) {
            [box removeFromSuperview];
        }];
    }];
}

#pragma mark Data mode

// Changing frame rate or bitrate needs a new connection: the PC session stays open and the
// app reconnects to it at once (same path as coming back from the background)
- (void)bureauReconnect {
    [MainFrameViewController bureauRequestResume];
    [self returnToMainFrame];
}

- (void)bureauAskDisableDataMode {
    TemporarySettings *settings = [[[DataManager alloc] init] getSettings];
    int fps = MIN([settings.framerate intValue], (int)[UIScreen mainScreen].maximumFramesPerSecond);
    double mbps = [settings.bitrate intValue] / 1000.0;
    double dataMbps = [MainFrameViewController bureauDataModeBitrate] / 1000.0;
    NSString *message = [NSString stringWithFormat:@"L'image repasse à %d images/s et jusqu'à %.0f Mb/s : jusqu'à environ %.0f Go par heure en vidéo ou en défilement, contre %.0f Go au plus en mode données. Un bureau immobile consomme peu dans les deux cas.\n\nLa connexion redémarre quelques secondes. Le mode données revient tout seul après un passage en Wi-Fi.",
                         fps, mbps, mbps * 0.45, ceil(dataMbps * 0.45)];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Désactiver le mode données ?"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Garder le mode données" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Désactiver" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [MainFrameViewController bureauSetDataModeOffByUser:YES];
        [self bureauReconnect];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)bureauEnableDataMode {
    [MainFrameViewController bureauSetDataModeOffByUser:NO];
    [self bureauReconnect];
}

// Wi-Fi <-> mobile data during a session: propose the matching quality, never forced
- (void)bureauNetworkCostChanged {
    if (self.presentedViewController != nil) {
        return;
    }
    BOOL mobile = [MainFrameViewController bureauOnMobileData];
    BOOL dataMode = [MainFrameViewController bureauSessionInDataMode];
    NSString *title = nil;
    NSString *message = nil;
    if (mobile && !dataMode && ![MainFrameViewController bureauDataModeOffByUser]) {
        title = @"Données mobiles";
        message = @"Tu n'es plus en Wi-Fi. Passer en mode données pour consommer moins ? La connexion redémarre quelques secondes.";
    } else if (!mobile && dataMode) {
        title = @"Wi-Fi retrouvé";
        message = @"Repasser en pleine qualité ? La connexion redémarre quelques secondes.";
    } else {
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Plus tard" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reconnecter" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self bureauReconnect];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// Home-screen "Fermer la session du PC" while this stream is open: stop it first
- (void)bureauStopForQuit {
    [MainFrameViewController bureauCancelResume];
    [self returnToMainFrame];
}

// Never a silent switch to key-by-key typing: it is slower and can mix letters up
- (void)bureauOfferTypedPaste:(NSString *)text {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Collage d'un coup indisponible"
                                                                   message:@"Le PC n'a pas répondu : le service de collage n'y est pas lancé. Le texte peut être tapé touche par touche à la place, plus lentement."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Taper le texte" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self bureauSendTextToPC:text];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark Composer

- (void)bureauShowComposer {
    _bureauFab.hidden = YES;
    _bureauComposer.hidden = NO;
    [self.view bringSubviewToFront:_bureauComposer];
    [_bureauTextView becomeFirstResponder];
    [self.view layoutIfNeeded];
    [self bureauFitComposerHeight];
    [self.view setNeedsLayout];
}

- (void)bureauHideComposer {
    [_bureauTextView resignFirstResponder];
    [_streamView becomeFirstResponder];
    _bureauComposer.hidden = YES;
    _bureauFab.hidden = NO;
    [self.view setNeedsLayout];
}

// Keyboard closed by any means (swipe, other app...): hide the composer too
- (void)textViewDidEndEditing:(UITextView *)textView {
    if (textView == _bureauTextView && !_bureauTextView.isFirstResponder) {
        _bureauComposer.hidden = YES;
        _bureauFab.hidden = NO;
    }
}

- (void)textViewDidChange:(UITextView *)textView {
    if (textView == _bureauTextView) {
        [self bureauFitComposerHeight];
        _bureauPlaceholder.hidden = textView.text.length > 0;
    }
}

- (void)bureauTakeComposedText:(void (^)(NSString *text))handler {
    // A word still being composed (marked text) is committed first
    [_bureauTextView unmarkText];
    NSString *text = _bureauTextView.text ?: @"";
    // Tell the keyboard the text changed, so its suggestions do not refer to the old text
    [_bureauTextView.inputDelegate textWillChange:_bureauTextView];
    _bureauTextView.text = @"";
    [_bureauTextView.inputDelegate textDidChange:_bureauTextView];
    [self bureauFitComposerHeight];
    _bureauPlaceholder.hidden = NO;
    handler(text);
}

- (void)bureauSendText {
    [self bureauTakeComposedText:^(NSString *text) {
        if (text.length > 0) {
            [self bureauSendTextToPC:text];
        }
    }];
}

- (void)bureauSendWithEnter {
    [self bureauTakeComposedText:^(NSString *text) {
        if (text.length > 0) {
            [self bureauSendTextToPC:text];
        }
        [self bureauSendKey:BUREAU_VK_RETURN modifiers:0];
    }];
}

- (void)bureauSendBackspace {
    [self bureauSendKey:BUREAU_VK_BACK modifiers:0];
}

#pragma mark Sending to the PC

// Text is sent as Unicode. A line break becomes Shift+Enter: a new line in editors and
// chat apps, not a "send" or "validate". Each event carries at most 32 UTF-8 bytes
// (UTF8_TEXT_EVENT_MAX_COUNT), so chunks never split a character.
- (void)bureauSendTextToPC:(NSString *)text {
    NSString *normalized = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
                            stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSArray<NSString *> *lines = [normalized componentsSeparatedByString:@"\n"];
    dispatch_async(BureauInputQueue(), ^{
        for (NSUInteger i = 0; i < lines.count; i++) {
            if (i > 0) {
                [self bureauKeyPressSync:BUREAU_VK_RETURN modifiers:MODIFIER_SHIFT];
            }
            NSString *line = lines[i];
            NSMutableString *chunk = [NSMutableString string];
            NSUInteger chunkBytes = 0;
            NSUInteger index = 0;
            while (index < line.length) {
                NSRange range = [line rangeOfComposedCharacterSequenceAtIndex:index];
                NSString *character = [line substringWithRange:range];
                NSUInteger bytes = [character lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
                if (chunkBytes + bytes > 32 && chunk.length > 0) {
                    LiSendUtf8TextEvent(chunk.UTF8String, (unsigned int)chunkBytes);
                    [chunk setString:@""];
                    chunkBytes = 0;
                }
                if (bytes <= 32) {
                    [chunk appendString:character];
                    chunkBytes += bytes;
                }
                index = NSMaxRange(range);
            }
            if (chunkBytes > 0) {
                LiSendUtf8TextEvent(chunk.UTF8String, (unsigned int)chunkBytes);
            }
            usleep(10 * 1000);
        }
    });
}

- (void)bureauSendKey:(short)vk modifiers:(char)modifiers {
    dispatch_async(BureauInputQueue(), ^{
        [self bureauKeyPressSync:vk modifiers:modifiers];
    });
}

// Presses the modifiers, then the key, then releases everything (background thread only)
- (void)bureauKeyPressSync:(short)vk modifiers:(char)modifiers {
    short modifierKeys[4] = { BUREAU_VK_LCONTROL, BUREAU_VK_LSHIFT, BUREAU_VK_LMENU, BUREAU_VK_LWIN };
    char modifierFlags[4] = { MODIFIER_CTRL, MODIFIER_SHIFT, MODIFIER_ALT, MODIFIER_META };
    char held = 0;
    for (int i = 0; i < 4; i++) {
        if (modifiers & modifierFlags[i]) {
            held |= modifierFlags[i];
            LiSendKeyboardEvent(0x8000 | modifierKeys[i], KEY_ACTION_DOWN, held);
        }
    }
    // Let Windows register the modifiers before the key (Ctrl+C was sometimes taken as C)
    if (modifiers != 0) {
        usleep(40 * 1000);
    }
    LiSendKeyboardEvent(0x8000 | vk, KEY_ACTION_DOWN, modifiers);
    usleep(30 * 1000);
    LiSendKeyboardEvent(0x8000 | vk, KEY_ACTION_UP, modifiers);
    if (modifiers != 0) {
        usleep(40 * 1000);
    }
    for (int i = 3; i >= 0; i--) {
        if (modifiers & modifierFlags[i]) {
            held &= ~modifierFlags[i];
            LiSendKeyboardEvent(0x8000 | modifierKeys[i], KEY_ACTION_UP, held);
        }
    }
}
#endif

@end

#if !TARGET_OS_TV
// Moonlight Bureau: containers ask the visible screen which orientations it supports
// (navigation controller -> top screen, reveal controller -> front screen).
@implementation UINavigationController (MoonlightBureauOrientation)
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return self.topViewController ? self.topViewController.supportedInterfaceOrientations : UIInterfaceOrientationMaskLandscape;
}
// Same for system edge gestures and the home indicator (Apple: the container asks its child)
- (UIViewController *)childViewControllerForScreenEdgesDeferringSystemGestures {
    return self.topViewController;
}
- (UIViewController *)childViewControllerForHomeIndicatorAutoHidden {
    return self.topViewController;
}
@end

#import "SWRevealViewController.h"
@implementation SWRevealViewController (MoonlightBureauOrientation)
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return self.frontViewController ? self.frontViewController.supportedInterfaceOrientations : UIInterfaceOrientationMaskLandscape;
}
- (UIViewController *)childViewControllerForScreenEdgesDeferringSystemGestures {
    return self.frontViewController;
}
- (UIViewController *)childViewControllerForHomeIndicatorAutoHidden {
    return self.frontViewController;
}
@end
#endif
