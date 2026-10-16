#import "OnboardingWindow.h"
#import "GestureStage.h"
#import <AVFoundation/AVFoundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <ServiceManagement/ServiceManagement.h>

static const CGFloat kWidth = 500, kInset = 40, kContent = kWidth - 2 * kInset, kTop = 46;
enum { kWelcome, kPermissions, kAirPods, kPractice, kDone, kSteps };

static NSTextField *label(NSString *string, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *field = [NSTextField labelWithString:string];
    field.font = [NSFont systemFontOfSize:size weight:weight];
    field.textColor = color;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    return field;
}
static NSTextField *paragraph(NSString *string, CGFloat size, NSColor *color, CGFloat width) {
    NSTextField *field = [NSTextField wrappingLabelWithString:string];
    field.font = [NSFont systemFontOfSize:size];
    field.textColor = color;
    field.selectable = NO;
    field.preferredMaxLayoutWidth = width;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    return field;
}
static NSStackView *stack(NSArray<NSView *> *views, NSUserInterfaceLayoutOrientation orientation, CGFloat spacing) {
    NSStackView *view = [NSStackView stackViewWithViews:views];
    view.orientation = orientation;
    view.spacing = spacing;
    view.alignment = orientation == NSUserInterfaceLayoutOrientationVertical ? NSLayoutAttributeLeading : NSLayoutAttributeCenterY;
    view.translatesAutoresizingMaskIntoConstraints = NO;
    return view;
}
static NSImageView *symbol(NSString *name, CGFloat size, NSColor *tint) {
    NSImageView *view = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]];
    view.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightRegular];
    view.contentTintColor = tint;
    view.translatesAutoresizingMaskIntoConstraints = NO;
    return view;
}
static NSBox *box(NSColor *fill, CGFloat radius, BOOL border) {
    NSBox *view = [NSBox new];
    view.boxType = NSBoxCustom;
    view.titlePosition = NSNoTitle;
    view.cornerRadius = radius;
    view.borderWidth = border ? 1 : 0;
    view.borderColor = NSColor.separatorColor;
    view.fillColor = fill;
    view.contentViewMargins = NSZeroSize;
    view.translatesAutoresizingMaskIntoConstraints = NO;
    return view;
}
static void pin(NSView *view, NSView *inside, NSEdgeInsets insets) {
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:inside.leadingAnchor constant:insets.left],
        [view.trailingAnchor constraintEqualToAnchor:inside.trailingAnchor constant:-insets.right],
        [view.topAnchor constraintEqualToAnchor:inside.topAnchor constant:insets.top],
        [view.bottomAnchor constraintEqualToAnchor:inside.bottomAnchor constant:-insets.bottom]]];
}
// A symbol on a tinted rounded square, as in System Settings.
static NSView *tile(NSString *name) {
    NSBox *square = box([NSColor.controlAccentColor colorWithAlphaComponent:.13], 8, NO);
    NSImageView *image = symbol(name, 14, NSColor.controlAccentColor);
    [square.contentView addSubview:image];
    [NSLayoutConstraint activateConstraints:@[
        [square.widthAnchor constraintEqualToConstant:30], [square.heightAnchor constraintEqualToConstant:30],
        [image.centerXAnchor constraintEqualToAnchor:square.contentView.centerXAnchor],
        [image.centerYAnchor constraintEqualToAnchor:square.contentView.centerYAnchor]]];
    return square;
}
static NSString *megabytes(long long bytes) { return [NSString stringWithFormat:@"%.0f MB", bytes / 1e6]; }

@interface APOnboardingWindow () <NSWindowDelegate, NSTextViewDelegate>
@property(weak) id<APOnboardingHost> host;
@property NSInteger step;
@property NSArray<NSView *> *pages;
@property NSArray<NSBox *> *dots;
@property NSButton *backButton, *nextButton;
@property NSTimer *timer;
@property NSButton *micButton, *accessibilityButton;
@property NSView *micDone, *accessibilityDone;
@property NSTextField *accessibilityHint;
@property BOOL askedAccessibility;
@property NSPopUpButton *devicePopup;
@property NSBox *touchCircle;
@property NSImageView *touchHand;
@property NSTextField *touchStatus;
@property BOOL touched;
@property NSBox *downloadBox;
@property NSTextField *downloadLabel;
@property NSProgressIndicator *downloadBar;
@property NSButton *retryButton;
@property NSStackView *bubbles;
@property NSTextField *bubblesEmpty, *placeholder;
@property NSTextView *practice;
@property NSArray<NSImageView *> *checks;
@property BOOL said, sent, undone;
@property NSSwitch *loginSwitch;
@property APGestureStage *stage;
@property NSArray<NSView *> *gestureRows;
@end

