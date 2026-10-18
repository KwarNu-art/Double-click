// Double-Click: a helper for the power button.
//
//  1. Double tap to unlock: double tap empty space on the Lock Screen and the unlock screen opens
//     (the same as pressing the Home button). With a passcode or Touch ID it only brings up the
//     prompt; authentication is never skipped.
//  2. Double tap to sleep: double tap the status bar, or empty space on the Home Screen, and the
//     screen turns off (the same as pressing the power button).
//  3. The "Lock Screen" app icon on the Home Screen posts a notification; SpringBoard turns the
//     screen off.
//
// SpringBoard handles everything. Inside apps a tiny hook only watches for a double tap on the
// status bar and tells SpringBoard, because app touches never reach SpringBoard.

#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "DCTap.h"

#define DC_DOMAIN CFSTR("com.kwarnu.doubleclick")
#define DC_PLIST_PATH @"/var/mobile/Library/Preferences/com.kwarnu.doubleclick.plist"
#define DC_NOTIFY_PREFS "com.kwarnu.doubleclick/prefschanged"
#define DC_NOTIFY_SLEEP "com.kwarnu.doubleclick/sleep"          // test button in Settings
#define DC_NOTIFY_APP_SLEEP "com.kwarnu.doubleclick/appsleep"   // status bar double tap inside an app
#define DC_NOTIFY_APP_LOCK "com.kwarnu.doubleclick/applock"     // the Lock Screen app icon
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
    BOOL debug;            // short on-screen message for every double tap
    NSInteger speedMs;     // maximum gap between the two taps
} DCConfig;

static DCConfig cfg = {
    .enabled = YES, .unlock = YES, .sleep = YES, .sleepStatusBar = YES, .sleepEmpty = YES,
    .haptic = YES, .debug = YES, .speedMs = 350,
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
    c.debug = DCBool(@"debug", YES);
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

static BOOL DCGetBool(id object, NSString *selector, BOOL fallback) {
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) return fallback;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, sel);
}

static BOOL DCScreenOn(void) {
    return DCGetBool(DCShared("SBBacklightController", @"sharedInstance"), @"screenIsOn", YES);
}

static BOOL DCIsLocked(void) {
    return DCGetBool(DCShared("SBLockScreenManager", @"sharedInstance"), @"isUILocked", NO);
}

static BOOL DCAppIsFront(void) {
    UIApplication *app = UIApplication.sharedApplication;
    SEL sel = NSSelectorFromString(@"_accessibilityFrontMostApplication");
    if (![app respondsToSelector:sel]) return NO;
    return ((id (*)(id, SEL))objc_msgSend)(app, sel) != nil;
}

static BOOL DCIconsAreJiggling(void) {
    return DCGetBool(DCShared("SBIconController", @"sharedInstance"), @"isEditing", NO);
}

static void DCHaptic(void) {
    if (cfg.haptic) AudioServicesPlaySystemSound(1519);
}

#pragma mark - Debug message

@interface DCToastWindow : UIWindow
@end

@implementation DCToastWindow
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { return NO; }
@end

// A small message at the top of the screen, so you can see what Double-Click decided.
static void DCToast(NSString *text) {
    if (!cfg.debug || !gIsSpringBoard) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        static DCToastWindow *window;
        static UILabel *label;
        static NSUInteger token;

        if (!window) {
            DCToastWindow *w = nil;
            if (@available(iOS 13.0, *)) {
                for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                    if ([scene isKindOfClass:UIWindowScene.class]) {
                        w = [[DCToastWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
                        break;
                    }
                }
            }
            if (!w) w = [[DCToastWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
            w.windowLevel = UIWindowLevelAlert + 2000.0;
            w.backgroundColor = UIColor.clearColor;
            w.userInteractionEnabled = NO;

            UIViewController *controller = [[UIViewController alloc] init];
            controller.view.backgroundColor = UIColor.clearColor;
            controller.view.userInteractionEnabled = NO;
            w.rootViewController = controller;

            UILabel *l = [[UILabel alloc] init];
            l.font = [UIFont boldSystemFontOfSize:13.0];
            l.textColor = UIColor.whiteColor;
            l.textAlignment = NSTextAlignmentCenter;
            l.backgroundColor = [UIColor colorWithRed:0.43 green:0.31 blue:0.88 alpha:0.94];
            l.layer.cornerRadius = 12.0;
            l.layer.masksToBounds = YES;
            l.numberOfLines = 2;
            [controller.view addSubview:l];
            window = w;
            label = l;
        }

        CGFloat width = MIN(UIScreen.mainScreen.bounds.size.width - 24.0, 340.0);
        label.text = text;
        CGSize fit = [label sizeThatFits:CGSizeMake(width - 24.0, 60.0)];
        label.frame = CGRectMake((UIScreen.mainScreen.bounds.size.width - width) / 2.0, 48.0,
                                 width, MAX(30.0, ceil(fit.height) + 14.0));
        window.hidden = NO;
        window.alpha = 1.0;

        NSUInteger mine = ++token;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (mine == token) window.hidden = YES;
        });
    });
}

