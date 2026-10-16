#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <AVFoundation/AVFoundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import "BenchmarkPanel.h"
#import "BudSensor.h"
#import "Commands.h"
#import "DebugClips.h"
#import "Feedback.h"
#import "Gesture.h"
#import "ModelStore.h"
#import "MonitorPanel.h"
#import "OnboardingWindow.h"
#import "Overlay.h"
#import "Recorder.h"
#import "SettingsWindow.h"
#import "Transcriber.h"

static double now(void) { return NSProcessInfo.processInfo.systemUptime; }
// Touch rules, shared by the live hint and the decision on release. Shorter than the hold time a
// touch is a tap; up to kQuickTouchSeconds with no speech it is still a tap; longer with no speech
// it is a silent hold. "No speech" is under kSpeechSeconds above the take's noise floor.
static const double kQuickTouchSeconds = .95, kSpeechSeconds = .12;
typedef NS_ENUM(NSInteger, APHint) { APHintNone, APHintSend, APHintListen, APHintUndo };
static void (^eventSink)(NSString *);
static NSString *support(void) {
    static NSString *path;
    if (!path) path = [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject.path
                       stringByAppendingPathComponent:@"Buddial"];
    return path;
}
// Builds up to 0.9 kept their data in ~/.local/share/buddial, next to the source. Moved once.
static void migrateSupportDirectory(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *old = [NSHomeDirectory() stringByAppendingPathComponent:@".local/share/buddial"];
    [files createDirectoryAtPath:support() withIntermediateDirectories:YES attributes:nil error:nil];
    if ([files fileExistsAtPath:[support() stringByAppendingPathComponent:@"config.json"]]) return;
    for (NSString *item in @[@"config.json", @"models", @"bench", @"debug-clips", @"events.log", @"whisper-server.pid"]) {
        NSString *from = [old stringByAppendingPathComponent:item];
        if ([files fileExistsAtPath:from]) [files moveItemAtPath:from toPath:[support() stringByAppendingPathComponent:item] error:nil];
    }
}
static void record(NSString *event) {
    static NSDateFormatter *clock;
    if (!clock) { clock = [NSDateFormatter new]; clock.dateFormat = @"HH:mm:ss.SSS"; }
    NSString *line = [NSString stringWithFormat:@"%@  %@", [clock stringFromDate:NSDate.date], event];
    if (eventSink) eventSink(line);
    NSString *path = [support() stringByAppendingPathComponent:@"events.log"];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) [NSData.data writeToFile:path atomically:YES];
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
    @try { [file seekToEndOfFile]; [file writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]]; [file closeFile]; }
    @catch (NSException *e) { (void)e; }
}
// Whisper's stock outputs for silence or noise; only trusted when there was little speech.
static BOOL looksLikeSilenceHallucination(NSString *text) {
    NSString *plain = [[[text lowercaseString] componentsSeparatedByCharactersInSet:NSCharacterSet.punctuationCharacterSet] componentsJoinedByString:@""];
    plain = [plain stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!plain.length || [@[@"you", @"thank you", @"thanks", @"thank you very much", @"thanks for watching", @"bye", @"blankaudio", @"blank audio", @"silence", @"music"] containsObject:plain]) return YES;
    // Hums alone, however many ("Mhm. Mhm."), are what Whisper makes of a quiet room and the start cue.
    NSSet<NSString *> *hums = [NSSet setWithArray:@[@"hmm", @"hm", @"mm", @"mmm", @"mhm", @"mmhmm", @"uh", @"um", @"uhm"]];
    for (NSString *word in [plain componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet])
        if (word.length && ![hums containsObject:word]) return NO;
    return YES;
}
// On near-silence, Whisper can return the prompt itself; such a transcript is not speech.
static BOOL echoesPrompt(NSString *text, NSString *prompt) {
    if (!prompt.length) return NO;
    NSString *(^plain)(NSString *) = ^NSString *(NSString *s) {
        NSArray *words = [[[s lowercaseString] componentsSeparatedByCharactersInSet:[NSCharacterSet.alphanumericCharacterSet invertedSet]]
                          filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        return [words componentsJoinedByString:@" "];
    };
    NSString *heard = plain(text);
    return [heard componentsSeparatedByString:@" "].count >= 3 && [plain(prompt) containsString:heard];
}

@interface BuddialApp : NSObject <NSApplicationDelegate, APOnboardingHost> {
    APGesture gesture;
    BOOL desiredEnabled, committed, pendingEnter, pendingDelete, bluetoothConnected, checkingConnection, sensorCovered;
    NSUInteger sensorChanges, inFlight;
    double lastTouchMs, preRollMs, releaseToTextMs, transcriptionMs, recordedSeconds, speechSeconds, levelDb, lastSnapshot, lastConnectionCheck;
    pid_t lastInsertPID;
    double lastInsertAt, lastEnterAt, lastSyntheticKeyAt;
    BOOL enterSinceInsert, modelDownloading;
    double liveSpeech;   // speech heard so far in the current touch
    APHint hint;         // what the pill says letting go would do
    dispatch_source_t terminationSource;
}
@property NSMutableDictionary *config;
@property NSStatusItem *statusItem;
@property NSMenuItem *statusLine, *toggleItem;
@property APSettingsWindow *settings;
@property APOnboardingWindow *onboarding;
@property APModelStore *models;
@property APBenchmarkPanel *benchmark;
@property APBudSensor *sensor;
@property APRecorder *recorder;
@property APTranscriber *transcriber;
@property APFeedback *feedback;
@property APOverlay *overlay;
@property MonitorPanel *monitor;
@property APDebugClips *debugClips;
@property IOBluetoothDevice *bluetoothDevice;
@property NSString *actionText;
@property NSString *sourceText;
@property NSString *lastTranscript;
@property NSMutableArray<NSDictionary *> *recentInserts;   // {pid, text, at}: context for apps that hide their text
@property NSMutableArray<NSString *> *deletable;   // pasted strings since the last Return, newest last
@end

@implementation BuddialApp
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    if ([NSRunningApplication runningApplicationsWithBundleIdentifier:NSBundle.mainBundle.bundleIdentifier].count > 1) { [NSApp terminate:nil]; return; }
    migrateSupportDirectory();
    NSData *configData = [NSData dataWithContentsOfFile:[support() stringByAppendingPathComponent:@"config.json"]];
    NSDictionary *loaded = configData ? [NSJSONSerialization JSONObjectWithData:configData options:0 error:nil] : nil;
    self.config = [loaded isKindOfClass:NSDictionary.class] ? [loaded mutableCopy] : [NSMutableDictionary dictionary];
    gesture = (APGesture){
        .holdSeconds = [self number:@"holdSeconds"],
        .minimumTapSeconds = .08,
        .maximumHoldSeconds = [self number:@"maximumHoldSeconds"]};
    desiredEnabled = [[self settingValue:@"controlsEnabled"] boolValue];
    lastTouchMs = preRollMs = releaseToTextMs = transcriptionMs = -1;
    levelDb = -80;
    self.actionText = @"Ready";
    self.sourceText = @"None";
    __weak BuddialApp *weakSelf = self;

    [self buildMenu];
    self.monitor = [[MonitorPanel alloc] initWithController:self];
    eventSink = ^(NSString *line) { [weakSelf.monitor addEvent:line]; };
    self.overlay = [APOverlay new];
    self.feedback = [APFeedback new];
    self.feedback.mode = [self settingValue:@"cueOutput"];
    self.debugClips = [[APDebugClips alloc] initWithRoot:[support() stringByAppendingPathComponent:@"debug-clips"]];

    self.recorder = [APRecorder new];
    self.recorder.preRollSeconds = [self number:@"preRollSeconds"];
    self.recorder.microphonePreference = [self settingValue:@"microphone"];
    self.recorder.onEvent = ^(NSString *line) { record(line); };
    self.recorder.onLevel = ^(double db) {
        BuddialApp *strong = weakSelf;
        if (!strong) return;
        strong->levelDb = db;
        [strong.overlay setLevel:db];
    };
    self.recorder.onSpeech = ^(double seconds) {
        BuddialApp *strong = weakSelf;
        if (!strong || !strong->gesture.tracking) return;
        strong->liveSpeech = seconds;
        [strong updateHint];
    };
    self.recorder.keepOpen = [[self settingValue:@"instantStart"] boolValue];

    self.transcriber = [[APTranscriber alloc] initWithSupportDirectory:support()];
    self.transcriber.modelFile = [self settingValue:@"model"];
    self.transcriber.language = [self settingValue:@"language"];
    self.transcriber.useVAD = [[self settingValue:@"vad"] boolValue];
    self.transcriber.beamSize = [[self settingValue:@"beamSize"] integerValue];
    self.recentInserts = [NSMutableArray array];
    self.deletable = [NSMutableArray array];
    self.transcriber.onEvent = ^(NSString *line) { record(line); [weakSelf updateStatus]; };
    self.models = [[APModelStore alloc] initWithDirectory:[support() stringByAppendingPathComponent:@"models"]];
    self.models.onChange = ^{ [weakSelf modelStoreChanged]; };
    [self.transcriber start];
    [self downloadModelIfMissing];

    [self startSensor];
    self.settings = [[APSettingsWindow alloc] initWithHost:self modelsDirectory:[support() stringByAppendingPathComponent:@"models"] version:[self version]];
    self.benchmark = [[APBenchmarkPanel alloc] initWithDirectory:[support() stringByAppendingPathComponent:@"bench"]];

    if ([NSProcessInfo.processInfo.arguments containsObject:@"--simulate-sensor"]) {
        // Test input for driving the full pipeline without touching a bud.
        [NSDistributedNotificationCenter.defaultCenter addObserverForName:@"dev.buddial.simulate" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            NSString *command = note.object;
            if ([command isEqual:@"benchmark"]) [weakSelf showBenchmark:nil];
            else if ([command hasPrefix:@"onboarding:"]) { [weakSelf.onboarding show:[command substringFromIndex:11].integerValue]; [weakSelf.onboarding present]; }
            else if ([command hasPrefix:@"snapshot:"]) {
                // Renders the guide to a PNG: checking it needs no Screen Recording permission.
                NSView *frame = weakSelf.onboarding.contentView.superview;
                NSBitmapImageRep *image = [frame bitmapImageRepForCachingDisplayInRect:frame.bounds];
                [frame cacheDisplayInRect:frame.bounds toBitmapImageRep:image];
                [[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[command substringFromIndex:9] atomically:YES];
            }
            else [weakSelf.sensor simulate:[command isEqual:@"cover"]];
        }];
        record(@"Simulated sensor input enabled (--simulate-sensor).");
    }

    NSTimer *tick = [NSTimer timerWithTimeInterval:.05 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    NSTimer *slow = [NSTimer timerWithTimeInterval:1 target:self selector:@selector(slowTick:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:tick forMode:NSRunLoopCommonModes];
    [NSRunLoop.mainRunLoop addTimer:slow forMode:NSRunLoopCommonModes];

    signal(SIGTERM, SIG_IGN);
    terminationSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(terminationSource, ^{ [NSApp terminate:nil]; });
    dispatch_resume(terminationSource);

    // First run: the guide asks for each permission in context instead of stacking system prompts at launch.
    if (![[self settingValue:@"onboarded"] boolValue] || [NSProcessInfo.processInfo.arguments containsObject:@"--onboarding"]) {
        self.onboarding = [[APOnboardingWindow alloc] initWithHost:self];
        [self.onboarding present];
    } else {
        if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusNotDetermined) {
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    record(granted ? @"Microphone access allowed." : @"Microphone access not allowed.");
                    [weakSelf.recorder applyKeepOpen];
                    [weakSelf updateStatus];
                });
            }];
        }
        if (!AXIsProcessTrusted()) AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES});
        if (![[self settingValue:@"bluetoothAddress"] length]) [self.settings present];
    }
    if ([[self settingValue:@"showMonitorOnLaunch"] boolValue]) [self.monitor orderFrontRegardless];
    record([NSString stringWithFormat:@"Started v%@. Hold %.2f s, pre-roll %.2f s, mic %@, model %@, language %@, cues %@.", [self version], gesture.holdSeconds,
            self.recorder.preRollSeconds, self.recorder.microphonePreference, self.transcriber.modelFile, self.transcriber.language, self.feedback.mode]);
    [self updateStatus];
}
- (NSString *)version { return NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"dev"; }
+ (NSDictionary *)defaults {
    return @{@"controlsEnabled":@YES, @"holdSeconds":@.55, @"tapToSend":@YES, @"silentHoldDeletes":@YES, @"maximumHoldSeconds":@90,
             @"preRollSeconds":@.6, @"microphone":@"builtin", @"instantStart":@YES, @"model":[APTranscriber defaultModelFile],
             @"language":@"en", @"cueOutput":@"speakers", @"showMonitorOnLaunch":@NO,
             // Speech detection cut quiet speech in noise: +11 to +25 points WER on the 2026-10-15 benchmark.
             @"vocabulary":@"", @"useContext":@YES, @"vad":@NO, @"beamSize":@5,
             @"voiceCommands":@YES, @"replacements":@[]};
}
- (id)settingValue:(NSString *)key { return self.config[key] ?: BuddialApp.defaults[key]; }
- (double)number:(NSString *)key { return [[self settingValue:key] doubleValue]; }
- (void)saveConfig {
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.config options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    [data writeToFile:[support() stringByAppendingPathComponent:@"config.json"] atomically:YES];
}
- (void)buildMenu {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.imagePosition = NSImageLeft;
    NSMenu *menu = [NSMenu new];
    self.statusLine = [menu addItemWithTitle:@"Buddial" action:nil keyEquivalent:@""];
    [menu addItem:NSMenuItem.separatorItem];
    self.toggleItem = [menu addItemWithTitle:@"Pause Dictation" action:@selector(toggle:) keyEquivalent:@""];
    NSMenuItem *settings = [menu addItemWithTitle:@"Settings…" action:@selector(showSettings:) keyEquivalent:@","];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [menu addItemWithTitle:@"Quit Buddial" action:@selector(quit:) keyEquivalent:@"q"];
    for (NSMenuItem *item in @[self.toggleItem, settings, quit]) item.target = self;
    self.statusItem.menu = menu;
    // A menu-bar app shows no menu bar, but its text fields still need the Edit key equivalents:
    // ⌘V is how Buddial pastes, including into its own windows.
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    [edit addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    [edit addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
    [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    NSMenu *main = [NSMenu new];
    [main addItemWithTitle:@"Edit" action:nil keyEquivalent:@""].submenu = edit;
    NSApp.mainMenu = main;
}
// Restarting the reader is how a new AirPods choice takes effect. Without a device, nothing is read:
// an empty address would match every AirPods' log line.
- (void)startSensor {
    [self.sensor stop];
    self.sensor = nil;
    NSString *address = [self settingValue:@"bluetoothAddress"];
    if (!address.length) return;
    __weak BuddialApp *weakSelf = self;
    self.sensor = [[APBudSensor alloc] initWithAddress:address];
    self.sensor.onEvent = ^(NSString *line) { record(line); };
    self.sensor.onChange = ^(BOOL covered, NSString *source) { [weakSelf sensorChanged:covered source:source]; };
    self.sensor.onWorn = ^(BOOL worn) { [weakSelf wornChanged:worn]; };
    [self.sensor start];
}
- (void)resetGesture {
    [self.recorder discard];
    committed = NO;
    hint = APHintNone;
    APCancel(&gesture); APObserve(&gesture, NO, now());
    sensorCovered = NO;
}

#pragma mark Sensor and gestures

- (BOOL)microphoneAllowed { return [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusAuthorized; }
- (BOOL)enabled { return desiredEnabled && [self microphoneAllowed] && !self.sensor.worn; }
- (void)sensorChanged:(BOOL)covered source:(NSString *)source {
    if ([source isEqual:@"startup"]) { APObserve(&gesture, NO, now()); sensorCovered = NO; [self updateStatus]; return; }
    sensorChanges++;
    self.sourceText = source;
    sensorCovered = covered;
    if (!covered && gesture.tracking) lastTouchMs = (now() - gesture.pressedAt) * 1000;
    NSString *delivery = self.sensor.lastDeliveryMs >= 0 ? [NSString stringWithFormat:@", log→app %.0f ms", self.sensor.lastDeliveryMs] : @"";
    record([NSString stringWithFormat:@"Sensor %@ (%@%@)%@.", covered ? @"covered" : @"uncovered", source, delivery,
            !covered && lastTouchMs >= 0 ? [NSString stringWithFormat:@"; touch %.0f ms", lastTouchMs] : @""]);
    [self handle:APObserve(&gesture, covered, now())];
}
- (void)wornChanged:(BOOL)worn {
    if (worn) {
        BOOL active = gesture.tracking;
        [self resetGesture];
        if (active) [self.overlay hide];
        record(@"Both buds in ear: AirPods are being worn, sensor ignored until they come out.");
    } else {
        record(@"AirPods no longer worn: sensor active.");
    }
    [self updateStatus];
}
- (void)handle:(APAction)action {
    // While the guide is in front, a touch only lights it up; nothing records or types until the
    // practice step. In any other app, gestures work as usual.
    if (self.onboarding.keyWindow && !self.onboarding.practicing) {
        if (self.recorder.taking) [self.recorder discard];
        committed = NO;
        [self updateStatus];
        return;
    }
    switch (action) {
        case APNone: break;
        case APBeginTouch:
            if (![self enabled]) { [self.overlay flash:[self controlState] tone:APOverlayToneError]; break; }
            // Recording starts here (pre-roll included); the hold threshold only separates taps.
            [self.recorder beginAt:now()];
            [self.feedback play:APCueStart];
            liveSpeech = 0;
            hint = APHintNone;
            [self updateHint];
            break;
        case APStartDictation:
            if (![self enabled]) { [self.recorder discard]; break; }
            if (!self.recorder.taking) { [self.feedback play:APCueError]; [self.overlay flash:@"Microphone not ready" tone:APOverlayToneError]; break; }
            committed = YES;
            break;
        case APStopDictation:
            if (committed) [self finishTake];
            else { [self.recorder discard]; hint = APHintNone; }
            break;
        case APTap:
            [self.recorder discard];
            hint = APHintNone;
            [self tapToSend:lastTouchMs];
            break;
        case APDiscardTouch:
            [self.recorder discard];
            hint = APHintNone;
            [self.overlay hide];
            break;
    }
    [self updateStatus];
}
- (void)tick:(NSTimer *)timer {
    (void)timer;
    APAction action = APTick(&gesture, now());
    if (action == APStopDictation) {
        // Nobody dictates for this long: the bud went into an ear. Discard, never paste.
        [self resetGesture];
        [self.sensor markCoveredBudsWorn];
        [self.feedback play:APCueError];
        [self.overlay flash:[NSString stringWithFormat:@"Over %.0f s: discarded (bud treated as worn)", gesture.maximumHoldSeconds] tone:APOverlayToneError];
        record(@"Hold exceeded the maximum: recording discarded; that bud is treated as worn until it leaves the ear.");
    } else [self handle:action];
    if (gesture.tracking) { [self updateHint]; [self updateStatus]; }
}
// While a bud is held, the pill says what letting go now would do, by the rules the release uses.
- (void)updateHint {
    if (!gesture.tracking || !self.recorder.taking) return;
    double held = now() - gesture.pressedAt;
    BOOL quiet = liveSpeech < kSpeechSeconds;
    APHint next = APHintListen;
    if (self.benchmark.recording) next = APHintListen;
    else if ((held < gesture.holdSeconds || (quiet && held < kQuickTouchSeconds)) && [[self settingValue:@"tapToSend"] boolValue]) next = APHintSend;
    else if (quiet && held >= kQuickTouchSeconds && [[self settingValue:@"silentHoldDeletes"] boolValue] && ![self whyNothingToDelete]) next = APHintUndo;
    if (next == hint) return;
    hint = next;
    if (next == APHintSend) [self.overlay showHint:@"Release to send ↵" color:NSColor.systemBlueColor];
    else if (next == APHintUndo) [self.overlay showHint:@"Release to undo" color:NSColor.systemOrangeColor];
    else [self.overlay showListening];
    self.actionText = next == APHintSend ? @"Release to send" : next == APHintUndo ? @"Release to undo" : @"Listening — release to insert";
    record([NSString stringWithFormat:@"Hint at %.0f ms (speech %.2f s): %@.", held * 1000, liveSpeech, self.actionText]);
}
- (void)slowTick:(NSTimer *)timer {
    (void)timer;
    if (self.recorder.keepOpen && !self.recorder.open && [self microphoneAllowed]) [self.recorder applyKeepOpen];
    if (!checkingConnection) {
        checkingConnection = YES;
        NSString *address = [self settingValue:@"bluetoothAddress"];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (!self.bluetoothDevice && address.length) self.bluetoothDevice = [IOBluetoothDevice deviceWithAddressString:address];
            BOOL connected = self.bluetoothDevice.isConnected;
            dispatch_async(dispatch_get_main_queue(), ^{
                self->checkingConnection = NO;
                if (self->bluetoothConnected && !connected) {
                    record(@"AirPods disconnected.");
                    if (self->gesture.tracking) [self.overlay hide];
                    [self resetGesture];
                } else if (!self->bluetoothConnected && connected) record(@"AirPods connected.");
                self->bluetoothConnected = connected;
            });
        });
    }
    [self updateStatus];
}

#pragma mark Transcription and insertion

// Text the speech probably continues: what is before the cursor in the focused field or, where an
// app does not expose its text, what was dictated into that app recently. Read locally, sent only
// to the local speech engine.
- (NSString *)contextBeforeCursor:(NSString **)source {
    NSString *context = nil;
    CFTypeRef focused = NULL, subrole = NULL, value = NULL, range = NULL;
    AXUIElementRef system = AXUIElementCreateSystemWide();
    AXUIElementSetMessagingTimeout(system, .15);   // a busy app must never stall the main thread
    if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == getpid()) {
        // Buddial's own window (the practice box): read it directly; AX calls into this process
        // from its own main thread would only time out.
        NSTextView *view = (NSTextView *)NSApp.keyWindow.firstResponder;
        if ([view isKindOfClass:NSTextView.class]) context = [view.string substringToIndex:MIN(view.selectedRange.location, view.string.length)];
    } else if (AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute, &focused) == kAXErrorSuccess && focused) {
        BOOL secure = AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute, &subrole) == kAXErrorSuccess && subrole
            && [(__bridge NSString *)subrole isEqual:(__bridge NSString *)kAXSecureTextFieldSubrole];
        if (!secure && AXUIElementCopyAttributeValue(focused, kAXValueAttribute, &value) == kAXErrorSuccess && value && CFGetTypeID(value) == CFStringGetTypeID()) {
            NSString *text = (__bridge NSString *)value;
            NSUInteger caret = text.length;
            CFRange selection;
            if (AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute, &range) == kAXErrorSuccess && range && CFGetTypeID(range) == AXValueGetTypeID()
                && AXValueGetValue(range, kAXValueCFRangeType, &selection) && selection.location >= 0 && (NSUInteger)selection.location <= text.length) caret = (NSUInteger)selection.location;
            context = [text substringToIndex:caret];
        }
    }
    if (focused) CFRelease(focused);
    if (subrole) CFRelease(subrole);
    if (value) CFRelease(value);
    if (range) CFRelease(range);
    CFRelease(system);
    context = [context stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    *source = @"text field";
    if (!context.length) {
        pid_t front = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
        NSMutableArray<NSString *> *recent = [NSMutableArray array];
        for (NSDictionary *insert in self.recentInserts)
            if ([insert[@"pid"] intValue] == front && now() - [insert[@"at"] doubleValue] < 600) [recent addObject:insert[@"text"]];
        context = [recent componentsJoinedByString:@" "];
        *source = @"recent dictation";
    }
    if (context.length > 300) {
        context = [context substringFromIndex:context.length - 300];
        NSRange space = [context rangeOfString:@" "];
        if (space.location != NSNotFound) context = [context substringFromIndex:space.location + 1];
    }
    return context;
}
// Whisper continues the prompt's style, so vocabulary is written as a sentence before the context.
- (NSString *)promptForTake:(NSString **)summary {
    NSMutableArray<NSString *> *parts = [NSMutableArray array], *described = [NSMutableArray array];
    NSCharacterSet *trim = [NSCharacterSet characterSetWithCharactersInString:@" ,.;\n\t"];
    // The user's words plus every spelling from the replacements list, so one list covers both.
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    NSString *typed = [[self settingValue:@"vocabulary"] stringByTrimmingCharactersInSet:trim];
    if (typed.length) [words addObject:typed];
    for (NSString *spelling in APReplacementSpellings([self settingValue:@"replacements"]))
        if ([typed rangeOfString:spelling options:NSCaseInsensitiveSearch].location == NSNotFound) [words addObject:spelling];
    NSString *vocabulary = [words componentsJoinedByString:@", "];
    if (vocabulary.length) { [parts addObject:[NSString stringWithFormat:@"Words I use: %@.", vocabulary]]; [described addObject:@"vocabulary"]; }
    NSString *source = nil;
    NSString *context = [[self settingValue:@"useContext"] boolValue] ? [self contextBeforeCursor:&source] : nil;
    if (context.length) { [parts addObject:context]; [described addObject:[NSString stringWithFormat:@"%lu chars of %@", (unsigned long)context.length, source]]; }
    *summary = described.count ? [described componentsJoinedByString:@" + "] : @"none";
    return parts.count ? [parts componentsJoinedByString:@" "] : nil;
}
- (void)finishTake {
    if (self.benchmark.recording) {
        // Benchmark takes are saved with their reference sentence; never transcribed or pasted.
        committed = NO;
        [self.feedback play:APCueStop];
        __weak BuddialApp *weakSelf = self;
        [self.recorder finishWithTail:.15 completion:^(APRecording *take) {
            NSString *saved = [weakSelf.benchmark saveTake:[take wave]];
            record([NSString stringWithFormat:@"Benchmark take %.2f s (speech %.2f s): %@.", take.seconds, take.speechSeconds, saved ?: @"benchmark closed, not saved"]);
            [weakSelf.overlay flash:saved ?: @"Benchmark closed" tone:APOverlayToneSuccess];
        }];
        return;
    }
    committed = NO;
    inFlight++;
    double released = now();
    double heldMs = (released - gesture.pressedAt) * 1000;
    BOOL listening = hint == APHintListen;
    hint = APHintNone;
    [self.feedback play:APCueStop];
    // A take that was going to send or undo keeps that hint while the last audio is checked.
    if (listening) [self.overlay showWorking:@"Transcribing…"];
    self.actionText = listening ? @"Transcribing…" : self.actionText;
    NSString *contextSummary = nil;
    NSString *prompt = [self promptForTake:&contextSummary];
    __weak BuddialApp *weakSelf = self;
    [self.recorder finishWithTail:.15 completion:^(APRecording *take) {
        BuddialApp *strong = weakSelf;
        if (!strong) return;
        strong->recordedSeconds = take.seconds;
        strong->speechSeconds = take.speechSeconds;
        strong->preRollMs = take.preRollMs;
        double window = strong.recorder.preRollSeconds * 1000 - 100;
        NSString *lead = take.speechLeadMs < 0 ? @"" : take.speechLeadMs == 0 ? @"; talking started after the touch report"
            : [NSString stringWithFormat:@"; already talking %@%.0f ms when the touch report arrived%@", take.speechLeadAtLeast ? @"≥" : @"", take.speechLeadMs,
               take.speechLeadMs > window ? @" (longer than the pre-roll: first words may be cut)" : @""];
        record([NSString stringWithFormat:@"Take %.2f s from %@ (pre-roll %.0f ms%@, speech %.2f s%@; context: %@).", take.seconds, take.microphone,
                take.preRollMs, take.firstAudioMs >= 0 && take.preRollMs == 0 ? [NSString stringWithFormat:@", mic start %.0f ms", take.firstAudioMs] : @"", take.speechSeconds, lead, contextSummary]);
        // No speech: a short touch is a tap (two quick taps also arrive as one such touch: the bud
        // never reports the gap between them); a longer one is a silent hold. Silent holds measured
        // ≤ 0.10 s of speech; the quietest real dictation 0.14 s.
        if (take.speechSeconds < kSpeechSeconds) {
            if (heldMs >= kQuickTouchSeconds * 1000 && ![[strong settingValue:@"silentHoldDeletes"] boolValue]) { [strong takeFailed:@"No speech heard"]; return; }
            if (strong->inFlight) strong->inFlight--;
            if (heldMs < kQuickTouchSeconds * 1000) [strong tapToSend:heldMs];
            else [strong deleteLastDictation:[NSString stringWithFormat:@"Silent hold (%.0f ms)", heldMs]];
            return;
        }
        NSData *wave = [take wave];
        NSString *clip = strong.debugClips.remaining ? [strong.debugClips reserveAudio:wave metadata:@{@"microphone":take.microphone ?: @"", @"preRollMs":@(take.preRollMs), @"speechSeconds":@(take.speechSeconds)}] : nil;
        [strong.transcriber transcribeWave:wave prompt:prompt completion:^(NSString *text, NSString *error, double elapsed) {
            strong->transcriptionMs = elapsed;
            if (!error && take.speechSeconds < .8 && looksLikeSilenceHallucination(text)) error = @"No speech recognized";
            if (!error && [text rangeOfCharacterFromSet:NSCharacterSet.alphanumericCharacterSet].location == NSNotFound) error = @"No speech recognized";
            if (!error && echoesPrompt(text, prompt)) error = @"No speech recognized";
            [strong.debugClips finishDirectory:clip text:text ?: @"" metadata:@{@"transcriptionMs":@(elapsed), @"error":error ?: @""}];
            // A short touch with no words was a tap the level meter mistook for speech (5 of 10 such
            // touches in the log, all ≤ 0.26 s of "speech"): send instead of failing.
            if (error && heldMs < kQuickTouchSeconds * 1000 && [error isEqual:@"No speech recognized"]) {
                if (strong->inFlight) strong->inFlight--;
                record([NSString stringWithFormat:@"No words in a %.0f ms touch: treated as a tap.", heldMs]);
                [strong tapToSend:heldMs];
                return;
            }
            if (error) { [strong takeFailed:error]; return; }
            text = APApplyReplacements(text, [strong settingValue:@"replacements"]);
            if ([[strong settingValue:@"voiceCommands"] boolValue] && [strong runCommand:text released:released]) return;
            [strong insert:text released:released];
        }];
    }];
    [self updateStatus];
}
- (void)takeFailed:(NSString *)reason {
    if (inFlight) inFlight--;
    if (!inFlight) pendingEnter = pendingDelete = NO;
    [self.feedback play:APCueError];
    [self.overlay flash:reason tone:APOverlayToneError];
    self.actionText = reason;
    record(reason);
    [self updateStatus];
}
- (BOOL)focusedFieldIsSecure {
    if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == getpid()) return NO;   // Buddial has no password fields
    AXUIElementRef system = AXUIElementCreateSystemWide();
    CFTypeRef focused = NULL;
    BOOL secure = NO;
    if (AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute, &focused) == kAXErrorSuccess && focused) {
        CFTypeRef subrole = NULL;
        if (AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute, &subrole) == kAXErrorSuccess && subrole) {
            secure = [(__bridge NSString *)subrole isEqual:(__bridge NSString *)kAXSecureTextFieldSubrole];
            CFRelease(subrole);
        }
        CFRelease(focused);
    }
    CFRelease(system);
    return secure;
}
- (void)postKey:(CGKeyCode)key flags:(CGEventFlags)flags {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    for (int down = 1; down >= 0; down--) {
        CGEventRef event = CGEventCreateKeyboardEvent(source, key, down);
        CGEventSetFlags(event, flags);
        CGEventPost(kCGSessionEventTap, event);
        CFRelease(event);
    }
    if (source) CFRelease(source);
    lastSyntheticKeyAt = now();
}
// Whether the user typed or clicked since Buddial's last keystroke: the cursor may have moved, so
// backspacing would no longer remove what Buddial pasted. Counts physical input only.
- (BOOL)userInputSinceLastKey {
    double since = now() - lastSyntheticKeyAt;
    const CGEventType types[] = {kCGEventKeyDown, kCGEventLeftMouseDown, kCGEventRightMouseDown};
    for (size_t i = 0; i < sizeof types / sizeof *types; i++)
        if (CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateHIDSystemState, types[i]) < since - .05) return YES;
    return NO;
}
// Puts text on the clipboard, presses ⌘V, and puts the previous clipboard back half a second later
// (unless something else changed it meanwhile).
- (void)paste:(NSString *)text {
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    NSMutableArray<NSPasteboardItem *> *saved = [NSMutableArray array];
    for (NSPasteboardItem *item in board.pasteboardItems) {
        NSPasteboardItem *copy = [NSPasteboardItem new];
        for (NSPasteboardType type in item.types) { NSData *data = [item dataForType:type]; if (data) [copy setData:data forType:type]; }
        [saved addObject:copy];
    }
    [board clearContents];
    [board setString:text forType:NSPasteboardTypeString];
    NSInteger ours = board.changeCount;
    [self postKey:9 flags:kCGEventFlagMaskCommand];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        if (board.changeCount == ours) { [board clearContents]; if (saved.count) [board writeObjects:saved]; }
    });
}
// A transcript that starts with a command word does that instead of being typed. Returns NO for
// ordinary dictation. Commands never join the undo list: their text is not in the document.
- (BOOL)runCommand:(NSString *)text released:(double)released {
    APCommand *command = [APCommand parse:text];
    if (command.kind == APCommandNone) return NO;
    if (inFlight) inFlight--;
    releaseToTextMs = (now() - released) * 1000;
    BOOL allowed = AXIsProcessTrusted();
    if (!allowed && command.kind != APCommandScratch) {
        [self.overlay flash:@"Allow Accessibility for voice commands" tone:APOverlayToneError];
        record(@"Voice command skipped: Accessibility is off.");
    } else if (command.kind == APCommandScratch) {
        [self deleteLastDictation:@"Voice command (scratch that)"];
    } else if (command.kind == APCommandNewLine) {
        [self postKey:36 flags:kCGEventFlagMaskShift];
        [self.overlay flash:@"New line" tone:APOverlayToneInfo];
        record(@"Voice command: new line (Shift+Return).");
    } else if (command.kind == APCommandSpotlight) {
        // ⌘Space opens Spotlight (or whichever launcher the user gave that shortcut). Its search
        // field needs a moment to appear before the query is pasted into it.
        [self postKey:49 flags:kCGEventFlagMaskCommand];
        [self.overlay flash:command.text.length ? [@"Spotlight: " stringByAppendingString:command.text] : @"Spotlight" tone:APOverlayToneInfo];
        record([NSString stringWithFormat:@"Voice command: Spotlight with a %lu-character query (release → command %.0f ms).", (unsigned long)command.text.length, releaseToTextMs]);
        if (command.text.length) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self paste:command.text]; });
    }
    // A tap made while this was transcribing still sends: after the query lands, Return opens the result.
    if (!inFlight && pendingEnter && allowed && command.kind != APCommandScratch) {
        pendingEnter = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self pressEnter]; });
    }
    if (!inFlight) pendingDelete = NO;
    [self updateStatus];
    return YES;
}
- (void)insert:(NSString *)text released:(double)released {
    if (inFlight) inFlight--;
    self.lastTranscript = text;
    releaseToTextMs = (now() - released) * 1000;
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    if (!AXIsProcessTrusted()) {
        [board clearContents]; [board setString:text forType:NSPasteboardTypeString];
        [self.overlay flash:@"Copied — allow Accessibility to paste" tone:APOverlayToneError];
        record(@"Accessibility is off: transcript copied to the clipboard instead of pasted.");
        pendingEnter = pendingDelete = NO;
        [self updateStatus];
        return;
    }
    if ([self focusedFieldIsSecure]) {
        [self.overlay flash:@"Password field — not pasted" tone:APOverlayToneError];
        record(@"Focused field is a password field: transcript not pasted (use Copy transcript).");
        pendingEnter = pendingDelete = NO;
        [self updateStatus];
        return;
    }
    NSRunningApplication *app = NSWorkspace.sharedWorkspace.frontmostApplication;
    // Consecutive takes into the same app read as one sentence stream.
    BOOL sameStream = app.processIdentifier == lastInsertPID && !enterSinceInsert;
    NSString *insert = sameStream && now() - lastInsertAt < 120 ? [@" " stringByAppendingString:text] : text;
    // Earlier dictations stay deletable only while they sit directly before this one.
    if (!sameStream || [self userInputSinceLastKey]) [self.deletable removeAllObjects];
    [self paste:insert];
    lastInsertPID = app.processIdentifier; lastInsertAt = now(); enterSinceInsert = NO;
    if (app.processIdentifier == getpid()) [self.onboarding noteInserted];
    [self.deletable addObject:insert];
    [self.recentInserts addObject:@{@"pid":@(app.processIdentifier), @"text":text, @"at":@(now())}];
    if (self.recentInserts.count > 20) [self.recentInserts removeObjectAtIndex:0];
    [self.overlay flash:@"Inserted" tone:APOverlayToneSuccess];
    self.actionText = @"Inserted — tap to send";
    record([NSString stringWithFormat:@"Pasted %lu characters into %@ (release → paste %.0f ms; engine %.0f ms).", (unsigned long)insert.length, app.localizedName ?: @"the front app", releaseToTextMs, transcriptionMs]);
    if (!inFlight && (pendingDelete || pendingEnter)) {
        BOOL delete = pendingDelete, enter = pendingEnter;
        pendingDelete = pendingEnter = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_main_queue(), ^{
            if (delete) [self deleteLastDictation:@"Queued silent hold"];
            if (enter) [self pressEnter];
        });
    }
    [self updateStatus];
}
// A tap presses Return. A double tap can reach the Mac as two touches (or one), so a tap within
// 1.5 s of the last Return is the same gesture and is ignored.
- (void)tapToSend:(double)touchMs {
    if (![[self settingValue:@"tapToSend"] boolValue]) { [self.overlay hide]; return; }
    if (inFlight) {
        pendingEnter = YES;
        [self.overlay flash:@"Sending once the text lands" tone:APOverlayToneInfo];
        record([NSString stringWithFormat:@"Tap (%.0f ms): Return queued until the text is pasted.", touchMs]);
        return;
    }
    if (now() - lastEnterAt < 1.5) {
        [self.overlay hide];
        record([NSString stringWithFormat:@"Tap (%.0f ms): part of the same tap gesture, Return already sent.", touchMs]);
        return;
    }
    record([NSString stringWithFormat:@"Tap (%.0f ms): Return.", touchMs]);
    [self pressEnter];
}
// A silent hold removes the last dictation by backspacing it; again, the one before, back to the
// last Return. Refused when another app is in front or the user typed or clicked since.
- (void)deleteLastDictation:(NSString *)trigger {
    if (inFlight) {
        pendingDelete = YES; pendingEnter = NO;
        [self.overlay flash:@"Deleting once the text lands" tone:APOverlayToneInfo];
        record([trigger stringByAppendingString:@": delete queued until the text is pasted."]);
        return;
    }
    NSString *why = [self whyNothingToDelete];
    if (why) {
        [self.feedback play:APCueError];
        [self.overlay flash:@"Nothing to delete" tone:APOverlayToneInfo];
        self.actionText = @"Nothing to delete";
        record([NSString stringWithFormat:@"%@: nothing deleted, %@.", trigger, why]);
        if (self.deletable.count && !AXIsProcessTrusted()) [self.deletable removeAllObjects];
        [self updateStatus];
        return;
    }
    NSString *last = self.deletable.lastObject;
    __block NSUInteger characters = 0;
    [last enumerateSubstringsInRange:NSMakeRange(0, last.length) options:NSStringEnumerationByComposedCharacterSequences | NSStringEnumerationSubstringNotRequired
                          usingBlock:^(NSString *s, NSRange r, NSRange e, BOOL *stop) { characters++; }];
    for (NSUInteger i = 0; i < characters; i++) [self postKey:51 flags:0];
    [self.deletable removeLastObject];
    NSDictionary *recent = self.recentInserts.lastObject;
    if ([recent[@"pid"] intValue] == lastInsertPID) [self.recentInserts removeLastObject];
    if (!self.deletable.count) lastInsertAt = 0;   // the next dictation starts fresh, without a joining space
    [self.feedback play:APCueDelete];
    [self.overlay flash:@"Deleted" tone:APOverlayToneInfo];
    self.actionText = @"Last dictation deleted";
    record([NSString stringWithFormat:@"%@: deleted the last dictation (%lu characters; %lu more can be deleted).", trigger,
            (unsigned long)characters, (unsigned long)self.deletable.count]);
    [self.onboarding noteDeleted];
    [self updateStatus];
}
// Why a silent hold would remove nothing right now; nil when it would. A dictation still being
// transcribed counts: the removal waits for it.
- (NSString *)whyNothingToDelete {
    if (inFlight) return nil;
    if (!AXIsProcessTrusted()) return @"Accessibility is off";
    if (!self.deletable.count) return @"nothing dictated since the last Return";
    if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != lastInsertPID) return @"a different app is in front";
    if ([self userInputSinceLastKey]) return @"you typed or clicked since, so the cursor may have moved";
    return nil;
}
- (void)pressEnter {
    if (!AXIsProcessTrusted()) { [self.overlay flash:@"Allow Accessibility for Return" tone:APOverlayToneError]; return; }
    [self postKey:36 flags:0];
    enterSinceInsert = YES; lastEnterAt = now();
    [self.deletable removeAllObjects];
    [self.onboarding noteSent];
    [self.feedback play:APCueEnter];
    [self.overlay flash:@"Sent ↵" tone:APOverlayToneInfo];
    self.actionText = @"Return pressed";
    [self updateStatus];
}

