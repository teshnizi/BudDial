#import <AppKit/AppKit.h>

typedef NS_ENUM(NSInteger, APOverlayTone) { APOverlayToneInfo, APOverlayToneSuccess, APOverlayToneError };

// Small click-through pill at the bottom of the active screen. Never takes focus.
@interface APOverlay : NSPanel
- (instancetype)init;
- (void)showListening;                   // touch reported; recording
- (void)showWorking:(NSString *)text;    // transcribing / pasting
- (void)showHint:(NSString *)text color:(NSColor *)color;   // while held: what letting go now will do, with the voice level
- (void)setLevel:(double)db;
- (void)flash:(NSString *)text tone:(APOverlayTone)tone;
- (void)flash:(NSString *)text tone:(APOverlayTone)tone seconds:(double)seconds;
- (void)hide;
@end
