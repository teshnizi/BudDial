#import "BenchmarkPanel.h"

// Everyday requests to coding assistants, project jargon, and short replies (the hardest case).
static NSArray<NSString *> *sentences(void) {
    return @[@"Can you check why the build is failing on the main branch?",
             @"Install BudDial with Homebrew and grant microphone access.",
             @"Let's ship the settings panel today and benchmark the models tomorrow.",
             @"Whisper runs locally on the Mac, so nothing leaves the device.",
             @"Open a pull request, then ask Cursor Bugbot to review it.",
             @"Why does the double tap only work if I wait half a second?",
             @"Rename the speech lead variable and update the README.",
             @"Pause dictation when both AirPods are in my ears.",
             @"Ask Codex to summarize the last three commits.",
             @"The transcription was wrong because I was too far from the microphone.",
             @"Yes, go ahead.",
             @"Send it."];
}

@interface APBenchmarkPanel ()
@property NSString *root, *session;
@property NSUInteger index;
@property NSTextField *progress, *sentence, *status;
@property NSButton *redo, *skip;
@property(readwrite) BOOL recording;
@end

@implementation APBenchmarkPanel
- (instancetype)initWithDirectory:(NSString *)directory {
    self = [super initWithContentRect:NSMakeRect(0, 0, 560, 250) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
                              backing:NSBackingStoreBuffered defer:NO];
    if (!self) return nil;
    _root = directory;
    self.title = @"Voice benchmark";
    self.releasedWhenClosed = NO;
    self.level = NSFloatingWindowLevel;
    self.hidesOnDeactivate = NO;
    self.progress = [NSTextField labelWithString:@""];
    self.progress.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    self.progress.textColor = NSColor.secondaryLabelColor;
    self.sentence = [NSTextField wrappingLabelWithString:@""];
    self.sentence.font = [NSFont systemFontOfSize:22 weight:NSFontWeightMedium];
    self.sentence.preferredMaxLayoutWidth = 512;
    NSTextField *hint = [NSTextField wrappingLabelWithString:@"Hold the bud, read the sentence the way you normally talk, from where you normally sit, then release. Nothing is pasted."];
    hint.font = [NSFont systemFontOfSize:12];
    hint.textColor = NSColor.secondaryLabelColor;
    hint.preferredMaxLayoutWidth = 512;
    self.status = [NSTextField labelWithString:@""];
    self.status.font = [NSFont systemFontOfSize:12];
    self.redo = [NSButton buttonWithTitle:@"Redo previous" target:self action:@selector(redoPrevious:)];
    self.skip = [NSButton buttonWithTitle:@"Skip" target:self action:@selector(skipSentence:)];
    NSStackView *buttons = [NSStackView stackViewWithViews:@[self.status, [NSView new], self.redo, self.skip]];
    buttons.spacing = 8;
    NSStackView *page = [NSStackView stackViewWithViews:@[self.progress, self.sentence, hint, buttons]];
    page.orientation = NSUserInterfaceLayoutOrientationVertical;
    page.alignment = NSLayoutAttributeLeading;
    page.spacing = 14;
    page.edgeInsets = NSEdgeInsetsMake(20, 24, 18, 24);
    page.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:page];
    [NSLayoutConstraint activateConstraints:@[
        [page.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [page.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [page.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [page.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor],
        [buttons.widthAnchor constraintEqualToAnchor:page.widthAnchor constant:-48]]];
    return self;
}
- (void)present {
    NSDateFormatter *stamp = [NSDateFormatter new];
    stamp.dateFormat = @"yyyy-MM-dd-HHmmss";
    self.session = [self.root stringByAppendingPathComponent:[stamp stringFromDate:NSDate.date]];
    [NSFileManager.defaultManager createDirectoryAtPath:self.session withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    self.index = 0;
    self.recording = YES;
    self.status.stringValue = @"";
    [self show];
    [self center];
    [NSApp activateIgnoringOtherApps:YES];
    [self makeKeyAndOrderFront:nil];
}
- (void)show {
    NSArray *all = sentences();
    if (self.index >= all.count) {
        self.recording = NO;
        self.progress.stringValue = @"DONE";
        self.sentence.stringValue = @"Thanks. All takes are saved.";
        self.status.stringValue = [NSString stringWithFormat:@"Run ./bench.py to score them (%@).", self.session.lastPathComponent];
        self.skip.enabled = NO;
        return;
    }
    self.progress.stringValue = [NSString stringWithFormat:@"SENTENCE %lu OF %lu", (unsigned long)self.index + 1, (unsigned long)all.count];
    self.sentence.stringValue = all[self.index];
    self.redo.enabled = self.index > 0;
    self.skip.enabled = YES;
}
- (NSString *)saveTake:(NSData *)wave {
    if (!self.recording) return nil;
    NSString *base = [self.session stringByAppendingPathComponent:[NSString stringWithFormat:@"%02lu", (unsigned long)self.index + 1]];
    [wave writeToFile:[base stringByAppendingPathExtension:@"wav"] atomically:YES];
    [sentences()[self.index] writeToFile:[base stringByAppendingPathExtension:@"txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString *saved = [NSString stringWithFormat:@"Saved %lu of %lu", (unsigned long)self.index + 1, (unsigned long)sentences().count];
    self.status.stringValue = saved;
    self.index++;
    [self show];
    return saved;
}
- (void)redoPrevious:(id)sender {
    (void)sender;
    if (!self.index) return;
    self.index--;
    self.recording = YES;
    self.status.stringValue = @"Read it again.";
    [self show];
}
- (void)skipSentence:(id)sender {
    (void)sender;
    self.index++;
    [self show];
}
- (void)close {
    self.recording = NO;
    [super close];
}
@end
