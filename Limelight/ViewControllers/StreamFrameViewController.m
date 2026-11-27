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

static NSString *const BUREAU_MUTED_KEY = @"MoonlightBureauMuted";
static NSString *const BUREAU_DATA_KEY = @"MoonlightBureauDataUsage";

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
    UIStackView *_bureauKeysRow;
    UIStackView *_bureauTilesBox;
    NSArray<UIButton *> *_bureauTiles;
    NSArray<UIButton *> *_bureauKeyChips;
    UILabel *_bureauDataLabel;
    UIButton *_bureauMuteButton;
    NSTimer *_bureauDataTimer;
    CGFloat _bureauGridWidth;
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
    UIButton *_bureauRotationButton;
#endif
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
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
    [_stageLabel setText:[NSString stringWithFormat:@"Starting %@...", self.streamConfig.appName]];
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
    [_tipLabel setText:@"Astuce : poignée en haut > bouton rouge pour se déconnecter"];
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
    if (_scrollView == nil || !_bureauCursorKnown || _scrollView.zoomScale <= 1.01f) {
        return;
    }
    CGPoint p = [_streamView convertPoint:_bureauCursor toView:_scrollView];
    CGSize visible = _scrollView.bounds.size;
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

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    // Stop the background timer, since we're foregrounded again
    if (_inactivityTimer != nil) {
        Log(LOG_I, @"Stopping inactivity timer after becoming active again");
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }
}

