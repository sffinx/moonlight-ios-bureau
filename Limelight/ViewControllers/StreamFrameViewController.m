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
    UIButton *_bureauRotationButton;
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
        _scrollView = [[UIScrollView alloc] initWithFrame:self.view.frame];
#if !TARGET_OS_TV
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
    [self bureauCenterOnCursor];
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
    if (_bureauInBackground) {
        _bureauInBackground = NO;
        _bureauForegroundAt = [NSDate date];
        [MainFrameViewController bureauCancelResume];
        // Fresh full picture right away (the decoder rebuilds itself if iOS broke it)
        LiRequestIdrFrame();
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
            title = @"Connection Error";
            message = @"Your device's network connection is blocking Moonlight. Streaming may not work while connected to this network.";
        }
        else {
            switch (errorCode) {
                case ML_ERROR_GRACEFUL_TERMINATION:
                    [self returnToMainFrame];
                    return;
                    
                case ML_ERROR_NO_VIDEO_TRAFFIC:
                    title = @"Connection Error";
                    message = @"No video received from host.";
                    if (portFlags != 0) {
                        char failingPorts[256];
                        LiStringifyPortFlags(portFlags, "\n", failingPorts, sizeof(failingPorts));
                        message = [message stringByAppendingString:[NSString stringWithFormat:@"\n\nCheck your firewall and port forwarding rules for port(s):\n%s", failingPorts]];
                    }
                    break;
                    
                case ML_ERROR_NO_VIDEO_FRAME:
                    title = @"Connection Error";
                    message = @"Your network connection isn't performing well. Reduce your video bitrate setting or try a faster connection.";
                    break;
                    
                case ML_ERROR_UNEXPECTED_EARLY_TERMINATION:
                case ML_ERROR_PROTECTED_CONTENT:
                    title = @"Connection Error";
                    message = @"Something went wrong on your host PC when starting the stream.\n\nMake sure you don't have any DRM-protected content open on your host PC. You can also try restarting your host PC.\n\nIf the issue persists, try reinstalling your GPU drivers and GeForce Experience.";
                    break;
                    
                case ML_ERROR_FRAME_CONVERSION:
                    title = @"Connection Error";
                    message = @"The host PC reported a fatal video encoding error.\n\nTry disabling HDR mode, changing the streaming resolution, or changing your host PC's display resolution.";
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
                    
                    title = @"Connection Terminated";
                    message = [NSString stringWithFormat: @"The connection was terminated\n\nError code: %@", errorString];
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
            message = [message stringByAppendingString:[NSString stringWithFormat:@"\n\nCheck your firewall and port forwarding rules for port(s):\n%s", failingPorts]];
        }
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            message = [message stringByAppendingString:@"\n\nYour device's network connection is blocking Moonlight. Streaming may not work while connected to this network."];
        }
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Connection Failed"
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
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Connection Error"
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
    [self bureauRestartHideTimer];
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