@implementation APOnboardingWindow
- (instancetype)initWithHost:(id<APOnboardingHost>)host {
    self = [super initWithContentRect:NSMakeRect(0, 0, kWidth, 600)
                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView
                              backing:NSBackingStoreBuffered defer:NO];
    if (!self) return nil;
    _host = host;
    self.title = @"Welcome to BudDial";
    self.titleVisibility = NSWindowTitleHidden;
    self.titlebarAppearsTransparent = YES;
    self.movableByWindowBackground = YES;
    self.releasedWhenClosed = NO;
    self.delegate = self;

    self.pages = @[[self welcomePage], [self permissionsPage], [self airPodsPage], [self practicePage], [self donePage]];
    NSView *holder = [NSView new];
    holder.translatesAutoresizingMaskIntoConstraints = NO;
    CGFloat tallest = 0;
    for (NSView *page in self.pages) {
        [holder addSubview:page];
        [NSLayoutConstraint activateConstraints:@[
            [page.leadingAnchor constraintEqualToAnchor:holder.leadingAnchor constant:kInset],
            [page.trailingAnchor constraintEqualToAnchor:holder.trailingAnchor constant:-kInset],
            [page.topAnchor constraintEqualToAnchor:holder.topAnchor]]];
        tallest = MAX(tallest, page.fittingSize.height);
    }
    NSView *bar = [self navigationBar];
    [self.contentView addSubview:holder];
    [self.contentView addSubview:bar];
    [NSLayoutConstraint activateConstraints:@[
        [holder.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [holder.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [holder.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:kTop],
        [holder.heightAnchor constraintEqualToConstant:ceil(tallest)],
        [bar.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:kInset],
        [bar.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-kInset],
        [bar.topAnchor constraintEqualToAnchor:holder.bottomAnchor constant:30],
        [bar.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-22],
        [self.contentView.widthAnchor constraintEqualToConstant:kWidth]]];
    [self setContentSize:NSMakeSize(kWidth, kTop + ceil(tallest) + 30 + bar.fittingSize.height + 22)];
    [self show:kWelcome];
    return self;
}

#pragma mark Layout

- (NSStackView *)pageWithSymbol:(NSString *)name tint:(NSColor *)tint title:(NSString *)title subtitle:(NSString *)subtitle {
    return [self pageWithHero:symbol(name, 40, tint) title:title subtitle:subtitle];
}
- (NSStackView *)pageWithHero:(NSView *)hero title:(NSString *)title subtitle:(NSString *)subtitle {
    NSTextField *subtitleField = paragraph(subtitle, 13, NSColor.secondaryLabelColor, kContent);
    subtitleField.alignment = NSTextAlignmentCenter;
    NSStackView *head = stack(@[hero, label(title, 22, NSFontWeightSemibold, NSColor.labelColor), subtitleField], NSUserInterfaceLayoutOrientationVertical, 6);
    head.alignment = NSLayoutAttributeCenterX;
    [head setCustomSpacing:14 afterView:hero];
    NSStackView *page = stack(@[head], NSUserInterfaceLayoutOrientationVertical, 24);
    page.alignment = NSLayoutAttributeCenterX;
    return page;
}
- (void)add:(NSView *)view to:(NSStackView *)page {
    [page addArrangedSubview:view];
    [view.widthAnchor constraintEqualToConstant:kContent].active = YES;
}
// Symbol tile, a title with a line of explanation, and an optional control on the right.
- (NSView *)item:(NSString *)name title:(NSString *)title text:(NSString *)text accessory:(NSView *)accessory width:(CGFloat)width {
    NSView *icon = tile(name);
    NSStackView *words = stack(@[label(title, 13, NSFontWeightSemibold, NSColor.labelColor),
                                 paragraph(text, 12, NSColor.secondaryLabelColor, width - 42 - (accessory ? 130 : 0))], NSUserInterfaceLayoutOrientationVertical, 2);
    NSView *row = [NSView new];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:icon];
    [row addSubview:words];
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [icon.topAnchor constraintEqualToAnchor:words.topAnchor constant:1],
        [words.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:12],
        [words.topAnchor constraintEqualToAnchor:row.topAnchor],
        [words.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:32]]];
    if (accessory) {
        accessory.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:accessory];
        [NSLayoutConstraint activateConstraints:@[
            [accessory.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [accessory.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [words.trailingAnchor constraintLessThanOrEqualToAnchor:accessory.leadingAnchor constant:-12]]];
    } else {
        [words.trailingAnchor constraintLessThanOrEqualToAnchor:row.trailingAnchor].active = YES;
    }
    return row;
}
// Rows in a rounded panel with hairlines between them, as in Settings.
- (NSBox *)panel:(NSArray<NSView *> *)rows {
    NSBox *panel = box([NSColor.labelColor colorWithAlphaComponent:.035], 10, YES);
    NSStackView *list = stack(@[], NSUserInterfaceLayoutOrientationVertical, 12);
    [panel.contentView addSubview:list];
    pin(list, panel.contentView, NSEdgeInsetsMake(14, 14, 14, 14));
    [rows enumerateObjectsUsingBlock:^(NSView *row, NSUInteger index, BOOL *stop) {
        (void)stop;
        if (index) {
            NSBox *line = [NSBox new];
            line.boxType = NSBoxSeparator;
            line.translatesAutoresizingMaskIntoConstraints = NO;
            [list addArrangedSubview:line];
            [line.widthAnchor constraintEqualToAnchor:list.widthAnchor].active = YES;
        }
        [list addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:list.widthAnchor].active = YES;
    }];
    return panel;
}
- (NSView *)allowedMark {
    return stack(@[symbol(@"checkmark.circle.fill", 13, NSColor.systemGreenColor), label(@"Allowed", 12, NSFontWeightRegular, NSColor.secondaryLabelColor)],
                 NSUserInterfaceLayoutOrientationHorizontal, 5);
}
- (NSView *)navigationBar {
    NSMutableArray<NSBox *> *dots = [NSMutableArray array];
    for (NSInteger i = 0; i < kSteps; i++) {
        NSBox *dot = box(NSColor.quaternaryLabelColor, 3.5, NO);
        [NSLayoutConstraint activateConstraints:@[[dot.widthAnchor constraintEqualToConstant:7], [dot.heightAnchor constraintEqualToConstant:7]]];
        [dots addObject:dot];
    }
    self.dots = dots;
    self.backButton = [NSButton buttonWithTitle:@"Back" target:self action:@selector(back:)];
    self.nextButton = [NSButton buttonWithTitle:@"Continue" target:self action:@selector(next:)];
    [self.nextButton.widthAnchor constraintGreaterThanOrEqualToConstant:96].active = YES;
    NSStackView *buttons = stack(@[self.backButton, self.nextButton], NSUserInterfaceLayoutOrientationHorizontal, 10);
    NSStackView *progress = stack(dots, NSUserInterfaceLayoutOrientationHorizontal, 7);
    NSView *bar = [NSView new];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:progress];
    [bar addSubview:buttons];
    [NSLayoutConstraint activateConstraints:@[
        [progress.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [progress.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [buttons.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],
        [buttons.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [buttons.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor]]];
    return bar;
}

#pragma mark Pages

- (NSView *)welcomePage {
    // The stage plays each gesture in turn; the row it is showing stays bright.
    self.stage = [APGestureStage new];
    NSStackView *page = [self pageWithHero:self.stage title:@"Welcome to BudDial"
                                  subtitle:@"Type with your voice by holding an AirPod. Works in any app."];
    self.gestureRows = @[
        [self item:@"mic.fill" title:@"Hold and talk" text:@"Cover a bud's sensor with your finger and speak. Let go, and the words appear at your cursor." accessory:nil width:kContent],
        [self item:@"return" title:@"Tap to send" text:@"A quick tap presses Return." accessory:nil width:kContent],
        [self item:@"delete.backward" title:@"Hold silently to undo" text:@"Cover it for a second without talking to remove what you just said." accessory:nil width:kContent]];
    NSStackView *gestures = stack(self.gestureRows, NSUserInterfaceLayoutOrientationVertical, 18);
    for (NSView *row in self.gestureRows) {
        [row.widthAnchor constraintEqualToConstant:kContent].active = YES;
        [row addGestureRecognizer:[[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(gestureRowClicked:)]];
    }
    __weak APOnboardingWindow *weakSelf = self;
    self.stage.onPhase = ^(APStagePhase phase) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = .25;
            [weakSelf.gestureRows enumerateObjectsUsingBlock:^(NSView *row, NSUInteger index, BOOL *stop) {
                (void)stop;
                row.animator.alphaValue = (APStagePhase)index == phase ? 1 : .4;
            }];
        }];
    };
    [self add:gestures to:page];
    NSStackView *privacy = stack(@[symbol(@"lock.fill", 10, NSColor.tertiaryLabelColor),
                                   label(@"Speech becomes text on this Mac. Nothing is uploaded.", 11, NSFontWeightRegular, NSColor.tertiaryLabelColor)],
                                 NSUserInterfaceLayoutOrientationHorizontal, 5);
    [page addArrangedSubview:privacy];
    [page setCustomSpacing:28 afterView:gestures];
    return page;
}
- (NSView *)permissionsPage {
    NSStackView *page = [self pageWithSymbol:@"hand.raised.fill" tint:NSColor.controlAccentColor title:@"Two permissions"
                                    subtitle:@"BudDial needs to hear you and to type for you."];
    self.micButton = [NSButton buttonWithTitle:@"Allow" target:self action:@selector(allowMicrophone:)];
    self.accessibilityButton = [NSButton buttonWithTitle:@"Open Settings…" target:self action:@selector(allowAccessibility:)];
    self.micDone = [self allowedMark];
    self.accessibilityDone = [self allowedMark];
    CGFloat inner = kContent - 28;
    NSBox *panel = [self panel:@[
        [self item:@"mic.fill" title:@"Microphone" text:@"Hears you only while you hold a bud." accessory:stack(@[self.micButton, self.micDone], NSUserInterfaceLayoutOrientationHorizontal, 0) width:inner],
        [self item:@"keyboard" title:@"Accessibility" text:@"Pastes the text and presses Return in the app you're using." accessory:stack(@[self.accessibilityButton, self.accessibilityDone], NSUserInterfaceLayoutOrientationHorizontal, 0) width:inner]]];
    [self add:panel to:page];
    self.accessibilityHint = paragraph(@"In System Settings, turn on BudDial in the list, then come back here.", 12, NSColor.secondaryLabelColor, kContent);
    self.accessibilityHint.alignment = NSTextAlignmentCenter;
    self.accessibilityHint.hidden = YES;
    [self add:self.accessibilityHint to:page];
    return page;
}
- (NSView *)airPodsPage {
    NSStackView *page = [self pageWithSymbol:@"airpods" tint:NSColor.controlAccentColor title:@"Choose your AirPods"
                                    subtitle:@"BudDial listens to one bud at a time. While both are in your ears, it stays out of the way."];
    self.devicePopup = [NSPopUpButton new];
    self.devicePopup.target = self;
    self.devicePopup.action = @selector(deviceChosen:);
    self.devicePopup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.devicePopup.widthAnchor constraintEqualToConstant:280].active = YES;
    [page addArrangedSubview:self.devicePopup];

    self.touchCircle = box(NSColor.quaternaryLabelColor, 22, NO);
    self.touchHand = symbol(@"hand.point.up.left.fill", 18, NSColor.secondaryLabelColor);
    [self.touchCircle.contentView addSubview:self.touchHand];
    [NSLayoutConstraint activateConstraints:@[
        [self.touchCircle.widthAnchor constraintEqualToConstant:44], [self.touchCircle.heightAnchor constraintEqualToConstant:44],
        [self.touchHand.centerXAnchor constraintEqualToAnchor:self.touchCircle.contentView.centerXAnchor],
        [self.touchHand.centerYAnchor constraintEqualToAnchor:self.touchCircle.contentView.centerYAnchor]]];
    self.touchStatus = paragraph(@"", 12, NSColor.secondaryLabelColor, kContent - 28 - 58);
    NSStackView *words = stack(@[label(@"Try a touch", 13, NSFontWeightSemibold, NSColor.labelColor), self.touchStatus], NSUserInterfaceLayoutOrientationVertical, 2);
    NSStackView *touch = stack(@[self.touchCircle, words], NSUserInterfaceLayoutOrientationHorizontal, 14);
    [self add:[self panel:@[touch]] to:page];
    return page;
}
- (NSView *)practicePage {
    NSStackView *page = [self pageWithSymbol:@"waveform" tint:NSColor.controlAccentColor title:@"Try it here"
                                    subtitle:@"Your words land in the box below, just like in any other app."];
    // One-time model download, shown until the speech engine is ready.
    self.downloadLabel = paragraph(@"", 12, NSColor.secondaryLabelColor, kContent - 28);
    self.downloadBar = [NSProgressIndicator new];
    self.downloadBar.style = NSProgressIndicatorStyleBar;
    self.downloadBar.controlSize = NSControlSizeSmall;
    self.downloadBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.retryButton = [NSButton buttonWithTitle:@"Try Again" target:self action:@selector(retryDownload:)];
    self.retryButton.controlSize = NSControlSizeSmall;
    NSStackView *download = stack(@[self.downloadLabel, self.downloadBar, self.retryButton], NSUserInterfaceLayoutOrientationVertical, 8);
    [self.downloadBar.widthAnchor constraintEqualToAnchor:download.widthAnchor].active = YES;
    self.downloadBox = [self panel:@[download]];
    [self add:self.downloadBox to:page];

    // A small chat: BudDial pastes into the field, a tap sends it up as a bubble.
    NSBox *chat = box(NSColor.textBackgroundColor, 10, YES);
    NSView *thread = [NSView new];
    thread.translatesAutoresizingMaskIntoConstraints = NO;
    thread.wantsLayer = YES;
    thread.layer.masksToBounds = YES;
    self.bubbles = stack(@[], NSUserInterfaceLayoutOrientationVertical, 6);
    self.bubbles.alignment = NSLayoutAttributeTrailing;
    self.bubblesEmpty = label(@"Sent messages show up here", 12, NSFontWeightRegular, NSColor.tertiaryLabelColor);
    [thread addSubview:self.bubbles];
    [thread addSubview:self.bubblesEmpty];
    NSBox *line = [NSBox new];
    line.boxType = NSBoxSeparator;
    line.translatesAutoresizingMaskIntoConstraints = NO;
    NSScrollView *scroll = [NSTextView scrollableTextView];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = NO;
    self.practice = scroll.documentView;
    self.practice.delegate = self;
    self.practice.richText = NO;
    self.practice.drawsBackground = NO;
    self.practice.font = [NSFont systemFontOfSize:14];
    self.practice.textContainerInset = NSMakeSize(6, 9);
    self.practice.automaticQuoteSubstitutionEnabled = NO;
    self.practice.automaticSpellingCorrectionEnabled = NO;
    self.placeholder = label(@"Hold a bud and say “Hello, BudDial.”", 14, NSFontWeightRegular, NSColor.placeholderTextColor);
    [chat.contentView addSubview:thread];
    [chat.contentView addSubview:line];
    [chat.contentView addSubview:scroll];
    [chat.contentView addSubview:self.placeholder];
    [NSLayoutConstraint activateConstraints:@[
        [thread.leadingAnchor constraintEqualToAnchor:chat.contentView.leadingAnchor constant:12],
        [thread.trailingAnchor constraintEqualToAnchor:chat.contentView.trailingAnchor constant:-12],
        [thread.topAnchor constraintEqualToAnchor:chat.contentView.topAnchor constant:10],
        [thread.heightAnchor constraintEqualToConstant:60],
        [self.bubbles.trailingAnchor constraintEqualToAnchor:thread.trailingAnchor],
        [self.bubbles.bottomAnchor constraintEqualToAnchor:thread.bottomAnchor],
        [self.bubbles.leadingAnchor constraintGreaterThanOrEqualToAnchor:thread.leadingAnchor constant:40],
        [self.bubblesEmpty.centerXAnchor constraintEqualToAnchor:thread.centerXAnchor],
        [self.bubblesEmpty.centerYAnchor constraintEqualToAnchor:thread.centerYAnchor],
        [line.leadingAnchor constraintEqualToAnchor:chat.contentView.leadingAnchor],
        [line.trailingAnchor constraintEqualToAnchor:chat.contentView.trailingAnchor],
        [line.topAnchor constraintEqualToAnchor:thread.bottomAnchor constant:10],
        [scroll.leadingAnchor constraintEqualToAnchor:chat.contentView.leadingAnchor constant:6],
        [scroll.trailingAnchor constraintEqualToAnchor:chat.contentView.trailingAnchor constant:-6],
        [scroll.topAnchor constraintEqualToAnchor:line.bottomAnchor],
        [scroll.heightAnchor constraintEqualToConstant:40],
        [scroll.bottomAnchor constraintEqualToAnchor:chat.contentView.bottomAnchor],
        [self.placeholder.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor constant:11],
        [self.placeholder.topAnchor constraintEqualToAnchor:scroll.topAnchor constant:9]]];
    [self add:chat to:page];

    NSMutableArray<NSImageView *> *checks = [NSMutableArray array];
    NSStackView *steps = stack(@[], NSUserInterfaceLayoutOrientationVertical, 8);
    for (NSString *text in @[@"Hold a bud, say something, let go.", @"Tap the bud to send it.", @"Say something else, then hold silently for a second to undo it."]) {
        NSImageView *check = symbol(@"circle", 14, NSColor.tertiaryLabelColor);
        [checks addObject:check];
        [steps addArrangedSubview:stack(@[check, label(text, 13, NSFontWeightRegular, NSColor.labelColor)], NSUserInterfaceLayoutOrientationHorizontal, 8)];
    }
    self.checks = checks;
    [self add:steps to:page];
    [page setCustomSpacing:16 afterView:chat];
    [page setCustomSpacing:16 afterView:self.downloadBox];
    return page;
}
- (NSView *)donePage {
    NSStackView *page = [self pageWithSymbol:@"checkmark.circle.fill" tint:NSColor.systemGreenColor title:@"You're all set"
                                    subtitle:@"Hold a bud and talk, in any app."];
    self.loginSwitch = [NSSwitch new];
    self.loginSwitch.state = NSControlStateValueOn;
    CGFloat inner = kContent - 28;
    [self add:[self panel:@[
        [self item:@"menubar.rectangle" title:@"In your menu bar" text:@"Click the AirPods icon for settings, or to disable or quit BudDial." accessory:nil width:inner],
        [self item:@"power" title:@"Open at login" text:@"Start BudDial when you log in." accessory:self.loginSwitch width:inner]]] to:page];
    return page;
}

