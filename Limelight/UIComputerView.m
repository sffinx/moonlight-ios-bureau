//
//  UIComputerView.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/22/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "UIComputerView.h"

@implementation UIComputerView {
    TemporaryHost* _host;
    UIImageView* _hostIcon;
    UILabel* _hostLabel;
    UIImageView* _hostOverlay;
    UIActivityIndicatorView* _hostSpinner;
    id<HostCallback> _callback;
    CGSize _labelSize;
#if !TARGET_OS_TV
    // Moonlight Bureau: card look (rounded tile, SF Symbol, status line)
    UIView* _card;
    UILabel* _statusLabel;
    UIView* _statusDot;
#endif
}

#if !TARGET_OS_TV
static const CGFloat BUREAU_CARD_W = 150;
static const CGFloat BUREAU_CARD_H = 150;
#endif
static const float REFRESH_CYCLE = 2.0f;

#if TARGET_OS_TV
static const int ITEM_PADDING = 50;
static const int LABEL_DY = 40;
#else
static const int ITEM_PADDING = 0;
static const int LABEL_DY = 20;
#endif

- (id) init {
    self = [super init];
        
#if !TARGET_OS_TV
    if (YES) {
        return [self bureauInitCard];
    }
#endif

#if TARGET_OS_TV
    self.frame = CGRectMake(0, 0, 400, 400);
#else
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        self.frame = CGRectMake(0, 0, 200, 200);
    } else {
        self.frame = CGRectMake(0, 0, 100, 100);
    }
