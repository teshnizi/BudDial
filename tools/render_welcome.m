// Renders the welcome page's gesture animation, one PNG per frame, for docs/demo.gif.
// Run: tools/make_demo_gif.sh. Uses the real onboarding window and stage with a stand-in host.
#import "../src/OnboardingWindow.h"
#import "../src/GestureStage.h"
#import <IOBluetooth/IOBluetooth.h>

// The device helpers live in SettingsWindow.m, which is not linked here; the welcome page needs none.
NSString *APBluetoothAddress(IOBluetoothDevice *device) { return device.addressString; }
NSArray<IOBluetoothDevice *> *APPairedBuds(void) { return @[]; }

@interface StandInHost : NSObject <APOnboardingHost>
@end
@implementation StandInHost
- (id)settingValue:(NSString *)key { (void)key; return nil; }
- (void)setSettingValue:(id)value forKey:(NSString *)key { (void)value; (void)key; }
- (NSDictionary *)liveStatus { return @{}; }
- (void)requestMicrophoneAccess {}
- (void)openAccessibilitySettings {}
- (void)testSound:(id)sender { (void)sender; }
- (void)showMonitor:(id)sender { (void)sender; }
- (void)retryModelDownload {}
- (void)finishOnboarding {}
@end

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: render_welcome <frames dir> <fps>\n"); return 1; }
    NSString *frames = [NSString stringWithUTF8String:argv[1]];
    double fps = atof(argv[2]);
    [NSApplication sharedApplication];
    NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;
    NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    StandInHost *host = [StandInHost new];
    APOnboardingWindow *window = [[APOnboardingWindow alloc] initWithHost:host];
    [window setFrameOrigin:NSMakePoint(-4000, -4000)];
    [window orderFrontRegardless];
    APGestureStage *stage = [window valueForKey:@"stage"];
    [stage stop];   // frames are drawn at exact times below, not by the display link
    NSView *frameView = window.contentView.superview;
    int count = (int)(14 * fps);
    for (int i = 0; i < count; i++) {
        [stage renderAt:i / fps];
        // Let the row highlight fade run for one frame's worth of real time.
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0 / fps]];
        [window displayIfNeeded];
        NSBitmapImageRep *rep = [frameView bitmapImageRepForCachingDisplayInRect:frameView.bounds];
        [frameView cacheDisplayInRect:frameView.bounds toBitmapImageRep:rep];
        NSString *path = [frames stringByAppendingPathComponent:[NSString stringWithFormat:@"f%04d.png", i]];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:NO];
    }
    printf("%d frames, %.0fx%.0f px\n", count, frameView.bounds.size.width * window.backingScaleFactor, frameView.bounds.size.height * window.backingScaleFactor);
}}
