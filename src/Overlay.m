#import "Overlay.h"
#import <QuartzCore/QuartzCore.h>

@interface APLevelBars : NSView
@property double level;   // 0...1
@end
@implementation APLevelBars
- (BOOL)isFlipped { return NO; }
- (void)drawRect:(NSRect)rect {
    (void)rect;
    static const double shape[5] = {.55, .85, 1, .8, .5};
    CGFloat width = 3, spacing = 3, height = NSHeight(self.bounds);
    [[NSColor colorWithWhite:1 alpha:.9] setFill];
    for (int i = 0; i < 5; i++) {
        CGFloat h = MAX(3, height * MIN(1, self.level * shape[i] * 1.15));
        NSRect bar = NSMakeRect(i * (width + spacing), (height - h) / 2, width, h);
        [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:1.5 yRadius:1.5] fill];
    }
}
@end

@interface APOverlay ()
@property NSView *pill;
@property NSView *dot;
@property NSTextField *label;
@property APLevelBars *bars;
@property NSUInteger generation;
@end

// The pill goes on the screen the text goes to: the one holding the front app's frontmost window.
// Not the mouse's screen: dictating leaves the mouse wherever it was, often on another display.
static NSScreen *APScreenOfFrontWindow(void) {
    pid_t front = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    CGFloat primaryTop = NSMaxY(NSScreen.screens.firstObject.frame);   // window bounds count down from here
    for (NSDictionary *window in windows) {   // front to back
        if ([window[(id)kCGWindowOwnerPID] intValue] != front || [window[(id)kCGWindowLayer] intValue] != 0) continue;
        if ([window[(id)kCGWindowAlpha] doubleValue] <= 0) continue;
        CGRect bounds;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(id)kCGWindowBounds], &bounds)) continue;
        if (bounds.size.width < 100 || bounds.size.height < 60) continue;   // title strips and helper windows
        NSRect rect = NSMakeRect(bounds.origin.x, primaryTop - CGRectGetMaxY(bounds), bounds.size.width, bounds.size.height);
        NSScreen *best = nil;
        CGFloat bestArea = 0;
        for (NSScreen *candidate in NSScreen.screens) {
            NSRect overlap = NSIntersectionRect(rect, candidate.frame);
            if (NSWidth(overlap) * NSHeight(overlap) > bestArea) { bestArea = NSWidth(overlap) * NSHeight(overlap); best = candidate; }
        }
        if (best) return best;
    }
    return NSScreen.mainScreen;
}

@implementation APOverlay
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
- (instancetype)init {
    self = [super initWithContentRect:NSMakeRect(0, 0, 160, 36) styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    if (!self) return nil;
    self.opaque = NO;
    self.backgroundColor = NSColor.clearColor;
    self.hasShadow = YES;
    self.level = NSStatusWindowLevel;
    self.ignoresMouseEvents = YES;
    self.hidesOnDeactivate = NO;
    self.releasedWhenClosed = NO;
    self.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
    self.pill = [[NSView alloc] initWithFrame:self.contentView.bounds];
    self.pill.wantsLayer = YES;
    self.pill.layer.backgroundColor = [NSColor colorWithWhite:.08 alpha:.88].CGColor;
    self.pill.layer.cornerRadius = 18;
    self.pill.layer.borderWidth = 1;
    self.pill.layer.borderColor = [NSColor colorWithWhite:1 alpha:.14].CGColor;
    self.pill.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.contentView addSubview:self.pill];
    self.dot = [[NSView alloc] initWithFrame:NSMakeRect(15, 13, 10, 10)];
    self.dot.wantsLayer = YES;
    self.dot.layer.cornerRadius = 5;
    [self.pill addSubview:self.dot];
    self.label = [NSTextField labelWithString:@""];
    self.label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    self.label.textColor = NSColor.whiteColor;
    [self.pill addSubview:self.label];
    self.bars = [[APLevelBars alloc] initWithFrame:NSMakeRect(0, 9, 27, 18)];
    [self.pill addSubview:self.bars];
    self.alphaValue = 0;
    return self;
}
- (void)present:(NSString *)text color:(NSColor *)color bars:(BOOL)bars {
    self.generation++;
    self.label.stringValue = text;
    [self.label sizeToFit];
    self.dot.layer.backgroundColor = color.CGColor;
    self.bars.hidden = !bars;
    CGFloat x = 33, labelWidth = text.length ? NSWidth(self.label.frame) : 0;
    self.label.frame = NSMakeRect(x, (36 - NSHeight(self.label.frame)) / 2, labelWidth, NSHeight(self.label.frame));
    CGFloat width = x + labelWidth + (bars ? (text.length ? 10 : 0) + 27 : 0) + 16;
    self.bars.frame = NSMakeRect(x + labelWidth + (text.length ? 10 : 0), 9, 27, 18);
    NSScreen *screen = APScreenOfFrontWindow();
    NSRect visible = screen.visibleFrame;
    [self setFrame:NSMakeRect(round(NSMidX(visible) - width / 2), NSMinY(visible) + 28, width, 36) display:YES];
    [self orderFrontRegardless];
    // Supersede any fade-out still running from a previous hide.
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) { context.duration = 0; self.animator.alphaValue = 1; }];
}
- (void)showListening { [self present:@"Listening" color:NSColor.systemRedColor bars:YES]; }
- (void)showWorking:(NSString *)text { [self present:text color:NSColor.systemBlueColor bars:NO]; }
- (void)showHint:(NSString *)text color:(NSColor *)color { [self present:text color:color bars:YES]; }
- (void)setLevel:(double)db {
    if (self.bars.hidden) return;
    self.bars.level = MIN(1, MAX(0, (db + 55) / 40));
    self.bars.needsDisplay = YES;
}
- (void)flash:(NSString *)text tone:(APOverlayTone)tone {
    [self flash:text tone:tone seconds:tone == APOverlayToneError ? 2.2 : .9];
}
- (void)flash:(NSString *)text tone:(APOverlayTone)tone seconds:(double)seconds {
    NSColor *color = tone == APOverlayToneSuccess ? NSColor.systemGreenColor : tone == APOverlayToneError ? NSColor.systemOrangeColor : [NSColor colorWithWhite:.75 alpha:1];
    [self present:text color:color bars:NO];
    NSUInteger token = self.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token == self.generation) [self hide];
    });
}
- (void)hide {
    self.generation++;
    NSUInteger token = self.generation;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = .18;
        self.animator.alphaValue = 0;
    } completionHandler:^{
        if (token == self.generation) [self orderOut:nil];
    }];
}
@end
