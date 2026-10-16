#import "MonitorPanel.h"

static NSTextField *label(NSString *text, CGFloat size, NSFontWeight weight) {
    NSTextField *field = [NSTextField wrappingLabelWithString:text];
    field.font = [NSFont systemFontOfSize:size weight:weight];
    field.maximumNumberOfLines = 0;
    return field;
}

@implementation MonitorPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
- (instancetype)initWithController:(id)controller {
    self = [super initWithContentRect:NSMakeRect(0, 0, 520, 710)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    if (!self) return nil;
    self.title = @"Buddial — Live";
    self.level = NSFloatingWindowLevel;
    self.hidesOnDeactivate = NO;
    self.releasedWhenClosed = NO;
    self.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.events = [NSMutableArray array];
    NSStackView *stack = [NSStackView new];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:22],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-18]
    ]];
    self.liveClockLabel = label(@"AIRPOD  ·  LIVE", 11, NSFontWeightBold);
    self.liveClockLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightBold];
    self.liveClockLabel.textColor = NSColor.systemBlueColor;
    [stack addArrangedSubview:self.liveClockLabel];
    self.sensorLabel = label(@"Waiting for sensor", 30, NSFontWeightSemibold);
    [stack addArrangedSubview:self.sensorLabel];
    self.sourceLabel = label(@"Waiting for a macOS observation", 12, NSFontWeightRegular);
    [stack addArrangedSubview:self.sourceLabel];
    self.rawStateLabel = label(@"Raw sensor: waiting for an ear-state event", 12, NSFontWeightRegular);
    self.rawStateLabel.textColor = NSColor.secondaryLabelColor;
    [stack addArrangedSubview:self.rawStateLabel];
    [self.rawStateLabel.heightAnchor constraintEqualToConstant:36].active = YES;
    self.holdProgress = [NSProgressIndicator new];
    self.holdProgress.indeterminate = NO;
    self.holdProgress.minValue = 0;
    self.holdProgress.maxValue = 1;
    self.holdProgress.style = NSProgressIndicatorStyleBar;
    [stack addArrangedSubview:self.holdProgress];
    [self.holdProgress.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    self.actionLabel = label(@"Ready — cover sensor to begin", 15, NSFontWeightMedium);
    [stack addArrangedSubview:self.actionLabel];
    [self.actionLabel.heightAnchor constraintEqualToConstant:42].active = YES;
    self.timingLabel = label(@"", 13, NSFontWeightRegular);
    self.timingLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
    [stack addArrangedSubview:self.timingLabel];
    [self.timingLabel.heightAnchor constraintEqualToConstant:60].active = YES;
    self.healthLabel = label(@"", 11, NSFontWeightRegular);
    self.healthLabel.textColor = NSColor.secondaryLabelColor;
    [stack addArrangedSubview:self.healthLabel];
    [self.healthLabel.heightAnchor constraintEqualToConstant:58].active = YES;
    self.microphoneLabel = label(@"Microphone: not started", 11, NSFontWeightRegular);
    [stack addArrangedSubview:self.microphoneLabel];
    self.microphoneLevel = [NSProgressIndicator new];
    self.microphoneLevel.indeterminate = NO;
    self.microphoneLevel.minValue = 0;
    self.microphoneLevel.maxValue = 1;
    [stack addArrangedSubview:self.microphoneLevel];
    [self.microphoneLevel.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    NSScrollView *scroll = [NSScrollView new];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    self.eventView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 470, 190)];
    self.eventView.editable = NO;
    self.eventView.selectable = NO;
    self.eventView.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.eventView.textContainerInset = NSMakeSize(8, 8);
    self.eventView.autoresizingMask = NSViewWidthSizable;
    scroll.documentView = self.eventView;
    [stack addArrangedSubview:scroll];
    [scroll.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    [scroll.heightAnchor constraintEqualToConstant:104].active = YES;
    NSStackView *buttons = [NSStackView new];
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttons.spacing = 8;
    self.pauseButton = [NSButton buttonWithTitle:@"Pause" target:controller action:@selector(toggle:)];
    [buttons addArrangedSubview:self.pauseButton];
    [buttons addArrangedSubview:[NSButton buttonWithTitle:@"Settings…" target:controller action:@selector(showSettings:)]];
    self.transcriptCopyButton = [NSButton buttonWithTitle:@"Copy transcript" target:controller action:@selector(copyTranscript:)];
    [buttons addArrangedSubview:self.transcriptCopyButton];
    [buttons addArrangedSubview:[NSButton buttonWithTitle:@"Test sound" target:controller action:@selector(testSound:)]];
    [buttons addArrangedSubview:[NSButton buttonWithTitle:@"Benchmark…" target:controller action:@selector(showBenchmark:)]];
    [stack addArrangedSubview:buttons];
    NSTextField *note = label(@"Cover a bud and talk right away (the open mic keeps a short buffer). Release → text at the cursor. Tap → Return. Hold a second without talking → delete the last dictation. Benchmark… records sentences for ./bench.py.", 11, NSFontWeightRegular);
    note.textColor = NSColor.secondaryLabelColor;
    [stack addArrangedSubview:note];
    for (NSView *view in stack.arrangedSubviews) {
        if ([view isKindOfClass:NSTextField.class]) [view.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    }
    NSRect screen = NSScreen.mainScreen.visibleFrame;
    [self setFrameTopLeftPoint:NSMakePoint(NSMaxX(screen) - 545, NSMaxY(screen) - 40)];
    return self;
}
- (void)displaySnapshot:(NSDictionary *)s {
    static NSDateFormatter *clock;
    if (!clock) { clock = [NSDateFormatter new]; clock.dateFormat = @"HH:mm:ss.SSS"; }
    self.liveClockLabel.stringValue = [NSString stringWithFormat:@"AIRPOD  ·  LIVE  %@", [clock stringFromDate:NSDate.date]];
    NSString *sensor = s[@"sensor"];
    self.sensorLabel.stringValue = [sensor isEqual:@"covered"] ? @"●  Covered" : [sensor isEqual:@"worn"] ? @"◐  Worn (ignored)" : @"○  Uncovered";
    self.sensorLabel.textColor = [sensor isEqual:@"covered"] ? NSColor.systemGreenColor : NSColor.labelColor;
    double age = [s[@"observationAgeMs"] doubleValue];
    self.sourceLabel.stringValue = age < 0 ? @"No sensor event yet: cover a bud once" : [NSString stringWithFormat:@"%@  ·  last event %.1f s ago", s[@"source"], age / 1000];
    self.rawStateLabel.stringValue = [NSString stringWithFormat:@"Buds: %@\nSensor changes this session: %@", s[@"rawSensorStates"], s[@"sensorChanges"]];
    self.actionLabel.stringValue = s[@"action"];
    double hold = [s[@"holdingMs"] doubleValue], threshold = [s[@"holdThresholdMs"] doubleValue];
    self.holdProgress.doubleValue = MIN(1, hold / threshold);
    NSString *(^ms)(NSString *) = ^NSString *(NSString *key) { double v = [s[key] doubleValue]; return v < 0 ? @"—" : [NSString stringWithFormat:@"%.0f ms", v]; };
    self.timingLabel.stringValue = [NSString stringWithFormat:@"Hold  %4.0f / %.0f ms    Last touch  %@\nBluetooth log → app  %@    Pre-roll kept  %@\nRelease → text  %@    (speech engine  %@)",
        hold, threshold, ms(@"lastTouchMs"), ms(@"logDeliveryMs"), ms(@"preRollMs"), ms(@"releaseToTextMs"), ms(@"transcriptionMs")];
    self.healthLabel.stringValue = [NSString stringWithFormat:@"AirPods connected: %@  ·  Event reader: %@\nAccessibility: %@  ·  Microphone: %@\nSpeech engine: %@ · %@\nCues: %@", [s[@"bluetoothConnected"] boolValue] ? @"yes" : @"no", [s[@"bluetoothReader"] boolValue] ? @"running" : @"stopped", [s[@"accessibility"] boolValue] ? @"allowed" : @"NOT allowed", [s[@"microphoneAllowed"] boolValue] ? @"allowed" : @"NOT allowed", s[@"backend"], s[@"engineStatus"], s[@"cueOutput"]];
    self.pauseButton.title = [s[@"controlsPaused"] boolValue] ? @"Resume" : @"Pause";
    self.transcriptCopyButton.enabled = [s[@"hasTranscript"] boolValue];
    double level = [s[@"levelDb"] doubleValue];
    self.microphoneLevel.doubleValue = MIN(1, MAX(0, (level + 60) / 60));
    self.microphoneLabel.stringValue = [NSString stringWithFormat:@"Mic: %@%@  ·  %.0f dB  ·  last take %.1f s (speech %.1f s)", s[@"microphone"], [s[@"micOpen"] boolValue] ? @" (open)" : @"", level, [s[@"recordedSeconds"] doubleValue], [s[@"speechSeconds"] doubleValue]];
}
- (void)addEvent:(NSString *)event {
    [self.events insertObject:event atIndex:0];
    if (self.events.count > 70) [self.events removeLastObject];
    self.eventView.string = [self.events componentsJoinedByString:@"\n"];
}
- (void)clearLog:(id)sender { (void)sender; [self.events removeAllObjects]; self.eventView.string = @""; }
@end
