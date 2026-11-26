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
    
    [self.view addGestureRecognizer:_exitSwipeRecognizer];
#endif
    
    _tipLabel = [[UILabel alloc] init];
    [_tipLabel setUserInteractionEnabled:NO];
    
#if TARGET_OS_TV
    [_tipLabel setText:@"Tip: Tap the Play/Pause button on the Apple TV Remote to disconnect from your PC"];
#else
    [_tipLabel setText:@"Tip: Swipe from the left edge to disconnect from your PC"];
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
// Moonlight Bureau: in trackpad mode, pinch-zoom around the mouse cursor (not the pinch center):
// the cursor keeps the same place on screen while the scale changes.
- (void)scrollViewWillBeginZooming:(UIScrollView *)scrollView withView:(UIView *)view {
    _bureauZoomAnchored = NO;
    if (scrollView == _scrollView && !_settings.absoluteTouchMode && _bureauCursorKnown) {
        CGPoint p = [_streamView convertPoint:_bureauCursor toView:_scrollView];
        _bureauZoomAnchor = CGPointMake(p.x - _scrollView.contentOffset.x, p.y - _scrollView.contentOffset.y);
        _bureauZoomAnchored = YES;
    }
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    if (scrollView != _scrollView || !_bureauZoomAnchored) {
        return;
    }
    CGPoint p = [_streamView convertPoint:_bureauCursor toView:_scrollView];
    CGSize visible = _scrollView.bounds.size;
    CGFloat x = MIN(MAX(p.x - _bureauZoomAnchor.x, 0), MAX(_scrollView.contentSize.width - visible.width, 0));
    CGFloat y = MIN(MAX(p.y - _bureauZoomAnchor.y, 0), MAX(_scrollView.contentSize.height - visible.height, 0));
    _scrollView.contentOffset = CGPointMake(x, y);
}

- (void)scrollViewDidEndZooming:(UIScrollView *)scrollView withView:(UIView *)view atScale:(CGFloat)scale {
    _bureauZoomAnchored = NO;
}

// Moonlight Bureau: keep the trackpad cursor visible while zoomed, like Chrome Remote Desktop.
// The view only moves when the cursor gets within 20% of an edge.
- (void)trackpadCursorMoved:(NSNotification *)notification {
    CGPoint cursor = [[notification.userInfo objectForKey:@"point"] CGPointValue];
    _bureauCursor = cursor;
    _bureauCursorKnown = YES;
    if (_scrollView == nil || _scrollView.zoomScale <= 1.01f) {
        return;
    }

    CGPoint p = [_streamView convertPoint:cursor toView:_scrollView];
    CGSize visible = _scrollView.bounds.size;
    CGPoint offset = _scrollView.contentOffset;
    CGFloat marginX = visible.width * 0.2f;
    CGFloat marginY = visible.height * 0.2f;
    CGFloat x = offset.x, y = offset.y;

    if (p.x < offset.x + marginX) {
        x = p.x - marginX;
    } else if (p.x > offset.x + visible.width - marginX) {
        x = p.x - visible.width + marginX;
    }
    if (p.y < offset.y + marginY) {
        y = p.y - marginY;
    } else if (p.y > offset.y + visible.height - marginY) {
        y = p.y - visible.height + marginY;
    }

    x = MIN(MAX(x, 0), MAX(_scrollView.contentSize.width - visible.width, 0));
    y = MIN(MAX(y, 0), MAX(_scrollView.contentSize.height - visible.height, 0));
    if (x != offset.x || y != offset.y) {
        [_scrollView setContentOffset:CGPointMake(x, y) animated:NO];
    }
}
#endif

- (void)willMoveToParentViewController:(UIViewController *)parent {
    // Only cleanup when we're being destroyed
    if (parent == nil) {
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
    NSArray<UIButton *> *mainButtons = @[
        [self bureauButtonWithSymbol:@"keyboard" title:@"Clavier" action:@selector(bureauShowComposer)],
        [self bureauButtonWithSymbol:@"command" title:@"Touches" action:@selector(bureauToggleKeys)],
        [self bureauButtonWithSymbol:@"doc.on.clipboard" title:@"Coller depuis l'iPhone" action:@selector(bureauPasteFromPhone)],
        [self bureauButtonWithSymbol:@"arrow.down.right.and.arrow.up.left" title:@"Zoom 100 %" action:@selector(bureauResetZoom)],
        _bureauPinButton,
        [self bureauDisconnectButton],
    ];
    UIStackView *mainRow = [[UIStackView alloc] initWithArrangedSubviews:mainButtons];
    mainRow.axis = UILayoutConstraintAxisHorizontal;
    mainRow.spacing = 2;

    // Keys and shortcuts row (scrolls horizontally on narrow screens)
    NSArray *keys = @[
        @[@"Échap", @(BUREAU_VK_ESCAPE), @0], @[@"Tab", @(BUREAU_VK_TAB), @0], @[@"⊞", @(BUREAU_VK_LWIN), @0],
        @[@"←", @(BUREAU_VK_LEFT), @0], @[@"↑", @(BUREAU_VK_UP), @0], @[@"↓", @(BUREAU_VK_DOWN), @0], @[@"→", @(BUREAU_VK_RIGHT), @0],
        @[@"Suppr", @(BUREAU_VK_DELETE), @0],
        @[@"Copier", @('C'), @(MODIFIER_CTRL)], @[@"Coller", @('V'), @(MODIFIER_CTRL)], @[@"Couper", @('X'), @(MODIFIER_CTRL)],
        @[@"Annuler", @('Z'), @(MODIFIER_CTRL)], @[@"Tout", @('A'), @(MODIFIER_CTRL)],
        @[@"Alt+Tab", @(BUREAU_VK_TAB), @(MODIFIER_ALT)], @[@"Bureau", @('D'), @(MODIFIER_META)],
        @[@"Gestionnaire", @(0x1B), @(MODIFIER_CTRL | MODIFIER_SHIFT)],
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
    [self bureauUpdateHandle];

    [self setupBureauComposer];
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
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium];
    [_bureauPinButton setImage:[UIImage systemImageNamed:(_bureauPinned ? @"pin.fill" : @"pin") withConfiguration:config]
                      forState:UIControlStateNormal];
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

- (UIButton *)bureauDisconnectButton {
    UIButton *button = [self bureauButtonWithSymbol:@"xmark.circle.fill" title:@"Déconnecter" action:@selector(bureauDisconnect)];
    button.tintColor = UIColor.systemRedColor;
    return button;
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
    LiSendKeyboardEvent(0x8000 | vk, KEY_ACTION_DOWN, modifiers);
    usleep(30 * 1000);
    LiSendKeyboardEvent(0x8000 | vk, KEY_ACTION_UP, modifiers);
    for (int i = 3; i >= 0; i--) {
        if (modifiers & modifierFlags[i]) {
            held &= ~modifierFlags[i];
            LiSendKeyboardEvent(0x8000 | modifierKeys[i], KEY_ACTION_UP, held);
        }
    }
}
#endif

@end