#pragma mark Navigation

- (void)show:(NSInteger)step {
    self.step = step;
    [self.pages enumerateObjectsUsingBlock:^(NSView *page, NSUInteger index, BOOL *stop) { (void)stop; page.hidden = (NSInteger)index != step; }];
    [self.dots enumerateObjectsUsingBlock:^(NSBox *dot, NSUInteger index, BOOL *stop) {
        (void)stop;
        dot.fillColor = (NSInteger)index == step ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor;
    }];
    self.backButton.hidden = step == kWelcome;
    self.nextButton.title = step == kWelcome ? @"Get Started" : step == kDone ? @"Done" : @"Continue";
    // On the practice step Return belongs to the text box: BudDial's tap presses it there.
    self.nextButton.keyEquivalent = step == kPractice ? @"" : @"\r";
    if (step == kWelcome) [self.stage start];
    else [self.stage stop];
    if (step == kAirPods) [self reloadDevices];
    if (step == kPractice) [self makeFirstResponder:self.practice];
    [self refresh];
}
- (void)next:(id)sender {
    (void)sender;
    if (self.step == kDone) { [self finish]; return; }
    [self show:self.step + 1];
}
- (void)back:(id)sender {
    (void)sender;
    if (self.step > kWelcome) [self show:self.step - 1];
}
- (BOOL)practicing { return self.visible && self.step == kPractice; }
- (void)present {
    [self show:self.step];
    if (!self.visible) [self center];
    [NSApp activateIgnoringOtherApps:YES];
    [self makeKeyAndOrderFront:nil];
    if (!self.timer) {
        __weak APOnboardingWindow *weakSelf = self;
        self.timer = [NSTimer timerWithTimeInterval:.2 repeats:YES block:^(NSTimer *timer) { (void)timer; [weakSelf refresh]; }];
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    }
}
- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    [self.timer invalidate];
    [self.stage stop];
    self.timer = nil;
}
- (void)finish {
    SMAppService *service = SMAppService.mainAppService;
    BOOL wanted = self.loginSwitch.state == NSControlStateValueOn, enabled = service.status == SMAppServiceStatusEnabled;
    if (wanted && !enabled) [service registerAndReturnError:nil];
    if (!wanted && enabled) [service unregisterAndReturnError:nil];
    [self.host finishOnboarding];
    [self close];
}

