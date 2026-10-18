// Double-Click: a helper for the power button.
//
//  1. Double tap to unlock: double tap empty space on the Lock Screen and the unlock screen opens
//     (the same as pressing the Home button). With a passcode or Touch ID it only brings up the
//     prompt; authentication is never skipped.
//  2. Double tap to sleep: double tap the status bar, or empty space on the Home Screen, and the
//     screen turns off (the same as pressing the power button).
//
// SpringBoard handles both. Inside apps a tiny hook only watches for a double tap on the status
// bar and tells SpringBoard, because app touches never reach SpringBoard.

#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define DC_DOMAIN CFSTR("com.kwarnu.doubleclick")
#define DC_PLIST_PATH @"/var/mobile/Library/Preferences/com.kwarnu.doubleclick.plist"
#define DC_NOTIFY_PREFS "com.kwarnu.doubleclick/prefschanged"
#define DC_NOTIFY_SLEEP "com.kwarnu.doubleclick/sleep"          // test button in Settings
#define DC_NOTIFY_APP_SLEEP "com.kwarnu.doubleclick/appsleep"   // status bar double tap inside an app
#define DC_NOTIFY_RESPRING "com.kwarnu.doubleclick/respring"

static BOOL gIsSpringBoard;

#pragma mark - Settings

typedef struct {
    BOOL enabled;
    BOOL unlock;           // double tap the Lock Screen to unlock
    BOOL sleep;            // double tap to sleep
    BOOL sleepStatusBar;   // ... on the status bar
    BOOL sleepEmpty;       // ... on empty space of the Home Screen
    BOOL haptic;
    NSInteger speedMs;     // maximum gap between the two taps
} DCConfig;

static DCConfig cfg = {
    .enabled = YES, .unlock = YES, .sleep = YES, .sleepStatusBar = YES, .sleepEmpty = YES,
    .haptic = YES, .speedMs = 350,
};

static NSDictionary *gFileFallback;

static id DCPref(NSString *key) {
    id value = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, DC_DOMAIN));
    return value ?: gFileFallback[key];
}

static BOOL DCBool(NSString *key, BOOL fallback) {
    id v = DCPref(key);
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : fallback;
}

static NSInteger DCInt(NSString *key, NSInteger fallback, NSInteger lo, NSInteger hi) {
    id v = DCPref(key);
    NSInteger n = [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : fallback;
    return n < lo ? lo : (n > hi ? hi : n);
}

static void DCLoadConfig(void) {
    CFPreferencesAppSynchronize(DC_DOMAIN);
    gFileFallback = [NSDictionary dictionaryWithContentsOfFile:DC_PLIST_PATH];   // for sandboxed apps
    DCConfig c = cfg;
    c.enabled = DCBool(@"enabled", YES);
    c.unlock = DCBool(@"unlock", YES);
    c.sleep = DCBool(@"sleep", YES);
    c.sleepStatusBar = DCBool(@"sleepStatusBar", YES);
    c.sleepEmpty = DCBool(@"sleepEmpty", YES);
    c.haptic = DCBool(@"haptic", YES);
    c.speedMs = DCInt(@"speedMs", 350, 200, 800);
    cfg = c;
}

#pragma mark - Runtime helpers (private classes are looked up by name and always guarded)

static id DCShared(const char *className, NSString *selector) {
    Class cls = objc_getClass(className);
    SEL sel = NSSelectorFromString(selector);
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, sel);
}

static BOOL DCScreenOn(void) {
    id backlight = DCShared("SBBacklightController", @"sharedInstance");
    SEL sel = NSSelectorFromString(@"screenIsOn");
    if (backlight && [backlight respondsToSelector:sel]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(backlight, sel);
    }
    return YES;
}

static void DCHaptic(void) {
    if (cfg.haptic) AudioServicesPlaySystemSound(1519);
}

#pragma mark - Actions (SpringBoard)

