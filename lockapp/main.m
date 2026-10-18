// "Lock" app: tap its icon on the Home Screen and the screen turns off.
//
// Normally Double-Click catches the tap on the icon inside SpringBoard and locks the screen without
// even opening this app. If that is not possible, the app opens, asks SpringBoard to lock the screen
// and closes itself right away.

#import <UIKit/UIKit.h>
#import <notify.h>

@interface DCLockAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation DCLockAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    UIViewController *controller = [[UIViewController alloc] init];
    controller.view.backgroundColor = [UIColor colorWithRed:0.79 green:0.71 blue:1.0 alpha:1.0];

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        notify_post("com.kwarnu.doubleclick/applock");
        // Close right after the screen has gone off, so the app is not left open behind the Lock Screen.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            exit(0);
        });
    });
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(DCLockAppDelegate.class));
    }
}