#pragma mark Live state

- (void)refresh {
    NSDictionary *status = [self.host liveStatus];
    BOOL microphone = [status[@"microphoneAllowed"] boolValue], accessibility = [status[@"accessibilityAllowed"] boolValue];
    self.micButton.hidden = microphone;
    self.micDone.hidden = !microphone;
    self.micButton.title = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusDenied ? @"Open Settings…" : @"Allow";
    self.accessibilityButton.hidden = accessibility;
    self.accessibilityDone.hidden = !accessibility;
    self.accessibilityHint.hidden = accessibility || !self.askedAccessibility;

    NSString *address = [self.host settingValue:@"bluetoothAddress"];
    [self refreshTouch:status address:address];
    [self refreshDownload:status];

    self.nextButton.enabled = self.step == kPermissions ? microphone && accessibility : self.step == kAirPods ? address.length > 0 : YES;
}
- (void)refreshTouch:(NSDictionary *)status address:(NSString *)address {
    NSString *sensor = status[@"sensor"];
    BOOL covered = [sensor isEqual:@"covered"] && [status[@"connected"] boolValue];
    if (covered) self.touched = YES;
    NSString *text;
    if (!address.length) text = @"Choose your AirPods above.";
    else if (![status[@"connected"] boolValue]) text = @"Not connected yet. Connect them to this Mac from Control Center, then try again.";
    else if ([sensor isEqual:@"worn"]) text = @"Both buds are in your ears. Take one out.";
    else if (covered) text = @"Got it. BudDial can feel your touch.";
    else if (self.touched) text = @"That works. Continue when you're ready.";
    else text = @"Take one bud out and cover the side that rests in your ear with a fingertip.";
    self.touchStatus.stringValue = text;
    self.touchCircle.fillColor = covered ? NSColor.systemGreenColor : self.touched ? [NSColor.systemGreenColor colorWithAlphaComponent:.18] : NSColor.quaternaryLabelColor;
    self.touchHand.contentTintColor = covered ? NSColor.whiteColor : self.touched ? NSColor.systemGreenColor : NSColor.secondaryLabelColor;
}
- (void)refreshDownload:(NSDictionary *)status {
    BOOL ready = [status[@"engineReady"] boolValue], downloading = [status[@"modelDownloading"] boolValue];
    NSString *error = status[@"modelError"];
    long long received = [status[@"modelReceived"] longLongValue], total = [status[@"modelTotal"] longLongValue];
    self.downloadBox.hidden = ready;
    if (ready) return;
    BOOL failed = error.length && !downloading;
    self.retryButton.hidden = !failed;
    self.downloadBar.hidden = failed;
    if (failed) {
        self.downloadLabel.stringValue = [NSString stringWithFormat:@"The speech model didn't download. %@", error];
    } else if (downloading && total > 0) {
        self.downloadLabel.stringValue = [NSString stringWithFormat:@"Downloading the speech model (one time), %@ of %@", megabytes(received), megabytes(total)];
        [self.downloadBar stopAnimation:nil];
        self.downloadBar.indeterminate = NO;
        self.downloadBar.doubleValue = 100.0 * received / total;
    } else {
        self.downloadLabel.stringValue = [status[@"modelInstalled"] boolValue] ? @"Starting the speech engine…" : @"Getting the speech model ready…";
        self.downloadBar.indeterminate = YES;
        [self.downloadBar startAnimation:nil];
    }
}
- (void)refreshChecklist {
    NSArray<NSNumber *> *done = @[@(self.said), @(self.sent), @(self.undone)];
    [self.checks enumerateObjectsUsingBlock:^(NSImageView *check, NSUInteger index, BOOL *stop) {
        (void)stop;
        BOOL complete = done[index].boolValue;
        check.image = [NSImage imageWithSystemSymbolName:complete ? @"checkmark.circle.fill" : @"circle" accessibilityDescription:nil];
        check.contentTintColor = complete ? NSColor.systemGreenColor : NSColor.tertiaryLabelColor;
    }];
}