// This fires when the home button is pressed
- (void)applicationDidEnterBackground:(UIApplication *)application {
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
        NSString* lowerCase = [NSString stringWithFormat:@"%s in progress...", stageName];
        NSString* titleCase = [[[lowerCase substringToIndex:1] uppercaseString] stringByAppendingString:[lowerCase substringFromIndex:1]];
        [self->_stageLabel setText:titleCase];
        [self->_stageLabel sizeToFit];
        self->_stageLabel.center = CGPointMake(self.view.frame.size.width / 2, self->_stageLabel.center.y);
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
    NSString *rotationTitle = lock == 0 ? @"Rotation" : (lock == UIInterfaceOrientationMaskPortrait ? @"Vertical 🔒" : @"Paysage 🔒");
    [self bureauSetTile:_bureauRotationButton symbol:(lock != 0 ? @"lock.rotation" : @"lock.rotation.open")
                  title:rotationTitle color:(lock != 0 ? UIColor.systemYellowColor : UIColor.systemTealColor)];
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
    [self bureauLayoutGrid];
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

    // Panel: thick blur, rounded, top center; its grid adapts to portrait and landscape
    _bureauBar = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
    _bureauBar.translatesAutoresizingMaskIntoConstraints = NO;
    _bureauBar.layer.cornerRadius = 22;
    _bureauBar.layer.cornerCurve = kCACornerCurveContinuous;
    _bureauBar.clipsToBounds = YES;
    _bureauBar.hidden = YES;
    [self.view addSubview:_bureauBar];

    // Header: name + data used
    UILabel *title = [[UILabel alloc] init];
    title.text = @"Moonlight Bureau";
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    title.textColor = UIColor.whiteColor;
    _bureauDataLabel = [[UILabel alloc] init];
    _bureauDataLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    _bureauDataLabel.textColor = [UIColor colorWithWhite:1 alpha:0.65];
    _bureauDataLabel.numberOfLines = 0;
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[title, _bureauDataLabel]];
    header.axis = UILayoutConstraintAxisVertical;
    header.spacing = 2;

    // Main actions, as tiles (icon + label)
    _bureauPinButton = [self bureauTile:@"pin" title:@"Épingler" color:UIColor.systemGrayColor action:@selector(bureauTogglePin)];
    _bureauRotationButton = [self bureauTile:@"lock.rotation.open" title:@"Rotation" color:UIColor.systemTealColor action:@selector(bureauToggleOrientationLock)];
    _bureauMuteButton = [self bureauTile:@"speaker.wave.2.fill" title:@"Son" color:UIColor.systemGreenColor action:@selector(bureauToggleMute)];
    _bureauTiles = @[
        [self bureauTile:@"keyboard" title:@"Clavier" color:UIColor.systemBlueColor action:@selector(bureauShowComposer)],
        [self bureauTile:@"command" title:@"Raccourcis" color:UIColor.systemIndigoColor action:@selector(bureauToggleKeys)],
        [self bureauTile:@"doc.on.clipboard" title:@"Coller iPhone" color:UIColor.systemPurpleColor action:@selector(bureauPasteFromPhone)],
        [self bureauTile:@"arrow.down.right.and.arrow.up.left" title:@"Zoom 100 %" color:UIColor.systemOrangeColor action:@selector(bureauResetZoom)],
        _bureauMuteButton,
        _bureauRotationButton,
        _bureauPinButton,
        [self bureauTile:@"xmark.circle.fill" title:@"Quitter" color:UIColor.systemRedColor action:@selector(bureauDisconnect)],
    ];

    // Keys and shortcuts, as chips
    NSArray *keys = @[
        @[@"Copier", @('C'), @(MODIFIER_CTRL)], @[@"Coller", @('V'), @(MODIFIER_CTRL)], @[@"Couper", @('X'), @(MODIFIER_CTRL)],
        @[@"Annuler", @('Z'), @(MODIFIER_CTRL)], @[@"Tout sélect.", @('A'), @(MODIFIER_CTRL)], @[@"Rechercher", @('F'), @(MODIFIER_CTRL)],
        @[@"Échap", @(BUREAU_VK_ESCAPE), @0], @[@"Tab", @(BUREAU_VK_TAB), @0], @[@"Entrée", @(BUREAU_VK_RETURN), @0],
        @[@"Suppr", @(BUREAU_VK_DELETE), @0], @[@"⌫", @(BUREAU_VK_BACK), @0], @[@"⊞ Win", @(BUREAU_VK_LWIN), @0],
        @[@"←", @(BUREAU_VK_LEFT), @0], @[@"↑", @(BUREAU_VK_UP), @0], @[@"↓", @(BUREAU_VK_DOWN), @0], @[@"→", @(BUREAU_VK_RIGHT), @0],
        @[@"Alt+Tab", @(BUREAU_VK_TAB), @(MODIFIER_ALT)], @[@"Bureau", @('D'), @(MODIFIER_META)],
        @[@"Fermer", @(0x73), @(MODIFIER_ALT)], @[@"Gestionnaire", @(0x1B), @(MODIFIER_CTRL | MODIFIER_SHIFT)],
    ];
    NSMutableArray *chips = [NSMutableArray array];
    for (NSArray *key in keys) {
        UIButton *chip = [self bureauChip:key[0] action:@selector(bureauKeyButton:)];
        chip.tag = ([key[1] intValue] & 0xFF) | ([key[2] intValue] << 8);
        [chips addObject:chip];
    }
    _bureauKeyChips = chips;

    _bureauTilesBox = [[UIStackView alloc] init];
    _bureauTilesBox.axis = UILayoutConstraintAxisVertical;
    _bureauTilesBox.spacing = 8;
    _bureauKeysRow = [[UIStackView alloc] init];
    _bureauKeysRow.axis = UILayoutConstraintAxisVertical;
    _bureauKeysRow.spacing = 6;
    _bureauKeysRow.hidden = YES;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[header, _bureauTilesBox, _bureauKeysRow]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 12;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [_bureauBar.contentView addSubview:content];
    NSLayoutConstraint *maxWidth = [_bureauBar.widthAnchor constraintEqualToConstant:560];
    maxWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:_bureauBar.contentView.topAnchor constant:14],
        [content.bottomAnchor constraintEqualToAnchor:_bureauBar.contentView.bottomAnchor constant:-14],
        [content.leadingAnchor constraintEqualToAnchor:_bureauBar.contentView.leadingAnchor constant:14],
        [content.trailingAnchor constraintEqualToAnchor:_bureauBar.contentView.trailingAnchor constant:-14],
        [_bureauBar.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6],
        [_bureauBar.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [_bureauBar.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-16],
        maxWidth,
    ]];

    // Handle: always visible, small and translucent, shows/hides the panel
    _bureauHandle = [UIButton buttonWithType:UIButtonTypeSystem];
    _bureauHandle.translatesAutoresizingMaskIntoConstraints = NO;
    _bureauHandle.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    _bureauHandle.tintColor = [UIColor colorWithWhite:1 alpha:0.85];
    _bureauHandle.layer.cornerRadius = 12;
    _bureauHandle.accessibilityLabel = @"Menu";
    [_bureauHandle addTarget:self action:@selector(bureauToggleToolbar) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_bureauHandle];
    [NSLayoutConstraint activateConstraints:@[
        [_bureauHandle.widthAnchor constraintEqualToConstant:52],
        [_bureauHandle.heightAnchor constraintEqualToConstant:24],
        [_bureauHandle.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
    ]];
    NSLayoutConstraint *handleTop = [_bureauHandle.topAnchor constraintEqualToAnchor:safe.topAnchor constant:2];
    handleTop.priority = UILayoutPriorityDefaultHigh;
    handleTop.active = YES;
    [self bureauUpdateHandle];

    // Phone-side mute, remembered between sessions
    BureauSetAudioMuted([[NSUserDefaults standardUserDefaults] boolForKey:BUREAU_MUTED_KEY]);
    [self bureauRefreshMuteTile];

    // Data counter: saved every 15 s and when the stream closes
    _bureauDataTimer = [NSTimer scheduledTimerWithTimeInterval:15 target:self selector:@selector(bureauFlushDataUsage) userInfo:nil repeats:YES];

    // Two-finger drag = mouse wheel (vertical and horizontal), measured on screen
    UIPanGestureRecognizer *wheel = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(bureauWheel:)];
    wheel.minimumNumberOfTouches = 2;
    wheel.maximumNumberOfTouches = 2;
    wheel.cancelsTouchesInView = NO;
    wheel.delaysTouchesBegan = NO;
    wheel.delaysTouchesEnded = NO;
    wheel.delegate = (id<UIGestureRecognizerDelegate>)self;
    if (!_settings.absoluteTouchMode) {
        [_streamView addGestureRecognizer:wheel];
    }

    [self setupBureauComposer];
    [self bureauApplyOrientationLock];
    [self bureauLayoutGrid];
}

