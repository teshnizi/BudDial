#import "GestureStage.h"
#import <QuartzCore/QuartzCore.h>

// A short scene at real speed, in seconds. A tap touches for 0.2 s; a dictation is held well past
// the 0.55 s hold time; a silent hold passes the 0.95 s mark; text lands 0.4 s after release (the
// measured release-to-paste time); a silent hold is decided 0.2 s after release.
typedef struct { double approach, down, up, leave; } APTouch;   // hand arrives, presses, lifts, is gone
static const APTouch kTouches[] = {
    {0.3, 0.8, 2.9, 3.4},       // hold and talk: "Running five minutes late"
    {5.0, 5.4, 5.6, 6.0},       // tap: Return sends it
    {7.2, 7.6, 9.0, 9.5},       // hold and talk: "See you at noon"
    {10.2, 10.6, 11.8, 12.3},   // silent hold: removes it again
};
enum { kTouchCount = 4, kWordCount = 4, kBars = 5 };
static const double kLoop = 14, kPaste = .4, kDecide = .2, kSilentHold = .95;
static const double kFirstWords[kWordCount] = {1.0, 1.35, 1.6, 1.95}, kSecondWords[kWordCount] = {7.8, 8.0, 8.2, 8.4};
static NSString *const kFirst = @"Running five minutes late", *const kSecond = @"See you at noon";
// Where clicking a gesture starts the scene, and the still frame shown with Reduce Motion.
static const double kPhaseStart[] = {0, 5.0, 9.6}, kStill[] = {2.2, 5.95, 11.4};
static const CGFloat kWidth = 420, kHeight = 184;
static const CGRect kBud = {{14, 44}, {100, 112}}, kField = {{150, 58}, {270, 36}};

static double clamp01(double x) { return x < 0 ? 0 : x > 1 ? 1 : x; }
static double ease(double x) { x = clamp01(x); return x * x * (3 - 2 * x); }
// 0 before a, easing up to 1 over the next d seconds.
static double rise(double t, double a, double d) { return ease((t - a) / d); }
// 1 between a and b, easing in before a and out after b over d seconds.
static double span(double t, double a, double b, double d) { return rise(t, a - d, d) * (1 - rise(t, b, d)); }
static BOOL during(double t, double a, double b) { return t >= a && t < b; }
// The gesture the scene is showing, for highlighting its row.
static APStagePhase gestureAt(double t) { return t < 5.0 ? APStageHoldAndTalk : t < 7.2 ? APStageTap : t < 9.6 ? APStageHoldAndTalk : APStageSilentHold; }

@interface APGestureStage ()
@property CALayer *bud, *hand, *field, *caret, *bubble, *pill, *pillDot;
@property CAShapeLayer *ring, *timerRing;
@property CATextLayer *timer, *caption, *fieldText, *bubbleText, *pillText;
@property NSArray<CALayer *> *bars;
@property CGPoint sensor;
@property id link;   // CADisplayLink, or the still-frame NSTimer under Reduce Motion
@property double origin;
@property APStagePhase phase;
@property BOOL announced;
@end