#pragma mark Practice

- (void)noteInserted { if (!self.practicing) return; self.said = YES; [self refreshChecklist]; }
- (void)noteSent { if (!self.practicing || !self.said) return; self.sent = YES; [self refreshChecklist]; }
- (void)noteDeleted { if (!self.practicing) return; self.undone = YES; [self refreshChecklist]; }
- (BOOL)textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
    if (selector != @selector(insertNewline:)) return NO;
    NSString *text = [textView.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) return YES;
    // Keep the newest two messages; the thread is a short preview, not a history.
    while (self.bubbles.arrangedSubviews.count >= 2) [self.bubbles.arrangedSubviews.firstObject removeFromSuperview];
    NSBox *bubble = box(NSColor.controlAccentColor, 12, NO);
    NSTextField *words = paragraph(text, 13, NSColor.whiteColor, kContent - 120);
    [bubble.contentView addSubview:words];
    pin(words, bubble.contentView, NSEdgeInsetsMake(6, 11, 6, 11));
    [self.bubbles addArrangedSubview:bubble];
    self.bubblesEmpty.hidden = YES;
    textView.string = @"";
    self.placeholder.hidden = NO;
    return YES;
}
- (void)textDidChange:(NSNotification *)notification {
    (void)notification;
    self.placeholder.hidden = self.practice.string.length > 0;
}

