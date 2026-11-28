//
//  RelativeTouchHandler.h
//  Moonlight
//
//  Created by Cameron Gutman on 11/1/20.
//  Copyright © 2020 Moonlight Game Streaming Project. All rights reserved.
//

#import "StreamView.h"

NS_ASSUME_NONNULL_BEGIN

@interface RelativeTouchHandler : UIResponder

-(id)initWithView:(StreamView*)view;

#if !TARGET_OS_TV
// Moonlight Bureau: places the PC cursor where the trackpad believes it is (center at first),
// so the first finger movement does not make it jump across the screen
- (void)bureauSyncCursor;

// YES while one finger drives the cursor: a second finger must not start the wheel or zoom
extern BOOL BureauTrackpadSingleFingerLock;
#endif

@end

NS_ASSUME_NONNULL_END