// Part of the screen covered by the iOS keyboard and, when shown, the composer above it.
// keyboardLayoutGuide follows the keyboard (its height is the bottom safe area when hidden).
- (void)bureauUpdateKeyboardOverlap {
    if (_scrollView == nil || _settings.absoluteTouchMode) {
        return;
    }
    UILayoutGuide *guide = self.view.keyboardLayoutGuide;
    CGFloat overlap = 0;
    if (guide.layoutFrame.size.height > self.view.safeAreaInsets.bottom + 1) {
        CGFloat top = guide.layoutFrame.origin.y;
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
    _scrollView.frame = self.view.bounds;
    if (_scrollView.zoomScale <= 1.001f && !CGRectEqualToRect(_streamView.frame, _scrollView.bounds)) {
        _streamView.frame = CGRectMake(0, 0, _scrollView.bounds.size.width, _scrollView.bounds.size.height);
        _scrollView.contentSize = _scrollView.bounds.size;
        [_streamView setNeedsLayout];
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

static const NSTimeInterval BUREAU_AUTOHIDE_SECONDS = 5.0;
static const short BUREAU_VK_BACK = 0x08, BUREAU_VK_TAB = 0x09, BUREAU_VK_RETURN = 0x0D,
                   BUREAU_VK_ESCAPE = 0x1B, BUREAU_VK_LEFT = 0x25, BUREAU_VK_UP = 0x26,
                   BUREAU_VK_RIGHT = 0x27, BUREAU_VK_DOWN = 0x28, BUREAU_VK_DELETE = 0x2E,
                   BUREAU_VK_LWIN = 0x5B, BUREAU_VK_LSHIFT = 0xA0, BUREAU_VK_LCONTROL = 0xA2,
                   BUREAU_VK_LMENU = 0xA4;

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
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    // Toolbar: blurred, rounded, top center
    _bureauBar = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    _bureauBar.translatesAutoresizingMaskIntoConstraints = NO;
    _bureauBar.layer.cornerRadius = 14;
    _bureauBar.clipsToBounds = YES;
    _bureauBar.alpha = 0.92;
    _bureauBar.hidden = YES;
    [self.view addSubview:_bureauBar];

    _bureauPinButton = [self bureauButtonWithSymbol:@"pin" title:@"Épingler" action:@selector(bureauTogglePin)];
    _bureauMuteButton = [self bureauButtonWithSymbol:@"speaker.wave.2" title:@"Couper le son sur l'iPhone" action:@selector(bureauToggleMute)];
    _bureauDataButton = [self bureauButtonWithSymbol:@"chart.bar" title:@"Données consommées" action:@selector(bureauToggleDataShown)];
    NSArray<UIButton *> *mainButtons = @[
        [self bureauButtonWithSymbol:@"keyboard" title:@"Clavier" action:@selector(bureauShowComposer)],
        [self bureauButtonWithSymbol:@"command" title:@"Touches" action:@selector(bureauToggleKeys)],
        [self bureauButtonWithSymbol:@"doc.on.clipboard" title:@"Coller depuis l'iPhone" action:@selector(bureauPasteFromPhone)],
        [self bureauButtonWithSymbol:@"arrow.down.right.and.arrow.up.left" title:@"Zoom 100 %" action:@selector(bureauResetZoom)],
        _bureauMuteButton,
        _bureauDataButton,
        (_bureauRotationButton = [self bureauButtonWithSymbol:@"lock.rotation.open" title:@"Verrouiller l'orientation" action:@selector(bureauToggleOrientationLock)]),
        _bureauPinButton,
        [self bureauDisconnectButton],
    ];
    UIStackView *mainRow = [[UIStackView alloc] initWithArrangedSubviews:mainButtons];
    mainRow.axis = UILayoutConstraintAxisHorizontal;
    mainRow.spacing = 0;

    // Keys and shortcuts row (scrolls horizontally on narrow screens)
    NSArray *keys = @[
        @[@"Échap", @(BUREAU_VK_ESCAPE), @0], @[@"Tab", @(BUREAU_VK_TAB), @0], @[@"⊞", @(BUREAU_VK_LWIN), @0],
        @[@"←", @(BUREAU_VK_LEFT), @0], @[@"↑", @(BUREAU_VK_UP), @0], @[@"↓", @(BUREAU_VK_DOWN), @0], @[@"→", @(BUREAU_VK_RIGHT), @0],
        @[@"Entrée", @(BUREAU_VK_RETURN), @0], @[@"⌫", @(BUREAU_VK_BACK), @0], @[@"Suppr", @(BUREAU_VK_DELETE), @0],
        @[@"Copier", @('C'), @(MODIFIER_CTRL)], @[@"Coller", @('V'), @(MODIFIER_CTRL)], @[@"Couper", @('X'), @(MODIFIER_CTRL)],
        @[@"Annuler", @('Z'), @(MODIFIER_CTRL)], @[@"Tout", @('A'), @(MODIFIER_CTRL)], @[@"Rechercher", @('F'), @(MODIFIER_CTRL)],
        @[@"Alt+Tab", @(BUREAU_VK_TAB), @(MODIFIER_ALT)], @[@"Bureau", @('D'), @(MODIFIER_META)],
        @[@"Fermer", @(0x73), @(MODIFIER_ALT)], @[@"Gestionnaire", @(0x1B), @(MODIFIER_CTRL | MODIFIER_SHIFT)],
    ];
    UIStackView *keysStack = [[UIStackView alloc] init];
    keysStack.axis = UILayoutConstraintAxisHorizontal;
    keysStack.spacing = 2;
    keysStack.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSArray *key in keys) {
        UIButton *b = [self bureauButtonWithSymbol:nil title:key[0] action:@selector(bureauKeyButton:)];
        b.tag = ([key[1] intValue] & 0xFF) | ([key[2] intValue] << 8);
        [keysStack addArrangedSubview:b];
    }
    _bureauKeysRow = [[UIScrollView alloc] init];
    _bureauKeysRow.showsHorizontalScrollIndicator = NO;
    _bureauKeysRow.hidden = YES;
    [_bureauKeysRow addSubview:keysStack];
    [NSLayoutConstraint activateConstraints:@[
        [keysStack.leadingAnchor constraintEqualToAnchor:_bureauKeysRow.contentLayoutGuide.leadingAnchor],
        [keysStack.trailingAnchor constraintEqualToAnchor:_bureauKeysRow.contentLayoutGuide.trailingAnchor],
        [keysStack.topAnchor constraintEqualToAnchor:_bureauKeysRow.contentLayoutGuide.topAnchor],
        [keysStack.bottomAnchor constraintEqualToAnchor:_bureauKeysRow.contentLayoutGuide.bottomAnchor],
        [keysStack.heightAnchor constraintEqualToAnchor:_bureauKeysRow.frameLayoutGuide.heightAnchor],
        [_bureauKeysRow.heightAnchor constraintEqualToConstant:40],
    ]];

    UIStackView *rows = [[UIStackView alloc] initWithArrangedSubviews:@[mainRow, _bureauKeysRow]];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.alignment = UIStackViewAlignmentCenter;
    rows.spacing = 4;
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    [_bureauBar.contentView addSubview:rows];
    [NSLayoutConstraint activateConstraints:@[
        [rows.topAnchor constraintEqualToAnchor:_bureauBar.contentView.topAnchor constant:4],
        [rows.bottomAnchor constraintEqualToAnchor:_bureauBar.contentView.bottomAnchor constant:-4],
        [rows.leadingAnchor constraintEqualToAnchor:_bureauBar.contentView.leadingAnchor constant:6],
        [rows.trailingAnchor constraintEqualToAnchor:_bureauBar.contentView.trailingAnchor constant:-6],
        [_bureauKeysRow.widthAnchor constraintEqualToAnchor:rows.widthAnchor],
        [_bureauBar.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6],
        [_bureauBar.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [_bureauBar.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-16],
    ]];

    // Handle: always visible, small and translucent, shows/hides the toolbar
    _bureauHandle = [UIButton buttonWithType:UIButtonTypeSystem];
    _bureauHandle.translatesAutoresizingMaskIntoConstraints = NO;
    _bureauHandle.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    _bureauHandle.tintColor = [UIColor colorWithWhite:1 alpha:0.85];
    _bureauHandle.layer.cornerRadius = 12;
    _bureauHandle.accessibilityLabel = @"Barre d'outils";
    [_bureauHandle addTarget:self action:@selector(bureauToggleToolbar) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_bureauHandle];
    [NSLayoutConstraint activateConstraints:@[
        [_bureauHandle.widthAnchor constraintEqualToConstant:48],
        [_bureauHandle.heightAnchor constraintEqualToConstant:24],
        [_bureauHandle.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
    ]];
    // Two positions: under the toolbar when it is shown, at the top otherwise
    NSLayoutConstraint *handleTop = [_bureauHandle.topAnchor constraintEqualToAnchor:safe.topAnchor constant:2];
    handleTop.priority = UILayoutPriorityDefaultHigh;
    handleTop.active = YES;

    // Data used: a small pill under the handle, shown with the toolbar when chosen
    _bureauDataPill = [[UIView alloc] init];
    _bureauDataPill.translatesAutoresizingMaskIntoConstraints = NO;
    _bureauDataPill.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    _bureauDataPill.layer.cornerRadius = 10;
    _bureauDataPill.userInteractionEnabled = NO;
    _bureauDataPill.hidden = YES;
    _bureauDataLabel = [[UILabel alloc] init];
    _bureauDataLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _bureauDataLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    _bureauDataLabel.textColor = UIColor.whiteColor;
    _bureauDataLabel.numberOfLines = 0;
    _bureauDataLabel.textAlignment = NSTextAlignmentCenter;
    [_bureauDataPill addSubview:_bureauDataLabel];
    [self.view addSubview:_bureauDataPill];
    [NSLayoutConstraint activateConstraints:@[
        [_bureauDataLabel.topAnchor constraintEqualToAnchor:_bureauDataPill.topAnchor constant:6],
        [_bureauDataLabel.bottomAnchor constraintEqualToAnchor:_bureauDataPill.bottomAnchor constant:-6],
        [_bureauDataLabel.leadingAnchor constraintEqualToAnchor:_bureauDataPill.leadingAnchor constant:10],
        [_bureauDataLabel.trailingAnchor constraintEqualToAnchor:_bureauDataPill.trailingAnchor constant:-10],
        [_bureauDataPill.topAnchor constraintEqualToAnchor:_bureauHandle.bottomAnchor constant:6],
        [_bureauDataPill.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [_bureauDataPill.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-16],
    ]];
    [self bureauUpdateHandle];

    // Phone-side mute, remembered between sessions
    BureauSetAudioMuted([[NSUserDefaults standardUserDefaults] boolForKey:BUREAU_MUTED_KEY]);
    [self bureauRefreshMuteTile];

    // Data counter: first reading = starting point, then saved every 15 s and at the end
    [self bureauFlushDataUsage];
    _bureauDataTimer = [NSTimer scheduledTimerWithTimeInterval:15 target:self selector:@selector(bureauFlushDataUsage) userInfo:nil repeats:YES];
    [self bureauRefreshDataShown];

    // Two-finger drag = mouse wheel (vertical and horizontal), measured on screen
    UIPanGestureRecognizer *wheel = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(bureauWheel:)];
    wheel.minimumNumberOfTouches = 2;
    wheel.maximumNumberOfTouches = 2;
    wheel.cancelsTouchesInView = NO;
    wheel.delaysTouchesBegan = NO;
    wheel.delaysTouchesEnded = NO;
    wheel.delegate = (id<UIGestureRecognizerDelegate>)self;
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
    [self bureauRestartHideTimer];
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

// Shown only when chosen (button next to the title), remembered between sessions
- (void)bureauToggleDataShown {
    BOOL shown = ![[NSUserDefaults standardUserDefaults] boolForKey:BUREAU_SHOW_DATA_KEY];
    [[NSUserDefaults standardUserDefaults] setBool:shown forKey:BUREAU_SHOW_DATA_KEY];
    [self bureauRefreshDataShown];
    [UIView animateWithDuration:0.15 animations:^{
        [self.view layoutIfNeeded];
    }];
    [self bureauRestartHideTimer];
}

- (void)bureauRefreshDataShown {
    BOOL wanted = [[NSUserDefaults standardUserDefaults] boolForKey:BUREAU_SHOW_DATA_KEY];
    if (wanted && !_bureauBar.hidden) {
        _bureauDataLabel.text = [self bureauDataSummary];
        _bureauDataPill.hidden = NO;
        [self.view bringSubviewToFront:_bureauDataPill];
    } else {
        _bureauDataPill.hidden = YES;
    }
    [self bureauSetIcon:_bureauDataButton symbol:(wanted ? @"chart.bar.fill" : @"chart.bar")
                   tint:(wanted ? UIColor.systemCyanColor : UIColor.whiteColor)];
    _bureauDataButton.accessibilityLabel = wanted ? @"Masquer les données consommées" : @"Afficher les données consommées";
}

#pragma mark Two-finger wheel

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
        if (spread > 24 && spread > travel) {
            _bureauWheelMode = 2; // fingers move apart/together: zoom
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
            CGFloat zoom = _bureauWheelStartZoom * distance / _bureauWheelStartDistance;
            zoom = MAX(_scrollView.minimumZoomScale, MIN(_scrollView.maximumZoomScale, zoom));
            if (fabs(zoom - _scrollView.zoomScale) > 0.001) {
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
    // Composer pinned on top of the iOS keyboard (keyboardLayoutGuide, iOS 15+)
    _bureauComposer = [[UIView alloc] init];
    _bureauComposer.translatesAutoresizingMaskIntoConstraints = NO;
    _bureauComposer.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.96];
    _bureauComposer.hidden = YES;
    [self.view addSubview:_bureauComposer];

    UIButton *hideKeyboard = [self bureauButtonWithSymbol:@"keyboard.chevron.compact.down" title:@"Fermer le clavier" action:@selector(bureauHideComposer)];
    UIButton *backspace = [self bureauButtonWithSymbol:@"delete.left" title:@"Retour arrière sur le PC" action:@selector(bureauSendBackspace)];
    UIButton *enter = [self bureauButtonWithSymbol:@"return" title:@"Envoyer puis Entrée" action:@selector(bureauSendWithEnter)];
    UIButton *send = [self bureauButtonWithSymbol:@"paperplane.fill" title:@"Envoyer" action:@selector(bureauSendText)];

    _bureauTextView = [[UITextView alloc] init];
    _bureauTextView.backgroundColor = UIColor.clearColor;
    _bureauTextView.textColor = UIColor.whiteColor;
    _bureauTextView.tintColor = UIColor.whiteColor;
    _bureauTextView.font = [UIFont systemFontOfSize:17];
    _bureauTextView.keyboardAppearance = UIKeyboardAppearanceDark;
    _bureauTextView.scrollEnabled = YES;
    _bureauTextView.textContainerInset = UIEdgeInsetsMake(8, 0, 8, 0);
    _bureauTextView.delegate = (id<UITextViewDelegate>)self;
    if (@available(iOS 17.0, *)) {
        _bureauTextView.inlinePredictionType = UITextInlinePredictionTypeNo;
    }
    _bureauPlaceholder = [[UILabel alloc] init];
    _bureauPlaceholder.text = @"Envoyer du texte (Retour = nouvelle ligne)";
    _bureauPlaceholder.textColor = [UIColor colorWithWhite:1 alpha:0.4];
    _bureauPlaceholder.font = [UIFont systemFontOfSize:17];
    _bureauPlaceholder.translatesAutoresizingMaskIntoConstraints = NO;
    [_bureauTextView addSubview:_bureauPlaceholder];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[hideKeyboard, _bureauTextView, backspace, enter, send]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 4;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [_bureauComposer addSubview:row];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_bureauComposer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_bureauComposer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_bureauComposer.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [row.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:4],
        [row.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-4],
        [row.topAnchor constraintEqualToAnchor:_bureauComposer.topAnchor constant:4],
        [row.bottomAnchor constraintEqualToAnchor:_bureauComposer.bottomAnchor constant:-4],
        [_bureauTextView.heightAnchor constraintGreaterThanOrEqualToConstant:40],
        [_bureauTextView.heightAnchor constraintLessThanOrEqualToConstant:96],
        [_bureauPlaceholder.leadingAnchor constraintEqualToAnchor:_bureauTextView.leadingAnchor constant:5],
        [_bureauPlaceholder.topAnchor constraintEqualToAnchor:_bureauTextView.topAnchor constant:8],
    ]];
    [_bureauTextView setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
}

#pragma mark Toolbar visibility

- (void)bureauUpdateHandle {
    BOOL shown = !_bureauBar.hidden;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold];
    [_bureauHandle setImage:[UIImage systemImageNamed:(shown ? @"chevron.up" : @"chevron.down") withConfiguration:config]
                   forState:UIControlStateNormal];
    // Hidden toolbar: handle stays at the top. Shown: handle sits right under the toolbar.
    for (NSLayoutConstraint *c in self.view.constraints) {
        if (c.firstItem == _bureauHandle && c.firstAttribute == NSLayoutAttributeTop && c.secondItem == _bureauBar) {
            c.active = NO;
        }
    }
    if (shown) {
        [_bureauHandle.topAnchor constraintEqualToAnchor:_bureauBar.bottomAnchor constant:2].active = YES;
    }
    [self.view bringSubviewToFront:_bureauBar];
    [self.view bringSubviewToFront:_bureauHandle];
    [self.view bringSubviewToFront:_bureauComposer];
}

- (void)bureauToggleToolbar {
    [self bureauSetToolbarShown:_bureauBar.hidden];
}

- (void)bureauSetToolbarShown:(BOOL)shown {
    _bureauBar.hidden = !shown;
    [self bureauRefreshDataShown];
    if (!shown) {
        _bureauKeysRow.hidden = YES;
    }
    [UIView animateWithDuration:0.15 animations:^{
        [self bureauUpdateHandle];
        [self.view layoutIfNeeded];
    }];
    [self bureauRestartHideTimer];
}

- (void)bureauRestartHideTimer {
    [_bureauHideTimer invalidate];
    _bureauHideTimer = nil;
    if (!_bureauBar.hidden && !_bureauPinned) {
        _bureauHideTimer = [NSTimer scheduledTimerWithTimeInterval:BUREAU_AUTOHIDE_SECONDS
                                                            target:self
                                                          selector:@selector(bureauAutoHide)
                                                          userInfo:nil
                                                           repeats:NO];
    }
}

- (void)bureauAutoHide {
    if (!_bureauPinned) {
        [self bureauSetToolbarShown:NO];
    }
}

- (void)bureauTogglePin {
    _bureauPinned = !_bureauPinned;
    [self bureauSetIcon:_bureauPinButton symbol:(_bureauPinned ? @"pin.fill" : @"pin")
                   tint:(_bureauPinned ? UIColor.systemYellowColor : UIColor.whiteColor)];
    [self bureauRestartHideTimer];
}

- (void)bureauToggleKeys {
    _bureauKeysRow.hidden = !_bureauKeysRow.hidden;
    [UIView animateWithDuration:0.15 animations:^{
        [self.view layoutIfNeeded];
    }];
    [self bureauRestartHideTimer];
}

#pragma mark Actions

- (void)bureauResetZoom {
    [_scrollView setZoomScale:1.0 animated:YES];
    [self bureauRestartHideTimer];
}

// Confirmation against mis-taps
- (void)bureauDisconnect {
    [_bureauHideTimer invalidate];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Se déconnecter ?"
                                                                    message:@"La session sur le PC reste ouverte."
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [self bureauRestartHideTimer];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Déconnecter" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self returnToMainFrame];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)bureauKeyButton:(UIButton *)sender {
    short vk = sender.tag & 0xFF;
    char modifiers = (char)((sender.tag >> 8) & 0xFF);
    [self bureauSendKey:vk modifiers:modifiers];
    [self bureauRestartHideTimer];
}

- (void)bureauPasteFromPhone {
    NSString *text = UIPasteboard.generalPasteboard.string;
    if (text.length > 0) {
        [self bureauSendTextToPC:text];
    }
    [self bureauRestartHideTimer];
}

#pragma mark Composer

- (void)bureauShowComposer {
    [self bureauSetToolbarShown:NO];
    _bureauComposer.hidden = NO;
    [self.view bringSubviewToFront:_bureauComposer];
    [_bureauTextView becomeFirstResponder];
    [self.view setNeedsLayout];
}

- (void)bureauHideComposer {
    [_bureauTextView resignFirstResponder];
    _bureauComposer.hidden = YES;
    [self.view setNeedsLayout];
}

// Keyboard closed by any means (swipe, other app...): hide the composer too
- (void)textViewDidEndEditing:(UITextView *)textView {
    if (textView == _bureauTextView) {
        _bureauComposer.hidden = YES;
    }
}

- (void)textViewDidChange:(UITextView *)textView {
    if (textView == _bureauTextView) {
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
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
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
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
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