#pragma mark Actions

- (void)allowMicrophone:(id)sender { (void)sender; [self.host requestMicrophoneAccess]; }
- (void)allowAccessibility:(id)sender {
    (void)sender;
    self.askedAccessibility = YES;
    [self.host openAccessibilitySettings];
    [self refresh];
}
- (void)retryDownload:(id)sender { (void)sender; [self.host retryModelDownload]; }
- (void)gestureRowClicked:(NSClickGestureRecognizer *)click {
    NSUInteger index = [self.gestureRows indexOfObject:click.view];
    if (index != NSNotFound) [self.stage showPhase:(APStagePhase)index];
}
- (void)reloadDevices {
    NSString *current = [self.host settingValue:@"bluetoothAddress"] ?: @"";
    NSArray<IOBluetoothDevice *> *buds = APPairedBuds();
    [self.devicePopup removeAllItems];
    if (!buds.count) {
        [self.devicePopup addItemWithTitle:@"No AirPods paired with this Mac"];
        self.devicePopup.lastItem.enabled = NO;
        return;
    }
    IOBluetoothDevice *chosen = nil;
    for (IOBluetoothDevice *device in buds) if ([APBluetoothAddress(device) caseInsensitiveCompare:current] == NSOrderedSame) chosen = device;
    for (IOBluetoothDevice *device in buds) if (!chosen && device.isConnected) chosen = device;
    chosen = chosen ?: buds.firstObject;
    for (IOBluetoothDevice *device in buds) {
        [self.devicePopup addItemWithTitle:device.isConnected ? device.name : [device.name stringByAppendingString:@"  ·  not connected"]];
        self.devicePopup.lastItem.representedObject = APBluetoothAddress(device);
        if (device == chosen) [self.devicePopup selectItem:self.devicePopup.lastItem];
    }
    [self deviceChosen:self.devicePopup];
}
- (void)deviceChosen:(NSPopUpButton *)sender {
    NSString *address = sender.selectedItem.representedObject;
    if (!address) return;
    if (![address isEqual:[self.host settingValue:@"bluetoothAddress"]]) self.touched = NO;
    [self.host setSettingValue:address forKey:@"bluetoothAddress"];
}
@end