#pragma mark - Actions (SpringBoard)

typedef void (^DCAttempt)(void);

// Calls a no-argument method if the object has it.
static DCAttempt DCCall(id object, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) return nil;
    return ^{ ((void (*)(id, SEL))objc_msgSend)(object, sel); };
}

// Calls a (source, options) method if the object has it.
static DCAttempt DCCallSource(id object, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) return nil;
    return ^{ ((void (*)(id, SEL, long long, id))objc_msgSend)(object, sel, 1, nil); };
}

// Runs the attempts one after another until `done` says the job is finished. A method that exists
// on one iOS version but silently does nothing on another is simply followed by the next one.
static void DCRunUntil(NSArray<DCAttempt> *attempts, NSUInteger index, BOOL (^done)(void)) {
    if (index >= attempts.count) return;
    attempts[index]();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!done()) DCRunUntil(attempts, index + 1, done);
    });
}

static NSArray<DCAttempt> *DCCompact(NSArray *maybeAttempts) {
    NSMutableArray *out = [NSMutableArray array];
    for (id item in maybeAttempts) if (item != NSNull.null) [out addObject:[item copy]];
    return out;
}

static id DCOrNull(id value) { return value ?: NSNull.null; }

// Same effect as pressing the power button while the screen is on.
static void DCSleepScreen(void) {
    UIApplication *app = UIApplication.sharedApplication;
    id manager = DCShared("SBLockScreenManager", @"sharedInstance");
    id agent = DCShared("SBUserAgent", @"sharedUserAgent");
    NSArray *attempts = DCCompact(@[
        DCOrNull(DCCall(app, @"_simulateLockButtonPress")),
        DCOrNull(DCCallSource(manager, @"lockUIFromSource:withOptions:")),
        DCOrNull(DCCall(agent, @"lockAndDimDevice")),
    ]);
    DCRunUntil(attempts, 0, ^BOOL { return !DCScreenOn(); });
}

// Same effect as pressing the Home button on the Lock Screen: opens the Home Screen when there is no
// passcode, otherwise shows the passcode / Touch ID prompt. It never skips authentication.
static BOOL DCPasscodeVisible(void);

static void DCUnlockScreen(void) {
    UIApplication *app = UIApplication.sharedApplication;
    id manager = DCShared("SBLockScreenManager", @"sharedInstance");
    id uiController = DCShared("SBUIController", @"sharedInstance");
    NSArray *attempts = DCCompact(@[
        DCOrNull(DCCall(app, @"_simulateHomeButtonPress")),
        DCOrNull(DCCallSource(manager, @"unlockUIFromSource:withOptions:")),
        DCOrNull(DCCall(uiController, @"clickedMenuButton")),
    ]);
    DCRunUntil(attempts, 0, ^BOOL { return !DCIsLocked() || DCPasscodeVisible(); });
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

// Decides what a double tap at this touch means. Icons, buttons, widgets, notifications, the
// passcode pad and any other control are never a double tap zone, so normal taps are never hijacked.
// `why` receives a short reason for the debug message.
static DCZone DCZoneForTouch(UITouch *touch, NSString **why) {
    static NSArray *blockers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        blockers = @[@"IconView", @"Widget", @"NCNotification", @"PLPlatter", @"MediaControls", @"MRPlatter",
                     @"QuickAction", @"Passcode", @"NumberPad", @"Keyboard", @"SearchBar", @"Spotlight",
                     @"ShortcutMenu", @"Switcher", @"Banner", @"ControlCenter", @"CCUI", @"Camera", @"Library"];
    });

    for (UIView *view = touch.view; view; view = view.superview) {
        NSString *name = NSStringFromClass(view.class);
        if ([view isKindOfClass:UIControl.class] || [view isKindOfClass:UITextField.class] ||
            DCNameContains(name, blockers)) {
            *why = [NSString stringWithFormat:@"tapped a control (%@)", name];
            return DCZoneNone;
        }
    }

    CGFloat band = MAX(DCStatusBarHeight(), 20.0) + 6.0;
    CGFloat y = [touch locationInView:nil].y;
    if (y >= 0 && y <= band) return DCZoneStatusBar;

    if (DCIsLocked()) {
        if (DCPasscodeVisible()) { *why = @"the passcode pad is showing"; return DCZoneNone; }
        return DCZoneLockEmpty;
    }
    if (DCAppIsFront()) { *why = @"an app is open"; return DCZoneNone; }
    if (DCIconsAreJiggling()) { *why = @"icons are being edited"; return DCZoneNone; }
    return DCZoneHomeEmpty;
}

#pragma mark - Double tap handling