@implementation APGestureStage
- (instancetype)initWithFrame:(NSRect)frame {
    (void)frame;
    self = [super initWithFrame:NSMakeRect(0, 0, kWidth, kHeight)];
    if (!self) return nil;
    self.layer = [CALayer layer];   // layer-hosting: every element is a plain layer
    self.wantsLayer = YES;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[[self.widthAnchor constraintEqualToConstant:kWidth], [self.heightAnchor constraintEqualToConstant:kHeight]]];
    // The ear sensor sits on the bud's head, in the symbol's upper left.
    self.sensor = CGPointMake(CGRectGetMinX(kBud) + .42 * kBud.size.width, CGRectGetMinY(kBud) + .76 * kBud.size.height);

    self.bud = [CALayer layer];
    self.bud.frame = kBud;
    self.bud.contentsGravity = kCAGravityResizeAspect;
    [self.layer addSublayer:self.bud];
    self.ring = [self circle:19];
    self.timerRing = [self circle:25];
    self.timerRing.lineCap = kCALineCapRound;

    self.timer = [self text:12 weight:NSFontWeightMedium];
    self.timer.font = (__bridge CFTypeRef)[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    self.timer.frame = CGRectMake(self.sensor.x - 50, 18, 100, 16);
    self.timer.alignmentMode = kCAAlignmentCenter;
    self.caption = [self text:14 weight:NSFontWeightRegular];
    self.caption.frame = CGRectMake(128, 148, 292, 20);

    self.field = [CALayer layer];
    self.field.frame = kField;
    self.field.cornerRadius = kField.size.height / 2;
    self.field.borderWidth = 1;
    [self.layer addSublayer:self.field];
    self.fieldText = [self text:13 weight:NSFontWeightRegular];
    self.fieldText.frame = CGRectMake(14, 9, kField.size.width - 28, 18);
    [self.fieldText removeFromSuperlayer];
    [self.field addSublayer:self.fieldText];
    self.caret = [CALayer layer];
    self.caret.bounds = CGRectMake(0, 0, 2, 17);
    self.caret.cornerRadius = 1;
    [self.field addSublayer:self.caret];

    self.bubble = [CALayer layer];
    self.bubble.cornerRadius = 14;
    [self.layer addSublayer:self.bubble];
    self.bubbleText = [self text:13 weight:NSFontWeightRegular];
    [self.bubbleText removeFromSuperlayer];
    [self.bubble addSublayer:self.bubbleText];

    // The same pill Buddial shows at the bottom of the screen.
    self.pill = [CALayer layer];
    self.pill.cornerRadius = 14;
    self.pill.borderWidth = 1;
    self.pill.backgroundColor = [NSColor colorWithWhite:.08 alpha:.88].CGColor;
    self.pill.borderColor = [NSColor colorWithWhite:1 alpha:.14].CGColor;
    [self.layer addSublayer:self.pill];
    self.pillDot = [CALayer layer];
    self.pillDot.frame = CGRectMake(12, 10, 8, 8);
    self.pillDot.cornerRadius = 4;
    [self.pill addSublayer:self.pillDot];
    self.pillText = [self text:12 weight:NSFontWeightSemibold];
    self.pillText.foregroundColor = NSColor.whiteColor.CGColor;
    [self.pillText removeFromSuperlayer];
    [self.pill addSublayer:self.pillText];
    NSMutableArray *bars = [NSMutableArray array];
    for (NSInteger i = 0; i < kBars; i++) {
        CALayer *bar = [CALayer layer];
        bar.cornerRadius = 1.25;
        bar.backgroundColor = [NSColor colorWithWhite:1 alpha:.9].CGColor;
        [self.pill addSublayer:bar];
        [bars addObject:bar];
    }
    self.bars = bars;

    // The hand passes over everything; its fingertip is the anchor point.
    self.hand = [CALayer layer];
    self.hand.bounds = CGRectMake(0, 0, 48, 56);
    self.hand.anchorPoint = CGPointMake(.14, .93);
    self.hand.contentsGravity = kCAGravityResizeAspect;
    self.hand.shadowOpacity = .22;
    self.hand.shadowRadius = 3;
    self.hand.shadowOffset = CGSizeMake(0, -1);
    [self.layer addSublayer:self.hand];

    [self applyColors];
    [self renderAt:kStill[0]];
    return self;
}
- (CAShapeLayer *)circle:(CGFloat)radius {
    CAShapeLayer *layer = [CAShapeLayer layer];
    CGMutablePathRef path = CGPathCreateMutable();
    // Starts at twelve o'clock and runs clockwise, so strokeEnd fills like a timer.
    CGPathAddArc(path, NULL, self.sensor.x, self.sensor.y, radius, M_PI_2, M_PI_2 - 2 * M_PI, true);
    layer.path = path;
    CGPathRelease(path);
    layer.fillColor = NULL;
    layer.lineWidth = 2.5;
    layer.opacity = 0;
    [self.layer addSublayer:layer];
    return layer;
}
- (CATextLayer *)text:(CGFloat)size weight:(NSFontWeight)weight {
    CATextLayer *layer = [CATextLayer layer];
    layer.font = (__bridge CFTypeRef)[NSFont systemFontOfSize:size weight:weight];
    layer.fontSize = size;
    layer.truncationMode = kCATruncationEnd;
    [self.layer addSublayer:layer];
    return layer;
}
- (NSImage *)symbol:(NSString *)name size:(CGFloat)size color:(NSColor *)color {
    NSImageSymbolConfiguration *config = [[NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightRegular]
                                          configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:color]];
    return [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil] imageWithSymbolConfiguration:config];
}
static CGFloat widthOf(NSString *string, CGFloat size, NSFontWeight weight) {
    return ceil([string sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:size weight:weight]}].width);
}

#pragma mark Appearance

- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; [self applyColors]; }
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self applyColors]; }
- (void)applyColors {
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        CGFloat scale = self.window.backingScaleFactor ?: 2;
        self.bud.contents = [[self symbol:@"airpod.gen3.right" size:64 color:NSColor.tertiaryLabelColor] layerContentsForContentsScale:scale];
        self.hand.contents = [[self symbol:@"hand.point.up.left.fill" size:46 color:NSColor.secondaryLabelColor] layerContentsForContentsScale:scale];
        for (CALayer *layer in @[self.bud, self.hand, self.timer, self.caption, self.fieldText, self.bubbleText, self.pillText]) layer.contentsScale = scale;
        self.hand.shadowColor = NSColor.shadowColor.CGColor;
        self.timer.foregroundColor = NSColor.secondaryLabelColor.CGColor;
        self.caption.foregroundColor = NSColor.secondaryLabelColor.CGColor;
        self.field.backgroundColor = NSColor.textBackgroundColor.CGColor;
        self.field.borderColor = NSColor.separatorColor.CGColor;
        self.caret.backgroundColor = NSColor.controlAccentColor.CGColor;
        self.bubble.backgroundColor = NSColor.controlAccentColor.CGColor;
        self.bubbleText.foregroundColor = NSColor.whiteColor.CGColor;
        self.timerRing.strokeColor = NSColor.secondaryLabelColor.CGColor;
    }];
    [self renderAt:self.link ? fmod(CACurrentMediaTime() - self.origin, kLoop) : kStill[self.phase]];
}

#pragma mark Playback