#pragma mark Menu building blocks

- (UIButton *)bureauTile:(NSString *)symbol title:(NSString *)title color:(UIColor *)color action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self bureauSetTile:button symbol:symbol title:title color:color];
    [button.heightAnchor constraintEqualToConstant:66].active = YES;
    return button;
}

- (void)bureauSetTile:(UIButton *)button symbol:(NSString *)symbol title:(NSString *)title color:(UIColor *)color {
    UIButtonConfiguration *c = [UIButtonConfiguration filledButtonConfiguration];
    c.image = [UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightSemibold]];
    c.imagePlacement = NSDirectionalRectEdgeTop;
    c.imagePadding = 6;
    c.baseBackgroundColor = [color colorWithAlphaComponent:0.24];
    c.baseForegroundColor = color;
    c.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    c.contentInsets = NSDirectionalEdgeInsetsMake(8, 2, 8, 2);
    c.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: UIColor.whiteColor,
    }];
    c.titleLineBreakMode = NSLineBreakByTruncatingTail;
    button.configuration = c;
    button.accessibilityLabel = title;
}

- (UIButton *)bureauChip:(NSString *)title action:(SEL)action {
    UIButtonConfiguration *c = [UIButtonConfiguration grayButtonConfiguration];
    c.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    c.baseForegroundColor = UIColor.whiteColor;
    c.contentInsets = NSDirectionalEdgeInsetsMake(6, 8, 6, 8);
    c.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold],
    }];
    UIButton *button = [UIButton buttonWithConfiguration:c primaryAction:nil];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:36].active = YES;
    return button;
}

// Lays the tiles and chips out in rows that fit the panel width (portrait: 4 tiles per row,
// landscape: 8). Rebuilt when the width changes.
- (void)bureauLayoutGrid {
    if (_bureauTilesBox == nil) {
        return;
    }
    CGFloat available = MIN(self.view.safeAreaLayoutGuide.layoutFrame.size.width - 16, 560) - 28;
    if (fabs(available - _bureauGridWidth) < 1) {
        return;
    }
    _bureauGridWidth = available;
    NSInteger tileColumns = available >= 8 * 58 ? 8 : 4;
    NSInteger chipColumns = MAX(3, MIN(6, (NSInteger)floor(available / 84)));
    [self bureauFill:_bureauTilesBox with:_bureauTiles columns:tileColumns spacing:8];
    [self bureauFill:_bureauKeysRow with:_bureauKeyChips columns:chipColumns spacing:6];
}