// Same effect as pressing the power button while the screen is on.
static void DCSleepScreen(void) {
    UIApplication *app = UIApplication.sharedApplication;
    SEL lockButton = NSSelectorFromString(@"_simulateLockButtonPress");
    if ([app respondsToSelector:lockButton]) {
        ((void (*)(id, SEL))objc_msgSend)(app, lockButton);
        return;
    }
    id manager = DCShared("SBLockScreenManager", @"sharedInstance");
    SEL lockUI = NSSelectorFromString(@"lockUIFromSource:withOptions:");
    if (manager && [manager respondsToSelector:lockUI]) {
        ((void (*)(id, SEL, long long, id))objc_msgSend)(manager, lockUI, 1, nil);
        return;
    }
    id agent = DCShared("SBUserAgent", @"sharedUserAgent");
    SEL lockDim = NSSelectorFromString(@"lockAndDimDevice");
    if (agent && [agent respondsToSelector:lockDim]) {
        ((void (*)(id, SEL))objc_msgSend)(agent, lockDim);
    }
}

// Same effect as pressing the Home button on the Lock Screen: opens the Home Screen when there is no
// passcode, otherwise shows the passcode / Touch ID prompt. It never skips authentication.
static void DCUnlockScreen(void) {
    UIApplication *app = UIApplication.sharedApplication;
    SEL homeButton = NSSelectorFromString(@"_simulateHomeButtonPress");
    if ([app respondsToSelector:homeButton]) {
        ((void (*)(id, SEL))objc_msgSend)(app, homeButton);
        return;
    }
    id manager = DCShared("SBLockScreenManager", @"sharedInstance");
    SEL unlockUI = NSSelectorFromString(@"unlockUIFromSource:withOptions:");
    if (manager && [manager respondsToSelector:unlockUI]) {
        ((void (*)(id, SEL, long long, id))objc_msgSend)(manager, unlockUI, 1, nil);
    }
}

static BOOL DCRateLimited(void) {
    static CFTimeInterval last;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - last < 1.0) return YES;   // one action per second at most
    last = now;
    return NO;
}

static void DCDoSleep(void) {
    if (!DCScreenOn() || DCRateLimited()) return;
    DCHaptic();
    DCSleepScreen();
}

static void DCDoUnlock(void) {
    if (!DCScreenOn() || DCRateLimited()) return;
    DCHaptic();
    DCUnlockScreen();
}

static void DCRespring(void) {
    id service = DCShared("FBSystemService", @"sharedInstance");
    SEL sel = NSSelectorFromString(@"exitAndRelaunch:");
    if (service && [service respondsToSelector:sel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(service, sel, YES);
        return;
    }
    exit(0);
}

#pragma mark - Where did the double tap land?

typedef NS_ENUM(NSInteger, DCZone) {
    DCZoneNone = 0,
    DCZoneStatusBar,
    DCZoneHomeEmpty,
    DCZoneLockEmpty,
};

static BOOL DCNameContains(NSString *name, NSArray<NSString *> *needles) {
    for (NSString *needle in needles) {
        if ([name rangeOfString:needle].location != NSNotFound) return YES;
    }
    return NO;
}

static CGFloat DCStatusBarHeight(void) {
    SEL sel = NSSelectorFromString(@"statusBarFrame");
    UIApplication *app = UIApplication.sharedApplication;
    if (![app respondsToSelector:sel]) return 0;
    CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(app, sel);
    return frame.size.height;
}

// YES while the passcode pad is on screen. A double tap there must never act as "unlock", because
// a quick press of the same digit twice is a double tap too.
static BOOL DCPasscodeVisibleInView(UIView *view, int depth) {
    if (depth > 14 || view.hidden || view.alpha < 0.01) return NO;
    NSString *name = NSStringFromClass(view.class);
    if ([name rangeOfString:@"PasscodeLockView"].location != NSNotFound ||
        [name rangeOfString:@"PasscodeNumberPad"].location != NSNotFound ||
        [name rangeOfString:@"PasscodeKeypad"].location != NSNotFound) return YES;
    for (UIView *sub in view.subviews) {
        if (DCPasscodeVisibleInView(sub, depth + 1)) return YES;
    }
    return NO;
}

static BOOL DCPasscodeVisible(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (DCPasscodeVisibleInView(window, 0)) return YES;
    }
    return NO;
}

