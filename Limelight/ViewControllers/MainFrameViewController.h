//
//  MainFrameViewController.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/17/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "DiscoveryManager.h"
#import "PairManager.h"
#import "StreamConfiguration.h"
#import "UIComputerView.h"
#import "UIAppView.h"
#import "AppAssetManager.h"
#import "SWRevealViewController.h"

@interface MainFrameViewController : UICollectionViewController <DiscoveryCallback, PairCallback, HostCallback, AppCallback, AppAssetCallback, NSURLConnectionDelegate, SWRevealViewControllerDelegate>

@property (weak, nonatomic) IBOutlet UIBarButtonItem *settingsButton;
#if !TARGET_OS_TV
@property (weak, nonatomic) IBOutlet UIBarButtonItem *upButton;
#endif

#if !TARGET_OS_TV
// Moonlight Bureau: reconnect when the app comes back from the background
+ (void)bureauRequestResume;
+ (void)bureauCancelResume;

// Data mode: on mobile data (or iOS Low Data Mode), 60 images/s and a lower bitrate ceiling
+ (void)bureauStartNetworkWatch;
+ (BOOL)bureauOnMobileData;
+ (BOOL)bureauDataModeOffByUser;
+ (void)bureauSetDataModeOffByUser:(BOOL)off;
+ (BOOL)bureauSessionInDataMode;
+ (int)bureauDataModeBitrate;

// Home-screen action "Fermer la session du PC", shown only while a session is open
+ (void)bureauUpdateQuitShortcut:(BOOL)sessionOpen;
+ (void)bureauQuitSessionFromShortcut;
#endif

@end