- (void)bureauFill:(UIStackView *)box with:(NSArray<UIButton *> *)items columns:(NSInteger)columns spacing:(CGFloat)spacing {
    for (UIView *row in [box.arrangedSubviews copy]) {
        [box removeArrangedSubview:row];
        [row removeFromSuperview];
    }
    for (NSInteger i = 0; i < (NSInteger)items.count; i += columns) {
        NSMutableArray *rowItems = [NSMutableArray array];
        for (NSInteger j = i; j < i + columns; j++) {
            if (j < (NSInteger)items.count) {
                [items[j] removeFromSuperview];
                [rowItems addObject:items[j]];
            } else {
                [rowItems addObject:[[UIView alloc] init]]; // keeps every column the same width
            }
        }
        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:rowItems];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.distribution = UIStackViewDistributionFillEqually;
        row.spacing = spacing;
        [box addArrangedSubview:row];
    }
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
    [self bureauSetTile:_bureauMuteButton
                 symbol:(muted ? @"speaker.slash.fill" : @"speaker.wave.2.fill")
                  title:(muted ? @"Son coupé" : @"Son")
                  color:(muted ? UIColor.systemRedColor : UIColor.systemGreenColor)];
}

#pragma mark Data used

// Received video + audio payloads, saved per hour (31 days kept). Network overhead and
// error correction are not counted: an estimate, a few % under the real mobile data.
- (void)bureauFlushDataUsage {
    unsigned long long bytes = BureauTakeReceivedBytes();
    if (bytes == 0) {
        return;
    }
    NSMutableDictionary *usage = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:BUREAU_DATA_KEY] mutableCopy] ?: [NSMutableDictionary dictionary];
    long long hour = (long long)floor([[NSDate date] timeIntervalSince1970] / 3600);
    NSString *key = [NSString stringWithFormat:@"%lld", hour];
    usage[key] = @([usage[key] unsignedLongLongValue] + bytes);
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
    unsigned long long day = 0, week = 0, month = 0;
    for (NSString *k in usage) {
        long long age = hour - [k longLongValue];
        unsigned long long v = [usage[k] unsignedLongLongValue];
        if (age < 24) day += v;
        if (age < 7 * 24) week += v;
        if (age < 30 * 24) month += v;
    }
    NSByteCountFormatter *f = [[NSByteCountFormatter alloc] init];
    f.countStyle = NSByteCountFormatterCountStyleDecimal;
    return [NSString stringWithFormat:@"Données ≈  24 h : %@  ·  7 j : %@  ·  30 j : %@",
            [f stringFromByteCount:(long long)day], [f stringFromByteCount:(long long)week], [f stringFromByteCount:(long long)month]];
}

#pragma mark Two-finger wheel

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)bureauWheel:(UIPanGestureRecognizer *)pan {
    // A pinch in progress zooms; it does not scroll
    UIGestureRecognizerState pinch = _scrollView.pinchGestureRecognizer.state;
    if (pinch == UIGestureRecognizerStateBegan || pinch == UIGestureRecognizerStateChanged) {
        [pan setTranslation:CGPointZero inView:nil];
        return;
    }
    if (pan.state != UIGestureRecognizerStateChanged) {
        return;
    }
    CGPoint t = [pan translationInView:nil];
    [pan setTranslation:CGPointZero inView:nil];
    // Content follows the fingers, like scrolling on iOS (120 = one wheel notch per ~12 points)
    short vertical = (short)MAX(MIN(t.y * 10, 32767), -32767);
    short horizontal = (short)MAX(MIN(-t.x * 10, 32767), -32767);
    if (vertical != 0 && fabs(t.y) >= fabs(t.x)) {
        LiSendHighResScrollEvent(vertical);
    }
    if (horizontal != 0 && fabs(t.x) > fabs(t.y)) {
        LiSendHighResHScrollEvent(horizontal);
    }
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
    if (shown) {
        _bureauDataLabel.text = [self bureauDataSummary];
        [self bureauLayoutGrid];
    }
    _bureauBar.hidden = !shown;
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
    [self bureauSetTile:_bureauPinButton symbol:(_bureauPinned ? @"pin.fill" : @"pin")
                  title:(_bureauPinned ? @"Épinglé" : @"Épingler")
                  color:(_bureauPinned ? UIColor.systemYellowColor : UIColor.systemGrayColor)];
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
}

- (void)bureauHideComposer {
    [_bureauTextView resignFirstResponder];
    _bureauComposer.hidden = YES;
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
    NSString *text = _bureauTextView.text ?: @"";
    _bureauTextView.text = @"";
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
@end

#import "SWRevealViewController.h"
@implementation SWRevealViewController (MoonlightBureauOrientation)
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return self.frontViewController ? self.frontViewController.supportedInterfaceOrientations : UIInterfaceOrientationMaskLandscape;
}
@end
#endif