#pragma mark Status

- (NSString *)controlState {
    if (!desiredEnabled) return @"Paused";
    if (![[self settingValue:@"bluetoothAddress"] length]) return @"Choose your AirPods in Settings";
    if (![self microphoneAllowed]) return @"Allow microphone access";
    if (!bluetoothConnected) return @"AirPods not connected";
    if (self.sensor.worn) return @"AirPods worn — sensor ignored";
    if (gesture.tracking && [self enabled]) return @"Listening — release to insert";
    if (inFlight) return @"Transcribing…";
    if (self.models.downloadingFile && self.models.totalBytes > 0)
        return [NSString stringWithFormat:@"Downloading speech model, %.0f%%", 100.0 * self.models.receivedBytes / self.models.totalBytes];
    if (self.models.error && ![self.models isInstalled:self.transcriber.modelFile]) return [@"Speech model not downloaded: " stringByAppendingString:self.models.error];
    if (!self.transcriber.ready) return [@"Speech engine: " stringByAppendingString:self.transcriber.status];
    if (!AXIsProcessTrusted()) return @"Allow Accessibility to paste (text is copied meanwhile)";
    return self.actionText;
}
- (void)updateStatus {
    NSString *state = [self controlState];
    self.statusLine.title = state;
    self.toggleItem.title = desiredEnabled ? @"Pause Dictation" : @"Resume Dictation";
    BOOL attention = !desiredEnabled || ![self microphoneAllowed] || !AXIsProcessTrusted() || ![[self settingValue:@"bluetoothAddress"] length];
    BOOL recording = gesture.tracking && [self enabled];
    NSString *symbol = recording ? @"mic.fill" : inFlight ? @"waveform" : @"airpods";
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:@"Buddial"];
    self.statusItem.button.contentTintColor = recording ? NSColor.systemRedColor : nil;
    self.statusItem.button.title = attention ? @" !" : @"";
    self.statusItem.button.toolTip = [@"Buddial — " stringByAppendingString:state];
    double t = now();
    if (!self.monitor.visible && t - lastSnapshot < .25) return;
    double age = self.sensor.lastEventUptime ? (t - self.sensor.lastEventUptime) * 1000 : -1;
    NSDictionary *snapshot = @{
        @"updatedAt":@([NSDate.date timeIntervalSince1970]),
        @"sensor":self.sensor.worn ? @"worn" : sensorCovered ? @"covered" : @"uncovered",
        @"source":self.sourceText ?: @"None", @"rawSensorStates":self.sensor.rawStates ?: @"", @"sensorChanges":@(sensorChanges),
        @"observationAgeMs":@(age), @"action":state,
        @"holdingMs":@(gesture.tracking ? (t - gesture.pressedAt) * 1000 : 0), @"holdThresholdMs":@(gesture.holdSeconds * 1000),
        @"lastTouchMs":@(lastTouchMs), @"logDeliveryMs":@(self.sensor.lastDeliveryMs), @"preRollMs":@(preRollMs),
        @"releaseToTextMs":@(releaseToTextMs), @"transcriptionMs":@(transcriptionMs),
        @"bluetoothReader":@(self.sensor.running), @"bluetoothConnected":@(bluetoothConnected),
        @"accessibility":@(AXIsProcessTrusted()), @"microphoneAllowed":@([self microphoneAllowed]),
        @"backend":self.transcriber.modelName, @"engineStatus":self.transcriber.status ?: @"",
        @"cueOutput":[NSString stringWithFormat:@"%@ (%@)", self.feedback.mode, self.feedback.outputName],
        @"microphone":self.recorder.microphoneName ?: @"", @"micOpen":@(self.recorder.open), @"levelDb":@(levelDb),
        @"recordedSeconds":@(recordedSeconds), @"speechSeconds":@(speechSeconds),
        @"hasTranscript":@(self.lastTranscript.length > 0), @"controlsPaused":@(!desiredEnabled),
        @"recording":@(recording), @"transcribing":@(inFlight > 0)
    };
    if (self.monitor.visible) [self.monitor displaySnapshot:snapshot];
    if (t - lastSnapshot > .25) {
        lastSnapshot = t;
        NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingPrettyPrinted error:nil];
        [data writeToFile:[support() stringByAppendingPathComponent:@"status.json"] atomically:YES];
    }
}