- (BOOL)stillFrames { return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion; }
- (void)start {
    if (self.link) return;
    self.origin = CACurrentMediaTime() - kPhaseStart[self.phase];
    self.announced = NO;   // tell the listener which gesture is showing
    if ([self stillFrames]) {
        __weak APGestureStage *weakSelf = self;
        NSTimer *timer = [NSTimer timerWithTimeInterval:3 repeats:YES block:^(NSTimer *t) { (void)t; [weakSelf renderAt:kStill[(weakSelf.phase + 1) % 3]]; }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
        self.link = timer;
        [self renderAt:kStill[self.phase]];
        return;
    }
    CADisplayLink *link = [self displayLinkWithTarget:self selector:@selector(tick:)];   // follows the screen's refresh rate
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    self.link = link;
    [self renderAt:kPhaseStart[self.phase]];
}
- (void)tick:(CADisplayLink *)link { (void)link; [self renderAt:fmod(CACurrentMediaTime() - self.origin, kLoop)]; }
- (void)stop {
    [self.link invalidate];
    self.link = nil;
}
- (void)showPhase:(APStagePhase)phase {
    self.origin = CACurrentMediaTime() - kPhaseStart[phase];
    self.announced = NO;
    [self renderAt:[self stillFrames] ? kStill[phase] : kPhaseStart[phase]];
}

#pragma mark Drawing

- (void)renderAt:(double)t {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    // The hand: how near it is (0 away, 1 on the sensor) and which touch is pressing now.
    double near = 0;
    NSInteger touching = -1;
    for (NSInteger i = 0; i < kTouchCount; i++) {
        APTouch touch = kTouches[i];
        if (!during(t, touch.approach, touch.leave)) continue;
        near = MIN(rise(t, touch.approach, touch.down - touch.approach), 1 - rise(t, touch.up, touch.leave - touch.up));
        if (during(t, touch.down, touch.up)) touching = i;
    }
    double press = touching >= 0 ? 1 : 0;
    self.hand.position = CGPointMake(self.sensor.x + (1 - near) * 72 + press * 1.5, self.sensor.y - (1 - near) * 64 - press * 1.5);
    self.hand.opacity = clamp01(near * 1.8);

    // Red ring while a hold listens, a quick blue flash for the tap, a filling ring for the silent hold.
    BOOL silent = touching == 3, tap = touching == 1;
    self.ring.strokeColor = (tap ? NSColor.controlAccentColor : NSColor.systemRedColor).CGColor;
    self.ring.opacity = touching >= 0 && !silent ? 1 : 0;
    self.timerRing.opacity = silent ? 1 : 0;
    self.timerRing.strokeEnd = silent ? clamp01((t - kTouches[3].down) / kSilentHold) : 0;

    // How long the finger has been down, counted live and left up briefly after release.
    double shown = 0;
    self.timer.string = @"";
    for (NSInteger i = 0; i < kTouchCount; i++) {
        APTouch touch = kTouches[i];
        if (!during(t, touch.down, touch.up + .9)) continue;
        self.timer.string = [NSString stringWithFormat:@"%.1f s", MIN(t, touch.up) - touch.down];
        shown = span(t, touch.down, touch.up + .7, .12);
    }
    self.timer.opacity = shown;

    // What you say, word by word.
    NSString *said = nil;
    double saidOpacity = 0;
    if (during(t, kFirstWords[0], kTouches[0].up + kPaste + .3)) { said = [self words:kFirst until:t starts:kFirstWords]; saidOpacity = 1 - rise(t, kTouches[0].up + kPaste, .3); }
    if (during(t, kSecondWords[0], kTouches[2].up + kPaste + .3)) { said = [self words:kSecond until:t starts:kSecondWords]; saidOpacity = 1 - rise(t, kTouches[2].up + kPaste, .3); }
    if (silent) { said = @"(say nothing)"; saidOpacity = 1; }
    self.caption.string = said ?: @"";
    self.caption.opacity = saidOpacity;

    // The message box: the first sentence lands, the tap sends it up, the second lands and is removed.
    double firstLands = kTouches[0].up + kPaste, sent = kTouches[1].up;
    double secondLands = kTouches[2].up + kPaste, removed = kTouches[3].up + kDecide;
    NSString *typed = during(t, firstLands, sent) ? kFirst : during(t, secondLands, removed) ? kSecond : @"";
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self.fieldText.string = typed.length ? typed : @"Message";
        self.fieldText.foregroundColor = (typed.length ? NSColor.labelColor : NSColor.placeholderTextColor).CGColor;
    }];
    self.caret.position = CGPointMake(14 + (typed.length ? widthOf(typed, 13, NSFontWeightRegular) + 2 : 0), kField.size.height / 2);

    CGFloat bubbleWidth = widthOf(kFirst, 13, NSFontWeightRegular) + 24;
    double rising = rise(t, sent, .3);
    self.bubble.bounds = CGRectMake(0, 0, bubbleWidth, 28);
    self.bubble.position = CGPointMake(kWidth - bubbleWidth / 2, CGRectGetMidY(kField) + rising * 44);
    self.bubble.opacity = t >= sent ? 1 - rise(t, kLoop - .4, .35) : 0;
    self.bubbleText.frame = CGRectMake(12, 6, bubbleWidth - 24, 17);
    self.bubbleText.string = kFirst;

    // The pill: what Buddial shows at each moment.
    NSString *status = nil;
    NSColor *dot = NSColor.systemBlueColor;
    BOOL listening = NO;
    if (touching >= 0 && !tap) { status = @"Listening"; dot = NSColor.systemRedColor; listening = YES; }
    else if (during(t, kTouches[0].up, firstLands) || during(t, kTouches[2].up, secondLands)) status = @"Transcribing…";
    else if (during(t, firstLands, firstLands + .8) || during(t, secondLands, secondLands + .8)) { status = @"Inserted"; dot = NSColor.systemGreenColor; }
    else if (during(t, sent, sent + .8)) status = @"Sent ↵";
    else if (during(t, removed, removed + .8)) status = @"Deleted";
    BOOL speaking = during(t, kFirstWords[0], kFirstWords[kWordCount - 1] + .45) || during(t, kSecondWords[0], kSecondWords[kWordCount - 1] + .4);
    CGFloat textWidth = status ? widthOf(status, 12, NSFontWeightSemibold) + 4 : 0, barsWidth = listening ? 5 * 2.5 + 4 * 2.5 + 10 : 0;
    self.pill.bounds = CGRectMake(0, 0, 26 + textWidth + barsWidth + 12, 28);
    self.pill.position = CGPointMake(CGRectGetMidX(kField), 22);
    self.pill.opacity = status ? 1 : 0;
    self.pillDot.backgroundColor = dot.CGColor;
    self.pillText.string = status ?: @"";
    self.pillText.frame = CGRectMake(26, 6, textWidth, 16);
    [self.bars enumerateObjectsUsingBlock:^(CALayer *bar, NSUInteger i, BOOL *stop) {
        (void)stop;
        double level = speaking && listening ? .3 + .7 * fabs(sin(t * (7 + i * 2.1) + i * 1.4)) : .15;
        CGFloat height = 2 + 12 * level;
        bar.hidden = !listening;
        bar.frame = CGRectMake(26 + textWidth + 8 + i * 5, 14 - height / 2, 2.5, height);
    }];
    [CATransaction commit];

    APStagePhase phase = gestureAt(t);
    if (!self.announced || phase != self.phase) {
        self.phase = phase;
        self.announced = YES;
        if (self.onPhase) self.onPhase(phase);
    }
}
- (NSString *)words:(NSString *)sentence until:(double)t starts:(const double *)starts {
    NSArray<NSString *> *words = [sentence componentsSeparatedByString:@" "];
    NSInteger count = 0;
    while (count < kWordCount && t >= starts[count]) count++;
    NSString *spoken = [[words subarrayWithRange:NSMakeRange(0, count)] componentsJoinedByString:@" "];
    return [NSString stringWithFormat:@"“%@%@", spoken, count == kWordCount ? @"”" : @""];
}
@end
