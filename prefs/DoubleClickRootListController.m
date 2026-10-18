#import <UIKit/UIKit.h>
#import <notify.h>

// Minimal declarations of the private Preferences.framework classes we subclass.
@interface PSViewController : UIViewController
@end

@interface PSListController : PSViewController {
@protected
    NSArray *_specifiers;
}
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)reloadSpecifiers;
@end

#define DC_DOMAIN CFSTR("com.kwarnu.doubleclick")
#define DC_NOTIFY_PREFS "com.kwarnu.doubleclick/prefschanged"
#define DC_NOTIFY_SLEEP "com.kwarnu.doubleclick/sleep"
#define DC_NOTIFY_RESPRING "com.kwarnu.doubleclick/respring"

@interface DoubleClickRootListController : PSListController
@end

@implementation DoubleClickRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// Turns the screen off 3 seconds after you confirm, so you can watch it work.
- (void)testSleep {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Test Sleep"
                         message:@"The screen will turn off in 3 seconds. Wake it with the Home button."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Start" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            notify_post(DC_NOTIFY_SLEEP);
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resetDefaults {
    NSArray *keys = @[@"enabled", @"unlock", @"sleep", @"sleepStatusBar", @"sleepEmpty",
                      @"haptic", @"debug", @"speedMs"];
    for (NSString *key in keys) {
        CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL, DC_DOMAIN);
    }
    CFPreferencesAppSynchronize(DC_DOMAIN);
    notify_post(DC_NOTIFY_PREFS);
    [self reloadSpecifiers];
    [self showAlert:@"Reset" message:@"All Double-Click settings are back to their defaults."];
}

- (void)respring {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Respring"
                         message:@"Respring now?"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        notify_post(DC_NOTIFY_RESPRING);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