#pragma mark Menu actions

- (void)showMonitor:(id)sender { (void)sender; [self.monitor orderFrontRegardless]; }
- (void)showSettings:(id)sender { (void)sender; [self.settings present]; }
- (void)showBenchmark:(id)sender { (void)sender; [self.benchmark present]; }
- (void)toggle:(id)sender { (void)sender; [self setSettingValue:@(!desiredEnabled) forKey:@"controlsEnabled"]; }

#pragma mark Speech model

- (void)downloadModelIfMissing {
    if ([self.models isInstalled:self.transcriber.modelFile]) return;
    record([NSString stringWithFormat:@"Speech model %@ not on this Mac: downloading.", self.transcriber.modelFile]);
    [self.models download:self.transcriber.modelFile];
}
- (void)retryModelDownload { [self downloadModelIfMissing]; }
- (void)modelStoreChanged {
    BOOL downloading = self.models.downloadingFile != nil;
    if (modelDownloading && !downloading) {
        if (self.models.error) record([NSString stringWithFormat:@"Speech model download failed: %@", self.models.error]);
        else { record(@"Speech model downloaded and verified."); [self.transcriber restart]; }
    }
    modelDownloading = downloading;
    [self updateStatus];
}

#pragma mark Onboarding and settings host

- (void)finishOnboarding {
    [self setSettingValue:@YES forKey:@"onboarded"];
    record(@"Onboarding finished.");
}

