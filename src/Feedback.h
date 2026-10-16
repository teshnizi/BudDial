#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, APCue) { APCueStart, APCueStop, APCueEnter, APCueDelete, APCueError };

// Short synthesized cues, preloaded and played off the main thread. "speakers"
// pins them to the Mac's built-in output: covering a bud makes macOS route
// system audio to that bud, which is in the user's hand, not their ear.
@interface APFeedback : NSObject
@property(nonatomic) NSString *mode;   // "speakers", "system" or "off"
@property(readonly) NSString *outputName;
- (void)play:(APCue)cue;
@end