static BOOL DCIsLocked(void) {
    id manager = DCShared("SBLockScreenManager", @"sharedInstance");
    SEL sel = NSSelectorFromString(@"isUILocked");
    if (manager && [manager respondsToSelector:sel]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(manager, sel);
    }
    return NO;
}

// Walks up from the touched view. Icons, buttons, widgets, notifications, the passcode pad and any
// other control are never a double tap zone, so normal taps are never hijacked.
static DCZone DCZoneForTouch(UITouch *touch) {
    static NSArray *blockers, *homeZones, *lockZones;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        blockers = @[@"IconView", @"Widget", @"NCNotification", @"PLPlatter", @"MediaControls", @"MRPlatter",
                     @"QuickAction", @"Passcode", @"NumberPad", @"Keyboard", @"SearchBar", @"Spotlight",
                     @"ShortcutMenu", @"Switcher", @"Banner", @"ControlCenter", @"CCUI", @"Camera"];
        homeZones = @[@"SBIconListView", @"SBRootFolderView", @"SBIconScrollView", @"SBHomeScreenView"];
        lockZones = @[@"SBDashBoardView", @"CSCoverSheetView", @"SBDashBoardMainPage", @"CSMainPage"];
    });

    BOOL blocked = NO, home = NO, lock = NO;
    for (UIView *view = touch.view; view; view = view.superview) {
        if ([view isKindOfClass:UIControl.class] || [view isKindOfClass:UITextField.class]) { blocked = YES; break; }
        NSString *name = NSStringFromClass(view.class);
        if (DCNameContains(name, blockers)) { blocked = YES; break; }
        if (DCNameContains(name, homeZones)) home = YES;
        if (DCNameContains(name, lockZones)) lock = YES;
    }
    if (blocked) return DCZoneNone;

    CGFloat band = MAX(DCStatusBarHeight(), 20.0) + 6.0;
    CGFloat y = [touch locationInView:nil].y;
    if (y >= 0 && y <= band) return DCZoneStatusBar;
    if (!lock && !home && DCIsLocked()) lock = YES;   // class names differ on this iOS: trust the lock state
    if (lock) return DCPasscodeVisible() ? DCZoneNone : DCZoneLockEmpty;
    if (home) return DCZoneHomeEmpty;
    return DCZoneNone;
}

#pragma mark - Double tap detection

// Tracks single taps (short, without moving) and reports when two follow each other quickly.
static BOOL DCRegisterTap(UITouch *touch) {
    static NSTimeInterval lastTapTime;
    static CGPoint lastTapPoint;
    static CGPoint beganPoint;
    static NSTimeInterval beganTime;
    static BOOL valid;

    CGPoint point = [touch locationInView:nil];
    switch (touch.phase) {
        case UITouchPhaseBegan:
            beganPoint = point;
            beganTime = touch.timestamp;
            valid = YES;
            return NO;
        case UITouchPhaseMoved:
            if (hypot(point.x - beganPoint.x, point.y - beganPoint.y) > 14.0) valid = NO;
            return NO;
        case UITouchPhaseCancelled:
            valid = NO;
            return NO;
        case UITouchPhaseEnded:
            break;
        default:
            return NO;
    }

    BOOL wasTap = valid && (touch.timestamp - beganTime) < 0.35 &&
                  hypot(point.x - beganPoint.x, point.y - beganPoint.y) <= 14.0;
    valid = NO;
    if (!wasTap) { lastTapTime = 0; return NO; }

    NSTimeInterval gap = touch.timestamp - lastTapTime;
    if (lastTapTime > 0 && gap <= (NSTimeInterval)cfg.speedMs / 1000.0 &&
        hypot(point.x - lastTapPoint.x, point.y - lastTapPoint.y) <= 60.0) {
        lastTapTime = 0;   // a third tap starts a new count
        return YES;
    }
    lastTapTime = touch.timestamp;
    lastTapPoint = point;
    return NO;
}

