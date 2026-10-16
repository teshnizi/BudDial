#import <AppKit/AppKit.h>

typedef NS_ENUM(NSInteger, APStagePhase) { APStageHoldAndTalk, APStageTap, APStageSilentHold };

// A looping, abstract picture of the three gestures: a fingertip on a bud, the sound it hears,
// and what happens to the text. With Reduce Motion on it shows still frames instead.
@interface APGestureStage : NSView
@property(copy) void (^onPhase)(APStagePhase phase);   // the gesture now playing
- (void)start;
- (void)stop;
- (void)showPhase:(APStagePhase)phase;   // jump to the start of a gesture
- (void)renderAt:(double)seconds;        // draw one moment of the loop
@end
