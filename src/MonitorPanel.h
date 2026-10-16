#import <AppKit/AppKit.h>

@interface MonitorPanel : NSPanel
@property NSTextField *sensorLabel;
@property NSTextField *sourceLabel;
@property NSTextField *liveClockLabel;
@property NSTextField *rawStateLabel;
@property NSTextField *actionLabel;
@property NSTextField *timingLabel;
@property NSTextField *healthLabel;
@property NSTextField *microphoneLabel;
@property NSProgressIndicator *microphoneLevel;
@property NSButton *transcriptCopyButton;
@property NSProgressIndicator *holdProgress;
@property NSTextView *eventView;
@property NSButton *pauseButton;
@property NSMutableArray<NSString *> *events;
- (instancetype)initWithController:(id)controller;
- (void)displaySnapshot:(NSDictionary *)snapshot;
- (void)addEvent:(NSString *)event;
@end