#endif
    
    _hostIcon = [[UIImageView alloc] initWithFrame:self.frame];
    [_hostIcon setImage:[UIImage imageNamed:@"Computer"]];
    
    self.layer.shadowColor = [[UIColor blackColor] CGColor];
    self.layer.shadowOffset = CGSizeMake(5,8);
    self.layer.shadowOpacity = 0.3;

    [self addTarget:self action:@selector(hostButtonSelected:) forControlEvents:UIControlEventTouchDown];
    [self addTarget:self action:@selector(hostButtonDeselected:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
    
    _hostLabel = [[UILabel alloc] init];
    _hostLabel.textColor = [UIColor whiteColor];
    
    _hostOverlay = [[UIImageView alloc] initWithFrame:CGRectMake(self.frame.size.width / 3, _hostIcon.frame.size.height / 4, _hostIcon.frame.size.width / 3, self.frame.size.height / 3)];
    _hostSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    [_hostSpinner setFrame:_hostOverlay.frame];
    _hostSpinner.userInteractionEnabled = NO;
    _hostSpinner.hidesWhenStopped = YES;

    [self addSubview:_hostLabel];
    [self addSubview:_hostIcon];
    
#if TARGET_OS_TV
    _hostIcon.clipsToBounds = NO;
    _hostIcon.adjustsImageWhenAncestorFocused = YES;
    _hostIcon.masksFocusEffectToContents = YES;
    
    self.adjustsImageWhenHighlighted = NO;
    
    _hostOverlay.masksFocusEffectToContents = YES;
    _hostOverlay.adjustsImageWhenAncestorFocused = NO;
    
    [_hostIcon.overlayContentView addSubview:_hostOverlay];
    [_hostIcon.overlayContentView addSubview:_hostSpinner];
#else
    [self addSubview:_hostOverlay];
    [self addSubview:_hostSpinner];
    
    if (@available(iOS 13.4.1, *)) {
        // Allow the button style to change when moused over
        self.pointerInteractionEnabled = YES;
    }
#endif
    
    return self;
}

#if !TARGET_OS_TV
- (id) bureauInitCard {
    self.frame = CGRectMake(0, 0, BUREAU_CARD_W, BUREAU_CARD_H);

    _card = [[UIView alloc] initWithFrame:self.bounds];
    _card.userInteractionEnabled = NO;
    _card.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    _card.layer.cornerRadius = 24;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.layer.borderWidth = 1;
    _card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
    [self addSubview:_card];

    _hostIcon = [[UIImageView alloc] initWithFrame:CGRectMake(0, 22, BUREAU_CARD_W, 56)];
    _hostIcon.contentMode = UIViewContentModeCenter;
    _hostIcon.tintColor = UIColor.whiteColor;
    _hostIcon.image = [UIImage systemImageNamed:@"desktopcomputer"
                              withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:46 weight:UIImageSymbolWeightRegular]];
    [self addSubview:_hostIcon];

    _hostLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 88, BUREAU_CARD_W - 20, 22)];
    _hostLabel.textColor = UIColor.whiteColor;
    _hostLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _hostLabel.textAlignment = NSTextAlignmentCenter;
    _hostLabel.adjustsFontSizeToFitWidth = YES;
    _hostLabel.minimumScaleFactor = 0.7;
    [self addSubview:_hostLabel];

    _statusDot = [[UIView alloc] initWithFrame:CGRectZero];
    _statusDot.layer.cornerRadius = 4;
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _statusLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    [self addSubview:_statusDot];
    [self addSubview:_statusLabel];

    _hostOverlay = [[UIImageView alloc] init]; // unused on iOS, kept for shared code
    _hostSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _hostSpinner.color = UIColor.whiteColor;
    _hostSpinner.center = CGPointMake(BUREAU_CARD_W - 22, 22);
    _hostSpinner.userInteractionEnabled = NO;
    _hostSpinner.hidesWhenStopped = YES;
    [self addSubview:_hostSpinner];

    [self addTarget:self action:@selector(hostButtonSelected:) forControlEvents:UIControlEventTouchDown];
    [self addTarget:self action:@selector(hostButtonDeselected:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
    if (@available(iOS 13.4.1, *)) {
        self.pointerInteractionEnabled = YES;
    }
    return self;
}

- (void) bureauSetStatus:(NSString*)text color:(UIColor*)color {
    _statusLabel.text = text;
    [_statusLabel sizeToFit];
    _statusDot.backgroundColor = color;
    _statusDot.hidden = color == nil;
    CGFloat dot = color == nil ? 0 : 8 + 6;
    CGFloat width = dot + _statusLabel.frame.size.width;
    CGFloat x = (BUREAU_CARD_W - width) / 2;
    _statusDot.frame = CGRectMake(x, 120, 8, 8);
    _statusLabel.frame = CGRectMake(x + dot, 124 - _statusLabel.frame.size.height / 2, _statusLabel.frame.size.width, _statusLabel.frame.size.height);
}
#endif

- (void) hostButtonSelected:(id)sender {
#if !TARGET_OS_TV
    [UIView animateWithDuration:0.1 animations:^{
        self->_card.transform = CGAffineTransformMakeScale(0.96, 0.96);
        self->_card.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    }];
#endif
    _hostIcon.layer.opacity = 0.5f;
    _hostSpinner.layer.opacity = 0.5f;
    _hostOverlay.layer.opacity = 0.5f;
}
- (void) hostButtonDeselected:(id)sender {
#if !TARGET_OS_TV
    [UIView animateWithDuration:0.15 animations:^{
        self->_card.transform = CGAffineTransformIdentity;
        self->_card.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    }];
#endif
    _hostIcon.layer.opacity = 1.0f;
    _hostSpinner.layer.opacity = 1.0f;
    _hostOverlay.layer.opacity = 1.0f;
}

- (id) initForAddWithCallback:(id<HostCallback>)callback {
    self = [self init];
    _callback = callback;
    
    [self addTarget:self action:@selector(addClicked) forControlEvents:UIControlEventPrimaryActionTriggered];
    
#if !TARGET_OS_TV
    _hostLabel.text = @"Ajouter un PC";
    _hostIcon.image = [UIImage systemImageNamed:@"plus.circle"
                              withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:42 weight:UIImageSymbolWeightLight]];
    _hostIcon.tintColor = [UIColor colorWithWhite:1 alpha:0.7];
    _card.backgroundColor = UIColor.clearColor;
    _card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    [self bureauSetStatus:@"Adresse IP" color:nil];
    if (YES) {
        return self;
    }
#endif
    [_hostLabel setText:@"Add Host Manually"];
    [_hostLabel sizeToFit];

    [_hostOverlay setImage:[UIImage imageNamed:@"AddOverlayIcon"]];

    [self updateBounds];
        
    return self;
}

