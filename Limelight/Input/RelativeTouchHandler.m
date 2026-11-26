//
//  RelativeTouchHandler.m
//  Moonlight
//
//  Created by Cameron Gutman on 11/1/20.
//  Copyright © 2020 Moonlight Game Streaming Project. All rights reserved.
//

#import "RelativeTouchHandler.h"

#include <Limelight.h>

static const int REFERENCE_WIDTH = 1280;
static const int REFERENCE_HEIGHT = 720;

#if !TARGET_OS_TV
// Moonlight Bureau: the trackpad cursor is tracked here and sent as an absolute position,
// so the zoomed view can follow it and its speed doesn't depend on the host resolution.
// Finger movement is measured in StreamView points, which are already divided by the zoom
// scale: the cursor gets more precise when zoomed in. Gain goes from MIN (slow finger) to
// MAX (fast finger, ACCEL_POINTS or more per event).
static const CGFloat CURSOR_GAIN_MIN = 1.0;
static const CGFloat CURSOR_GAIN_MAX = 2.5;
static const CGFloat CURSOR_ACCEL_POINTS = 12.0;
#endif

@implementation RelativeTouchHandler {
#if !TARGET_OS_TV
    CGPoint cursorLocation;
    BOOL cursorKnown;
#endif
    CGPoint touchLocation, originalLocation;
    BOOL touchMoved;
    BOOL isDragging;
    NSTimer* dragTimer;
    NSUInteger peakTouchCount;
    
#if TARGET_OS_TV
    UIGestureRecognizer* remotePressRecognizer;
    UIGestureRecognizer* remoteLongPressRecognizer;
#endif
    
    StreamView* view;
}

- (id)initWithView:(StreamView*)view {
    self = [self init];
    self->view = view;
    
#if TARGET_OS_TV
    remotePressRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(remoteButtonPressed:)];
    remotePressRecognizer.allowedPressTypes = @[@(UIPressTypeSelect)];
    
    remoteLongPressRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(remoteButtonLongPressed:)];
    remoteLongPressRecognizer.allowedPressTypes = @[@(UIPressTypeSelect)];
    
    [self->view addGestureRecognizer:remotePressRecognizer];
    [self->view addGestureRecognizer:remoteLongPressRecognizer];
#endif
    
    return self;
}

#if !TARGET_OS_TV
- (void)moveCursorByX:(CGFloat)dx y:(CGFloat)dy {
    CGSize videoSize = [view getVideoAreaSize];
    if (videoSize.width < 1 || videoSize.height < 1) {
        return;
    }
    CGPoint origin = CGPointMake(view.bounds.size.width / 2 - videoSize.width / 2,
                                 view.bounds.size.height / 2 - videoSize.height / 2);

    // The host cursor position is unknown at the start: begin in the middle of the screen.
    if (!cursorKnown) {
        cursorLocation = CGPointMake(origin.x + videoSize.width / 2, origin.y + videoSize.height / 2);
        cursorKnown = YES;
    }

    CGFloat speed = MIN(hypot(dx, dy) / CURSOR_ACCEL_POINTS, 1.0);
    CGFloat gain = CURSOR_GAIN_MIN + (CURSOR_GAIN_MAX - CURSOR_GAIN_MIN) * speed;
    cursorLocation.x = MIN(MAX(cursorLocation.x + dx * gain, origin.x), origin.x + videoSize.width - 0.5);
    cursorLocation.y = MIN(MAX(cursorLocation.y + dy * gain, origin.y), origin.y + videoSize.height - 0.5);

    // Send in physical pixels rather than points so the host gets full precision
    CGFloat scale = view.window.screen.scale > 0 ? view.window.screen.scale : 1;
    LiSendMousePositionEvent((short)((cursorLocation.x - origin.x) * scale),
                             (short)((cursorLocation.y - origin.y) * scale),
                             (short)(videoSize.width * scale),
                             (short)(videoSize.height * scale));

    [[NSNotificationCenter defaultCenter] postNotificationName:@"MoonlightBureauCursorMoved"
                                                        object:nil
                                                      userInfo:@{@"point": [NSValue valueWithCGPoint:cursorLocation]}];
}
#endif

- (BOOL)isConfirmedMove:(CGPoint)currentPoint from:(CGPoint)originalPoint {
    // Movements of greater than 5 pixels are considered confirmed
    return hypotf(originalPoint.x - currentPoint.x, originalPoint.y - currentPoint.y) >= 5;
}

