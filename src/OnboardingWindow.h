#import "SettingsWindow.h"

// The app side of onboarding. Its liveStatus also carries engineReady, modelInstalled,
// modelDownloading (NSNumber BOOLs), modelReceived and modelTotal (bytes) and modelError (string).
@protocol APOnboardingHost <APSettingsHost>
- (void)retryModelDownload;
- (void)finishOnboarding;
@end

// First-run guide: welcome, permissions, AirPods, a practice run, done.
@interface APOnboardingWindow : NSWindow
- (instancetype)initWithHost:(id<APOnboardingHost>)host;
- (void)present;
- (void)show:(NSInteger)step;   // 0 welcome, 1 permissions, 2 AirPods, 3 practice, 4 done
@property(readonly) BOOL practicing;   // on the practice step, gestures act in the guide; on other steps, while it is focused, they only light it up
- (void)noteInserted;   // BudDial pasted a dictation into this window
- (void)noteSent;       // BudDial pressed Return
- (void)noteDeleted;    // BudDial removed a dictation
@end