- (id) initWithComputer:(TemporaryHost*)host andCallback:(id<HostCallback>)callback {
    self = [self init];
    _host = host;
    _callback = callback;
    
    // Use UIContextMenuInteraction on iOS 13.0+ and a standard UILongPressGestureRecognizer
    // for tvOS devices and iOS prior to 13.0.
#if !TARGET_OS_TV
    if (@available(iOS 13.0, *)) {
        UIContextMenuInteraction* rightClickInteraction = [[UIContextMenuInteraction alloc] initWithDelegate:self];
        [self addInteraction:rightClickInteraction];
    }
    else
#endif
    {
        UILongPressGestureRecognizer* longPressRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(hostLongClicked:)];
        [self addGestureRecognizer:longPressRecognizer];
    }
    
    [self addTarget:self action:@selector(hostClicked) forControlEvents:UIControlEventPrimaryActionTriggered];
    
    [self updateContentsForHost:host];

    return self;
}

- (void)didMoveToSuperview {
    // Start our update loop when we are added to our cell
    if (self.superview != nil && _host != nil) {
        [self updateLoop];
    }
}

- (void) updateBounds {
    float x = FLT_MAX;
    float y = FLT_MAX;
    float width = 0;
    float height;
    
    float iconX = _hostIcon.frame.origin.x + _hostIcon.frame.size.width / 2;
    _hostLabel.center = CGPointMake(iconX, _hostIcon.frame.origin.y + _hostIcon.frame.size.height + LABEL_DY);
    
    x = MIN(x, _hostIcon.frame.origin.x);
    x = MIN(x, _hostLabel.frame.origin.x);
    
    y = MIN(y, _hostIcon.frame.origin.y);
    y = MIN(y, _hostLabel.frame.origin.y);

    width = MAX(width, _hostIcon.frame.size.width);
    width = MAX(width, _hostLabel.frame.size.width);
    
    height = _hostIcon.frame.size.height +
        _hostLabel.frame.size.height +
        LABEL_DY / 2;
    
    self.bounds = CGRectMake(x - ITEM_PADDING, y - ITEM_PADDING, width + 2 * ITEM_PADDING, height + 2 * ITEM_PADDING);
}

- (void) updateContentsForHost:(TemporaryHost*)host {
#if !TARGET_OS_TV
    _hostLabel.text = _host.name;
    if (host.state == StateOnline) {
        [_hostSpinner stopAnimating];
        if (host.pairState == PairStateUnpaired) {
            [self bureauSetStatus:@"Non appairé" color:UIColor.systemOrangeColor];
        } else {
            [self bureauSetStatus:@"En ligne" color:UIColor.systemGreenColor];
        }
        _hostIcon.tintColor = UIColor.whiteColor;
    }
    else if (host.state == StateOffline) {
        [_hostSpinner stopAnimating];
        [self bureauSetStatus:@"Hors ligne" color:UIColor.systemGrayColor];
        _hostIcon.tintColor = [UIColor colorWithWhite:1 alpha:0.45];
    }
    else {
        [_hostSpinner startAnimating];
        [self bureauSetStatus:@"Recherche…" color:nil];
    }
    if (YES) {
        return;
    }
#endif
    _hostLabel.text = _host.name;
    [_hostLabel sizeToFit];
    
    if (host.state == StateOnline) {
        [_hostSpinner stopAnimating];

        if (host.pairState == PairStateUnpaired) {
            [_hostOverlay setImage:[UIImage imageNamed:@"LockedOverlayIcon"]];
        }
        else {
            [_hostOverlay setImage:nil];
        }
    }
    else if (host.state == StateOffline) {
        [_hostSpinner stopAnimating];
        [_hostOverlay setImage:[UIImage imageNamed:@"ErrorOverlayIcon"]];
    }
    else {
        [_hostSpinner startAnimating];
    }
    
    [self updateBounds];
}

- (void) updateLoop {
    // Stop immediately if the view has been detached
    if (self.superview == nil) {
        return;
    }
    
    [self updateContentsForHost:_host];
    
    // Queue the next refresh cycle
    [self performSelector:@selector(updateLoop) withObject:self afterDelay:REFRESH_CYCLE];
}

- (void) hostLongClicked:(UILongPressGestureRecognizer*)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [_callback hostLongClicked:_host view:self];
    }
}

#if !TARGET_OS_TV
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                        configurationForMenuAtLocation:(CGPoint)location {
    // We don't want to trigger the primary action at this point, so cancel
    // tracking touch on this view now. This will also have the (intended)
    // effect of removing the touch highlight on this view.
    [self cancelTrackingWithEvent:nil];
    
    [_callback hostLongClicked:_host view:self];
    return nil;
}
#endif

- (void) hostClicked {
    [_callback hostClicked:_host view:self];
}

- (void) addClicked {
    [_callback addHostClicked];
}

@end