static void DCHandleDoubleTapInSpringBoard(UITouch *touch) {
    NSString *why = @"";
    DCZone zone = DCZoneForTouch(touch, &why);

    if (zone == DCZoneNone) {
        DCToast([NSString stringWithFormat:@"Double-Click: ignored, %@", why]);
        return;
    }
    if (zone == DCZoneLockEmpty) {
        if (!cfg.unlock) { DCToast(@"Double-Click: double tap to unlock is off"); return; }
        DCToast(@"Double-Click: unlock");
        dispatch_async(dispatch_get_main_queue(), ^{ DCDoUnlock(); });
        return;
    }
    if (!cfg.sleep) { DCToast(@"Double-Click: double tap to sleep is off"); return; }
    if (zone == DCZoneStatusBar && !cfg.sleepStatusBar) { DCToast(@"Double-Click: status bar sleep is off"); return; }
    if (zone == DCZoneHomeEmpty && !cfg.sleepEmpty) { DCToast(@"Double-Click: empty space sleep is off"); return; }
    DCToast(@"Double-Click: sleep");
    dispatch_async(dispatch_get_main_queue(), ^{ DCDoSleep(); });
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

static DCTapState gTapState;
static NSTimeInterval gLastBeforeStamp, gLastAfterStamp;

// Called around every touch event, from both hooks below.
//   before == YES : just before iOS delivers the event. Taps are judged here, because the touched
//                   view and the position are still valid.
//   before == NO  : right after delivery. Finger-down and movement are recorded here.
static void DCObserveEvent(UIEvent *event, BOOL before) {
    if (event.type != UIEventTypeTouches) return;

    NSSet<UITouch *> *touches = event.allTouches;
    if (touches.count != 1) {            // two fingers are never a double tap
        if (!before) DCTapInvalidate(&gTapState);
        return;
    }
    UITouch *touch = touches.anyObject;
    UITouchPhase phase = touch.phase;
    BOOL finishing = (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled);
    if (before != finishing) return;

    NSTimeInterval *last = before ? &gLastBeforeStamp : &gLastAfterStamp;
    if (event.timestamp == *last) return;   // UIApplication and UIWindow both report the same event
    *last = event.timestamp;

    DCTapPhase tapPhase = DCTapMoved;
    switch (phase) {
        case UITouchPhaseBegan: tapPhase = DCTapBegan; break;
        case UITouchPhaseEnded: tapPhase = DCTapEnded; break;
        case UITouchPhaseCancelled: tapPhase = DCTapCancelled; break;
        default: break;
    }

    CGPoint point = [touch locationInView:nil];
    if (!DCTapFeed(&gTapState, tapPhase, point.x, point.y, touch.timestamp, (double)cfg.speedMs / 1000.0)) return;

    if (gIsSpringBoard) {
        if (cfg.enabled) DCHandleDoubleTapInSpringBoard(touch);
    } else {
        DCHandleDoubleTapInApp(touch);
    }
}

%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    DCObserveEvent(event, YES);
    %orig;
    DCObserveEvent(event, NO);
}

%end

// Some SpringBoard windows deliver touches without going through UIApplication, so watch windows too.
%hook UIWindow

- (void)sendEvent:(UIEvent *)event {
    DCObserveEvent(event, YES);
    %orig;
    DCObserveEvent(event, NO);
}

%end

// Tapping the "Lock" icon on the Home Screen: lock the screen right away, without opening the app.
// If this hook does not apply on some iOS version, the app opens and asks for the same thing itself.
@interface SBApplicationIcon : NSObject
- (NSString *)applicationBundleID;
@end

%hook SBApplicationIcon

- (void)launchFromLocation:(id)location context:(id)context {
    NSString *bundleID = [self respondsToSelector:@selector(applicationBundleID)] ? [self applicationBundleID] : nil;
    if ([bundleID isEqualToString:@"com.kwarnu.doubleclick.lock"]) {
        DCToast(@"Double-Click: Lock icon tapped");
        dispatch_async(dispatch_get_main_queue(), ^{ DCDoSleep(); });
        return;
    }
    %orig;
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
            DCToast(@"Double-Click: test sleep");
            DCDoSleep();   // test button in Settings
        } else if ([n isEqualToString:@DC_NOTIFY_APP_SLEEP]) {
            if (cfg.enabled && cfg.sleep && cfg.sleepStatusBar) {
                DCToast(@"Double-Click: sleep (status bar in app)");
                DCDoSleep();
            }
        } else if ([n isEqualToString:@DC_NOTIFY_APP_LOCK]) {
            DCDoSleep();   // the Lock Screen app icon always works
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
            const char *names[] = { DC_NOTIFY_PREFS, DC_NOTIFY_SLEEP, DC_NOTIFY_APP_SLEEP,
                                    DC_NOTIFY_APP_LOCK, DC_NOTIFY_RESPRING };
            for (int i = 0; i < 5; i++) {
                CFNotificationCenterAddObserver(darwin, NULL, DCDarwinCallback,
                                                (__bridge CFStringRef)@(names[i]), NULL,
                                                CFNotificationSuspensionBehaviorDeliverImmediately);
            }
            // Proof that the tweak is running inside SpringBoard.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ DCToast(@"Double-Click is active"); });
        } else {
            CFNotificationCenterAddObserver(darwin, NULL, DCDarwinCallback,
                                            CFSTR(DC_NOTIFY_PREFS), NULL,
                                            CFNotificationSuspensionBehaviorDeliverImmediately);
        }
    }
}