- (void)onDragStart:(NSTimer*)timer {
    if (!touchMoved && !isDragging){
        isDragging = true;
        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
    }
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    touchMoved = false;
    peakTouchCount = [[event allTouches] count];
    if ([[event allTouches] count] == 1) {
        UITouch *touch = [[event allTouches] anyObject];
        originalLocation = touchLocation = [touch locationInView:view];
        if (!isDragging) {
            dragTimer = [NSTimer scheduledTimerWithTimeInterval:0.650
                                                     target:self
                                                   selector:@selector(onDragStart:)
                                                   userInfo:nil
                                                    repeats:NO];
        }
    }
    else if ([[event allTouches] count] == 2) {
        CGPoint firstLocation = [[[[event allTouches] allObjects] objectAtIndex:0] locationInView:view];
        CGPoint secondLocation = [[[[event allTouches] allObjects] objectAtIndex:1] locationInView:view];
        
        originalLocation = touchLocation = CGPointMake((firstLocation.x + secondLocation.x) / 2, (firstLocation.y + secondLocation.y) / 2);
    }
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    if ([[event allTouches] count] == 1) {
        UITouch *touch = [[event allTouches] anyObject];
        CGPoint currentLocation = [touch locationInView:view];
        
#if !TARGET_OS_TV
        if (touchLocation.x != currentLocation.x ||
            touchLocation.y != currentLocation.y)
        {
            [self moveCursorByX:currentLocation.x - touchLocation.x y:currentLocation.y - touchLocation.y];
            touchLocation = currentLocation;
            if ([self isConfirmedMove:touchLocation from:originalLocation]) {
                touchMoved = true;
            }
        }
#else
        if (touchLocation.x != currentLocation.x ||
            touchLocation.y != currentLocation.y)
        {
            int deltaX = (currentLocation.x - touchLocation.x) * (REFERENCE_WIDTH / view.bounds.size.width);
            int deltaY = (currentLocation.y - touchLocation.y) * (REFERENCE_HEIGHT / view.bounds.size.height);
            
            if (deltaX != 0 || deltaY != 0) {
                LiSendMouseMoveEvent(deltaX, deltaY);
                touchLocation = currentLocation;
                
                // If we've moved far enough to confirm this wasn't just human/machine error,
                // mark it as such.
                if ([self isConfirmedMove:touchLocation from:originalLocation]) {
                    touchMoved = true;
                }
            }
        }
#endif
    } else if ([[event allTouches] count] == 2) {
        CGPoint firstLocation = [[[[event allTouches] allObjects] objectAtIndex:0] locationInView:view];
        CGPoint secondLocation = [[[[event allTouches] allObjects] objectAtIndex:1] locationInView:view];
        
        CGPoint avgLocation = CGPointMake((firstLocation.x + secondLocation.x) / 2, (firstLocation.y + secondLocation.y) / 2);
        if (touchLocation.y != avgLocation.y) {
            LiSendHighResScrollEvent((avgLocation.y - touchLocation.y) * 10);
        }

        // If we've moved far enough to confirm this wasn't just human/machine error,
        // mark it as such.
        if ([self isConfirmedMove:firstLocation from:originalLocation]) {
            touchMoved = true;
        }
        
        touchLocation = avgLocation;
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    [dragTimer invalidate];
    dragTimer = nil;
    if (isDragging) {
        isDragging = false;
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    } else if (!touchMoved) {
        if (peakTouchCount == 2) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                Log(LOG_D, @"Sending right mouse button press");
                
                LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_RIGHT);
                
                // Wait 100 ms to simulate a real button press
                usleep(100 * 1000);
                
                LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
            });
        } else if (peakTouchCount == 1) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                if (!self->isDragging){
                    Log(LOG_D, @"Sending left mouse button press");
                    
                    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
                    
                    // Wait 100 ms to simulate a real button press
                    usleep(100 * 1000);
                }
                self->isDragging = false;
                LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
            });
        }
    }
    
    // We we're moving from 2+ touches to 1. Synchronize the current position
    // of the active finger so we don't jump unexpectedly on the next touchesMoved
    // callback when finger 1 switches on us.
    if ([[event allTouches] count] - [touches count] == 1) {
        NSMutableSet *activeSet = [[NSMutableSet alloc] initWithCapacity:[[event allTouches] count]];
        [activeSet unionSet:[event allTouches]];
        [activeSet minusSet:touches];
        touchLocation = [[activeSet anyObject] locationInView:view];
        
        // Mark this touch as moved so we don't send a left mouse click if the user
        // right clicks without moving their other finger.
        touchMoved = true;
    }
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    [dragTimer invalidate];
    dragTimer = nil;
    if (isDragging) {
        isDragging = false;
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    }
    peakTouchCount = 0;
}

#if TARGET_OS_TV
- (void)remoteButtonPressed:(id)sender {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        Log(LOG_D, @"Sending left mouse button press");
        
        // Mark this as touchMoved to avoid a duplicate press on touch up
        self->touchMoved = true;
        
        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
        
        // Wait 100 ms to simulate a real button press
        usleep(100 * 1000);
            
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    });
}
- (void)remoteButtonLongPressed:(id)sender {
    Log(LOG_D, @"Holding left mouse button");
    
    isDragging = true;
    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
}
#endif

@end