- (void)setSettingValue:(id)value forKey:(NSString *)key {
    if (!value || [value isEqual:[self settingValue:key]]) return;
    self.config[key] = value;
    [self saveConfig];
    if ([key isEqual:@"controlsEnabled"]) {
        desiredEnabled = [value boolValue];
        [self resetGesture];
        self.actionText = desiredEnabled ? @"Ready" : @"Paused";
        [self.overlay flash:desiredEnabled ? @"Dictation on" : @"Dictation paused" tone:APOverlayToneInfo];
    } else if ([key isEqual:@"bluetoothAddress"]) {
        [self resetGesture];
        self.bluetoothDevice = nil;
        bluetoothConnected = NO;
        [self startSensor];
    } else if ([key isEqual:@"holdSeconds"]) gesture.holdSeconds = [value doubleValue];
    else if ([key isEqual:@"microphone"]) { self.recorder.microphonePreference = value; [self.recorder reopen]; }
    else if ([key isEqual:@"instantStart"]) self.recorder.keepOpen = [value boolValue];
    else if ([key isEqual:@"model"]) { self.transcriber.modelFile = value; [self.transcriber restart]; }
    else if ([key isEqual:@"language"]) { self.transcriber.language = value; [self.transcriber restart]; }
    else if ([key isEqual:@"vad"]) { self.transcriber.useVAD = [value boolValue]; [self.transcriber restart]; }
    else if ([key isEqual:@"beamSize"]) { self.transcriber.beamSize = [value integerValue]; [self.transcriber restart]; }
    else if ([key isEqual:@"cueOutput"]) self.feedback.mode = value;
    if (![key isEqual:@"holdSeconds"]) record([NSString stringWithFormat:@"Setting %@ → %@.", key, value]);
    [self updateStatus];
}
- (NSDictionary *)liveStatus {
    BOOL recording = gesture.tracking && [self enabled];
    BOOL attention = !desiredEnabled || ![self microphoneAllowed] || !AXIsProcessTrusted() || !bluetoothConnected || !self.transcriber.ready;
    return @{@"state":[self controlState], @"tone":@(recording ? 1 : attention ? 2 : 0),
             @"sensor":self.sensor.worn ? @"worn" : sensorCovered ? @"covered" : @"uncovered",
             @"connected":@(bluetoothConnected), @"microphoneAllowed":@([self microphoneAllowed]), @"accessibilityAllowed":@(AXIsProcessTrusted()),
             @"engineReady":@(self.transcriber.ready), @"modelInstalled":@([self.models isInstalled:self.transcriber.modelFile]),
             @"modelDownloading":@(self.models.downloadingFile != nil), @"modelReceived":@(self.models.receivedBytes),
             @"modelTotal":@(self.models.totalBytes), @"modelError":self.models.error ?: @""};
}
- (void)requestMicrophoneAccess {
    if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            (void)granted;
            dispatch_async(dispatch_get_main_queue(), ^{ [self.recorder applyKeepOpen]; [self updateStatus]; });
        }];
        return;
    }
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]];
}
- (void)openAccessibilitySettings {
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES});
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}
- (void)testSound:(id)sender {
    (void)sender;
    [self.feedback play:APCueStart];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 6 / 10), dispatch_get_main_queue(), ^{ [self.feedback play:APCueStop]; });
    record([NSString stringWithFormat:@"Test sound through %@.", self.feedback.outputName]);
}
- (void)copyTranscript:(id)sender {
    (void)sender;
    if (!self.lastTranscript.length) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:self.lastTranscript forType:NSPasteboardTypeString];
    self.actionText = @"Transcript copied";
    [self updateStatus];
}
- (void)quit:(id)sender { (void)sender; [NSApp terminate:nil]; }
- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.transcriber stop];
    [self.sensor stop];
    record(@"Stopped.");
}
@end

int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        BuddialApp *delegate = [BuddialApp new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