static void DCHandleDoubleTapInSpringBoard(UITouch *touch) {
    DCZone zone = DCZoneForTouch(touch);
    if (zone == DCZoneNone) return;
    if (zone == DCZoneLockEmpty) {
        if (cfg.unlock) dispatch_async(dispatch_get_main_queue(), ^{ DCDoUnlock(); });
        return;
    }
    if (!cfg.sleep) return;
    if ((zone == DCZoneStatusBar && cfg.sleepStatusBar) || (zone == DCZoneHomeEmpty && cfg.sleepEmpty)) {
        dispatch_async(dispatch_get_main_queue(), ^{ DCDoSleep(); });
    }
}

// Inside an app: only the status bar counts, and only when it is a normal one.
static void DCHandleDoubleTapInApp(UITouch *touch) {
    UIWindow *window = touch.window;
    if (!window) return;
    if (!CGSizeEqualToSize(window.bounds.size, UIScreen.mainScreen.bounds.size)) return;

    CGFloat height = DCStatusBarHeight();
    if (height <= 0) return;                                   // status bar hidden (games, video)
    BOOL hasHomeIndicator = window.safeAreaInsets.bottom > 0;
    if (!hasHomeIndicator && height > 24.0) return;            // in-call or hotspot bar: tapping returns to the call

    if ([touch locationInView:nil].y > height) return;
    notify_post(DC_NOTIFY_APP_SLEEP);
}

%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (event.type != UIEventTypeTouches) return;

    NSSet<UITouch *> *touches = event.allTouches;
    if (touches.count != 1) return;   // two fingers are never a double tap
    UITouch *touch = touches.anyObject;

    if (!DCRegisterTap(touch)) return;
    if (gIsSpringBoard) {
        if (cfg.enabled) DCHandleDoubleTapInSpringBoard(touch);
    } else {
        DCHandleDoubleTapInApp(touch);
    }
}

%end

#pragma mark - Notifications and entry point

static void DCDarwinCallback(CFNotificationCenterRef center, void *observer, CFStringRef name,
                             const void *object, CFDictionaryRef userInfo) {
    NSString *n = (__bridge NSString *)name;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([n isEqualToString:@DC_NOTIFY_PREFS]) {
            DCLoadConfig();
        } else if ([n isEqualToString:@DC_NOTIFY_SLEEP]) {
            DCDoSleep();   // test button in Settings
        } else if ([n isEqualToString:@DC_NOTIFY_APP_SLEEP]) {
            if (cfg.enabled && cfg.sleep && cfg.sleepStatusBar) DCDoSleep();
        } else if ([n isEqualToString:@DC_NOTIFY_RESPRING]) {
            DCRespring();
        }
    });
}

%ctor {
    @autoreleasepool {
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        if (!bundleID) return;

        gIsSpringBoard = [bundleID isEqualToString:@"com.apple.springboard"];
        // Apps only: skip extensions, XPC services and daemons.
        if (!gIsSpringBoard && ![NSBundle.mainBundle.bundlePath hasSuffix:@".app"]) return;

        DCLoadConfig();
        %init;

        CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
        if (gIsSpringBoard) {
            const char *names[] = { DC_NOTIFY_PREFS, DC_NOTIFY_SLEEP, DC_NOTIFY_APP_SLEEP, DC_NOTIFY_RESPRING };
            for (int i = 0; i < 4; i++) {
                CFNotificationCenterAddObserver(darwin, NULL, DCDarwinCallback,
                                                (__bridge CFStringRef)@(names[i]), NULL,
                                                CFNotificationSuspensionBehaviorDeliverImmediately);
            }
        } else {
            CFNotificationCenterAddObserver(darwin, NULL, DCDarwinCallback,
                                            CFSTR(DC_NOTIFY_PREFS), NULL,
                                            CFNotificationSuspensionBehaviorDeliverImmediately);
        }
    }
}
