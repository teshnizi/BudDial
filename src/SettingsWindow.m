#import "SettingsWindow.h"
#import "ReplacementsSheet.h"
#import "Transcriber.h"
#import <AVFoundation/AVFoundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <IOKit/audio/IOAudioTypes.h>
#import <ServiceManagement/ServiceManagement.h>

static const CGFloat kWidth = 520, kInset = 24, kControlWidth = 230;

static NSTextField *label(NSString *string, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *field = [NSTextField labelWithString:string];
    field.font = [NSFont systemFontOfSize:size weight:weight];
    field.textColor = color;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    return field;
}
static NSTextField *caption(NSString *string, CGFloat width) {
    NSTextField *field = [NSTextField wrappingLabelWithString:string];
    field.font = [NSFont systemFontOfSize:11];
    field.textColor = NSColor.secondaryLabelColor;
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
NSString *APBluetoothAddress(IOBluetoothDevice *device) {
    // bluetoothd logs addresses as AA:BB:CC:DD:EE:FF; IOBluetooth reports aa-bb-cc-dd-ee-ff.
    return [device.addressString.uppercaseString stringByReplacingOccurrencesOfString:@"-" withString:@":"];
}
NSArray<IOBluetoothDevice *> *APPairedBuds(void) {
    NSMutableArray<IOBluetoothDevice *> *buds = [NSMutableArray array];
    for (IOBluetoothDevice *device in IOBluetoothDevice.pairedDevices) {
        NSString *name = device.name ?: @"";
        if ([name localizedCaseInsensitiveContainsString:@"AirPods"] || [name localizedCaseInsensitiveContainsString:@"Beats"]) [buds addObject:device];
    }
    return buds;
}
static NSArray<NSArray<NSString *> *> *languages(void) {
    return @[@[@"auto", @"Detect automatically"], @[@"en", @"English"], @[@"es", @"Spanish"], @[@"fr", @"French"],
             @[@"de", @"German"], @[@"it", @"Italian"], @[@"pt", @"Portuguese"], @[@"nl", @"Dutch"], @[@"sv", @"Swedish"],
             @[@"pl", @"Polish"], @[@"uk", @"Ukrainian"], @[@"ru", @"Russian"], @[@"tr", @"Turkish"], @[@"fa", @"Persian"],
             @[@"ar", @"Arabic"], @[@"hi", @"Hindi"], @[@"zh", @"Chinese"], @[@"ja", @"Japanese"], @[@"ko", @"Korean"]];
}

@interface APSettingsWindow () <NSWindowDelegate>
@property(weak) id<APSettingsHost> host;
@property NSString *modelsDirectory;
@property NSStackView *page;
@property NSTimer *timer;
@property NSTextField *statusDot, *statusLabel, *sensorDot, *sensorLabel, *holdValue;
@property NSBox *banner;
@property NSTextField *bannerText;
@property NSButton *bannerButton;
@property BOOL bannerFixesMicrophone;
@property NSSwitch *enabledSwitch, *sendSwitch, *deleteSwitch, *instantSwitch, *loginSwitch;
@property NSSlider *holdSlider;
@property NSTextField *vocabularyField;
@property NSSwitch *contextSwitch, *commandsSwitch;
@property NSButton *replacementsButton;
@property APReplacementsSheet *replacementsSheet;
@property NSPopUpButton *devicePopup, *microphonePopup, *modelPopup, *languagePopup, *soundPopup;
@end

@implementation APSettingsWindow
- (instancetype)initWithHost:(id<APSettingsHost>)host modelsDirectory:(NSString *)modelsDirectory version:(NSString *)version {
    self = [super initWithContentRect:NSMakeRect(0, 0, kWidth, 600)
                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskFullSizeContentView
                              backing:NSBackingStoreBuffered defer:NO];
    if (!self) return nil;
    _host = host;
    _modelsDirectory = modelsDirectory;
    self.title = @"BudDial";
    self.titleVisibility = NSWindowTitleHidden;
    self.titlebarAppearsTransparent = YES;
    self.releasedWhenClosed = NO;
    self.delegate = self;

    self.page = stack(@[], NSUserInterfaceLayoutOrientationVertical, 16);
    self.page.edgeInsets = NSEdgeInsetsMake(38, kInset, 18, kInset);
    [self.contentView addSubview:self.page];
    [NSLayoutConstraint activateConstraints:@[
        [self.page.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [self.page.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [self.page.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [self.page.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        [self.page.widthAnchor constraintEqualToConstant:kWidth]]];

    [self add:[self header]];
    [self buildControls];
    [self add:self.banner];
    [self add:[self section:@"AirPods" rows:@[
        [self row:@"Device" detail:stack(@[self.sensorDot, self.sensorLabel], NSUserInterfaceLayoutOrientationHorizontal, 5) control:self.devicePopup]]]];
    [self add:[self section:@"Dictation" rows:@[
        [self row:@"Hold before dictating" caption:@"Shorter touches count as taps." control:stack(@[self.holdSlider, self.holdValue], NSUserInterfaceLayoutOrientationHorizontal, 10)],
        [self row:@"Tap to send" caption:@"A quick tap on the bud presses Return." control:self.sendSwitch],
        [self row:@"Silent hold deletes" caption:@"Cover the bud for a second without talking to remove the last dictation." control:self.deleteSwitch],
        [self row:@"Microphone" caption:nil control:self.microphonePopup],
        [self row:@"Instant start" caption:@"Keeps the mic open so your first words aren't cut off. Audio stays in memory." control:self.instantSwitch]]]];
    [self add:[self section:@"Speech" rows:@[
        [self row:@"Model" caption:@"Runs on this Mac." control:self.modelPopup],
        [self row:@"Language" caption:nil control:self.languagePopup],
        [self row:@"Vocabulary" caption:@"Names and terms you say, comma-separated." control:self.vocabularyField],
        [self row:@"Replacements" caption:@"Fix words it keeps getting wrong, like “clawed code” to “Claude Code”." control:self.replacementsButton],
        [self row:@"Voice commands" caption:@"Start with “Spotlight” to search. Say “scratch that” to undo, “new line” for a line break." control:self.commandsSwitch],
        [self row:@"Use text before the cursor" caption:@"Helps spelling and style. Read on this Mac, never sent anywhere." control:self.contextSwitch]]]];
    NSButton *test = [NSButton buttonWithTitle:@"Test" target:self action:@selector(testSound:)];
    test.controlSize = NSControlSizeSmall;
    [self add:[self section:@"General" rows:@[
        [self row:@"Sounds" caption:nil control:stack(@[test, self.soundPopup], NSUserInterfaceLayoutOrientationHorizontal, 8)],
        [self row:@"Launch at login" caption:nil control:self.loginSwitch]]]];
    [self add:[self footer:version]];
    [self fitContent];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadDevices) name:NSPopUpButtonWillPopUpNotification object:self.devicePopup];
    return self;
}
- (void)add:(NSView *)view {
    [self.page addArrangedSubview:view];
    [view.widthAnchor constraintEqualToConstant:kWidth - 2 * kInset].active = YES;
}
// Sizes the window to its content, keeping the top edge where it is.
- (void)fitContent {
    [self.contentView layoutSubtreeIfNeeded];
    NSSize size = self.page.fittingSize;
    NSRect frame = [self frameRectForContentRect:NSMakeRect(0, 0, size.width, size.height)];
    frame.origin = NSMakePoint(NSMinX(self.frame), NSMaxY(self.frame) - NSHeight(frame));
    [self setFrame:frame display:YES animate:self.visible];
}

#pragma mark Layout

- (NSView *)header {
    NSImageView *icon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"airpods" accessibilityDescription:nil]];
    icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:28 weight:NSFontWeightRegular];
    icon.contentTintColor = NSColor.controlAccentColor;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusDot = label(@"●", 10, NSFontWeightRegular, NSColor.systemGreenColor);
    self.statusLabel = label(@"Ready", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    NSStackView *titles = stack(@[label(@"BudDial", 20, NSFontWeightSemibold, NSColor.labelColor),
                                  stack(@[self.statusDot, self.statusLabel], NSUserInterfaceLayoutOrientationHorizontal, 5)],
                                NSUserInterfaceLayoutOrientationVertical, 2);
    self.enabledSwitch = [NSSwitch new];
    self.enabledSwitch.target = self;
    self.enabledSwitch.action = @selector(enabledChanged:);
    self.enabledSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *top = [NSView new];
    top.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView *identity = stack(@[icon, titles], NSUserInterfaceLayoutOrientationHorizontal, 12);
    [top addSubview:identity];
    [top addSubview:self.enabledSwitch];
    [NSLayoutConstraint activateConstraints:@[
        [identity.leadingAnchor constraintEqualToAnchor:top.leadingAnchor],
        [identity.topAnchor constraintEqualToAnchor:top.topAnchor],
        [identity.bottomAnchor constraintEqualToAnchor:top.bottomAnchor],
        [self.enabledSwitch.trailingAnchor constraintEqualToAnchor:top.trailingAnchor],
        [self.enabledSwitch.centerYAnchor constraintEqualToAnchor:top.centerYAnchor]]];
    NSTextField *hint = caption(@"Cover an AirPod and talk  ·  release to paste  ·  tap for Return  ·  hold silently to undo", kWidth - 2 * kInset);
    hint.font = [NSFont systemFontOfSize:12];
    NSStackView *header = stack(@[top, hint], NSUserInterfaceLayoutOrientationVertical, 12);
    [top.widthAnchor constraintEqualToAnchor:header.widthAnchor].active = YES;
    return header;
}
- (NSView *)section:(NSString *)title rows:(NSArray<NSView *> *)rows {
    NSBox *box = [NSBox new];
    box.boxType = NSBoxCustom;
    box.titlePosition = NSNoTitle;
    box.cornerRadius = 10;
    box.borderWidth = 1;
    box.borderColor = NSColor.separatorColor;
    box.fillColor = [NSColor.labelColor colorWithAlphaComponent:.035];
    box.contentViewMargins = NSZeroSize;
    box.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView *list = stack(@[], NSUserInterfaceLayoutOrientationVertical, 0);
    [box.contentView addSubview:list];
    [NSLayoutConstraint activateConstraints:@[
        [list.leadingAnchor constraintEqualToAnchor:box.contentView.leadingAnchor],
        [list.trailingAnchor constraintEqualToAnchor:box.contentView.trailingAnchor],
        [list.topAnchor constraintEqualToAnchor:box.contentView.topAnchor],
        [list.bottomAnchor constraintEqualToAnchor:box.contentView.bottomAnchor]]];
    [rows enumerateObjectsUsingBlock:^(NSView *row, NSUInteger index, BOOL *stop) {
        (void)stop;
        if (index) {
            NSView *holder = [NSView new];
            holder.translatesAutoresizingMaskIntoConstraints = NO;
            NSBox *line = [NSBox new];
            line.boxType = NSBoxSeparator;
            line.translatesAutoresizingMaskIntoConstraints = NO;
            [holder addSubview:line];
            [NSLayoutConstraint activateConstraints:@[
                [line.leadingAnchor constraintEqualToAnchor:holder.leadingAnchor constant:14],
                [line.trailingAnchor constraintEqualToAnchor:holder.trailingAnchor constant:-14],
                [line.centerYAnchor constraintEqualToAnchor:holder.centerYAnchor],
                [holder.heightAnchor constraintEqualToConstant:1]]];
            [list addArrangedSubview:holder];
            [holder.widthAnchor constraintEqualToAnchor:list.widthAnchor].active = YES;
        }
        [list addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:list.widthAnchor].active = YES;
    }];
    NSStackView *section = stack(@[label(title, 13, NSFontWeightSemibold, NSColor.labelColor), box], NSUserInterfaceLayoutOrientationVertical, 8);
    [box.widthAnchor constraintEqualToAnchor:section.widthAnchor].active = YES;
    return section;
}
- (NSView *)row:(NSString *)title caption:(NSString *)text control:(NSView *)control {
    return [self row:title detail:text ? caption(text, 250) : nil control:control];
}
- (NSView *)row:(NSString *)title detail:(NSView *)detail control:(NSView *)control {
    NSView *row = [NSView new];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView *labels = stack(@[label(title, 13, NSFontWeightRegular, NSColor.labelColor)], NSUserInterfaceLayoutOrientationVertical, 2);
    if (detail) [labels addArrangedSubview:detail];
    control.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:labels];
    [row addSubview:control];
    NSLayoutConstraint *compact = [row.heightAnchor constraintEqualToConstant:0];
    compact.priority = NSLayoutPriorityFittingSizeCompression;
    [NSLayoutConstraint activateConstraints:@[
        [labels.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [labels.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [labels.trailingAnchor constraintLessThanOrEqualToAnchor:control.leadingAnchor constant:-16],
        [control.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
        [control.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.heightAnchor constraintGreaterThanOrEqualToAnchor:labels.heightAnchor constant:22],
        [row.heightAnchor constraintGreaterThanOrEqualToAnchor:control.heightAnchor constant:16],
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:40], compact]];
    return row;
}
- (NSView *)footer:(NSString *)version {
    NSButton *diagnostics = [NSButton buttonWithTitle:@"Diagnostics…" target:self action:@selector(diagnostics:)];
    diagnostics.controlSize = NSControlSizeSmall;
    NSView *footer = [NSView new];
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *about = label([NSString stringWithFormat:@"Version %@ · Speech stays on this Mac", version], 11, NSFontWeightRegular, NSColor.tertiaryLabelColor);
    diagnostics.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:diagnostics];
    [footer addSubview:about];
    [NSLayoutConstraint activateConstraints:@[
        [diagnostics.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor],
        [diagnostics.topAnchor constraintEqualToAnchor:footer.topAnchor],
        [diagnostics.bottomAnchor constraintEqualToAnchor:footer.bottomAnchor],
        [about.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor],
        [about.centerYAnchor constraintEqualToAnchor:diagnostics.centerYAnchor]]];
    return footer;
}
- (NSPopUpButton *)popup:(SEL)action {
    NSPopUpButton *popup = [NSPopUpButton new];
    popup.target = self;
    popup.action = action;
    [popup.widthAnchor constraintEqualToConstant:kControlWidth].active = YES;
    return popup;
}
- (NSSwitch *)toggle:(SEL)action {
    NSSwitch *toggle = [NSSwitch new];
    toggle.target = self;
    toggle.action = action;
    return toggle;
}
- (NSButton *)smallButton:(NSString *)title action:(SEL)action {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.controlSize = NSControlSizeSmall;
    return button;
}
- (void)buildControls {
    self.devicePopup = [self popup:@selector(deviceChanged:)];
    self.sensorDot = label(@"○", 12, NSFontWeightRegular, NSColor.tertiaryLabelColor);
    self.sensorLabel = label(@"Waiting for AirPods", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    self.holdSlider = [NSSlider sliderWithValue:.55 minValue:.3 maxValue:1 target:self action:@selector(holdChanged:)];
    [self.holdSlider.widthAnchor constraintEqualToConstant:160].active = YES;
    self.holdValue = label(@"0.55 s", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    self.holdValue.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    [self.holdValue.widthAnchor constraintEqualToConstant:44].active = YES;
    self.sendSwitch = [self toggle:@selector(sendChanged:)];
    self.deleteSwitch = [self toggle:@selector(deleteChanged:)];
    self.microphonePopup = [self popup:@selector(microphoneChanged:)];
    self.instantSwitch = [self toggle:@selector(instantChanged:)];
    self.modelPopup = [self popup:@selector(modelChanged:)];
    self.languagePopup = [self popup:@selector(languageChanged:)];
    for (NSArray<NSString *> *language in languages()) {
        [self.languagePopup addItemWithTitle:language[1]];
        self.languagePopup.lastItem.representedObject = language[0];
    }
    self.soundPopup = [NSPopUpButton new];
    self.soundPopup.target = self;
    self.soundPopup.action = @selector(soundChanged:);
    for (NSArray<NSString *> *choice in @[@[@"speakers", @"Mac speakers"], @[@"system", @"Current output"], @[@"off", @"Off"]]) {
        [self.soundPopup addItemWithTitle:choice[1]];
        self.soundPopup.lastItem.representedObject = choice[0];
    }
    self.loginSwitch = [self toggle:@selector(loginChanged:)];
    self.contextSwitch = [self toggle:@selector(contextChanged:)];
    self.commandsSwitch = [self toggle:@selector(commandsChanged:)];
    self.replacementsButton = [NSButton buttonWithTitle:@"Edit…" target:self action:@selector(editReplacements:)];
    self.vocabularyField = [NSTextField textFieldWithString:@""];
    self.vocabularyField.placeholderString = @"BudDial, Homebrew, Claude…";
    self.vocabularyField.target = self;
    self.vocabularyField.action = @selector(vocabularyChanged:);
    self.vocabularyField.cell.sendsActionOnEndEditing = YES;
    [self.vocabularyField.widthAnchor constraintEqualToConstant:kControlWidth].active = YES;
    NSImageView *warning = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"exclamationmark.triangle.fill" accessibilityDescription:nil]];
    warning.contentTintColor = NSColor.systemOrangeColor;
    self.bannerText = caption(@"", 300);
    self.bannerText.font = [NSFont systemFontOfSize:12];
    self.bannerText.textColor = NSColor.labelColor;
    self.bannerButton = [self smallButton:@"Open Settings…" action:@selector(fixPermission:)];
    NSStackView *content = stack(@[warning, self.bannerText], NSUserInterfaceLayoutOrientationHorizontal, 8);
    self.banner = [NSBox new];
    self.banner.boxType = NSBoxCustom;
    self.banner.titlePosition = NSNoTitle;
    self.banner.cornerRadius = 10;
    self.banner.borderWidth = 0;
    self.banner.fillColor = [NSColor.systemOrangeColor colorWithAlphaComponent:.14];
    self.banner.contentViewMargins = NSZeroSize;
    self.banner.translatesAutoresizingMaskIntoConstraints = NO;
    self.bannerButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.banner.contentView addSubview:content];
    [self.banner.contentView addSubview:self.bannerButton];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:self.banner.contentView.leadingAnchor constant:12],
        [content.topAnchor constraintEqualToAnchor:self.banner.contentView.topAnchor constant:10],
        [content.bottomAnchor constraintEqualToAnchor:self.banner.contentView.bottomAnchor constant:-10],
        [content.trailingAnchor constraintLessThanOrEqualToAnchor:self.bannerButton.leadingAnchor constant:-12],
        [self.bannerButton.trailingAnchor constraintEqualToAnchor:self.banner.contentView.trailingAnchor constant:-12],
        [self.bannerButton.centerYAnchor constraintEqualToAnchor:self.banner.contentView.centerYAnchor]]];
    self.banner.hidden = YES;
}

#pragma mark Data

- (void)select:(NSPopUpButton *)popup value:(id)value {
    for (NSMenuItem *item in popup.itemArray) {
        if ([item.representedObject isEqual:value]) { [popup selectItem:item]; return; }
    }
}
- (void)reloadDevices {
    NSString *current = [self.host settingValue:@"bluetoothAddress"];
    [self.devicePopup removeAllItems];
    NSArray<IOBluetoothDevice *> *buds = APPairedBuds();
    if (!buds.count) {
        [self.devicePopup addItemWithTitle:@"No AirPods paired with this Mac"];
        self.devicePopup.lastItem.enabled = NO;
        return;
    }
    BOOL known = NO;
    for (IOBluetoothDevice *device in buds) known = known || [APBluetoothAddress(device) caseInsensitiveCompare:current ?: @""] == NSOrderedSame;
    if (!known) [self.devicePopup addItemWithTitle:@"Choose your AirPods…"];
    for (IOBluetoothDevice *device in buds) {
        [self.devicePopup addItemWithTitle:device.isConnected ? device.name : [device.name stringByAppendingString:@"  ·  not connected"]];
        self.devicePopup.lastItem.representedObject = APBluetoothAddress(device);
    }
    if (known) [self select:self.devicePopup value:current.uppercaseString];
}
- (void)reloadChoices {
    [self reloadDevices];

    NSString *microphone = [self.host settingValue:@"microphone"];
    [self.microphonePopup removeAllItems];
    [self.microphonePopup addItemWithTitle:@"Built-in microphone"];
    self.microphonePopup.lastItem.representedObject = @"builtin";
    [self.microphonePopup addItemWithTitle:@"System default"];
    self.microphonePopup.lastItem.representedObject = @"default";
    AVCaptureDeviceDiscoverySession *discovery = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeMicrophone, AVCaptureDeviceTypeExternal] mediaType:AVMediaTypeAudio position:AVCaptureDevicePositionUnspecified];
    BOOL separated = NO;
    for (AVCaptureDevice *device in discovery.devices) {
        if (device.transportType == kIOAudioDeviceTransportTypeBuiltIn) continue;
        if (!separated) { [self.microphonePopup.menu addItem:NSMenuItem.separatorItem]; separated = YES; }
        [self.microphonePopup addItemWithTitle:device.localizedName];
        self.microphonePopup.lastItem.representedObject = device.localizedName;
    }
    // A chosen microphone that is unplugged stays selectable, marked as not connected.
    if (microphone.length && [self.microphonePopup indexOfItemWithRepresentedObject:microphone] < 0) {
        [self.microphonePopup addItemWithTitle:[microphone stringByAppendingString:@" (not connected)"]];
        self.microphonePopup.lastItem.representedObject = microphone;
    }
    [self select:self.microphonePopup value:microphone];

    NSString *model = [self.host settingValue:@"model"];
    [self.modelPopup removeAllItems];
    NSArray<NSString *> *models = [APTranscriber installedModelsIn:self.modelsDirectory];
    for (NSString *file in models) {
        unsigned long long bytes = [[NSFileManager.defaultManager attributesOfItemAtPath:[self.modelsDirectory stringByAppendingPathComponent:file] error:nil] fileSize];
        [self.modelPopup addItemWithTitle:[NSString stringWithFormat:@"%@  ·  %.0f MB", APModelTitle(file), bytes / 1e6]];
        self.modelPopup.lastItem.representedObject = file;
    }
    if (!models.count) { [self.modelPopup addItemWithTitle:@"No models in models/"]; self.modelPopup.lastItem.enabled = NO; }
    [self select:self.modelPopup value:model];

    [self select:self.languagePopup value:[self.host settingValue:@"language"]];
    [self updateLanguageAvailability];
    [self select:self.soundPopup value:[self.host settingValue:@"cueOutput"]];
    double hold = [[self.host settingValue:@"holdSeconds"] doubleValue];
    self.holdSlider.doubleValue = hold;
    self.holdValue.stringValue = [NSString stringWithFormat:@"%.2f s", hold];
    self.sendSwitch.state = [[self.host settingValue:@"tapToSend"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    self.deleteSwitch.state = [[self.host settingValue:@"silentHoldDeletes"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    self.instantSwitch.state = [[self.host settingValue:@"instantStart"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    self.contextSwitch.state = [[self.host settingValue:@"useContext"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    self.commandsSwitch.state = [[self.host settingValue:@"voiceCommands"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    NSUInteger replacements = [[self.host settingValue:@"replacements"] count];
    self.replacementsButton.title = replacements ? [NSString stringWithFormat:@"%lu %@…", (unsigned long)replacements, replacements == 1 ? @"word" : @"words"] : @"Edit…";
    self.vocabularyField.stringValue = [self.host settingValue:@"vocabulary"] ?: @"";
    self.loginSwitch.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
}
- (void)updateLanguageAvailability {
    NSString *model = self.modelPopup.selectedItem.representedObject ?: @"";
    BOOL englishOnly = [model containsString:@".en."];
    self.languagePopup.enabled = !englishOnly;
    if (englishOnly) [self select:self.languagePopup value:@"en"];
}
- (void)refreshLive {
    NSDictionary *status = [self.host liveStatus];
    self.statusLabel.stringValue = status[@"state"] ?: @"";
    NSInteger tone = [status[@"tone"] integerValue];
    self.statusDot.textColor = tone == 1 ? NSColor.systemRedColor : tone == 2 ? NSColor.systemOrangeColor : NSColor.systemGreenColor;
    self.enabledSwitch.state = [[self.host settingValue:@"controlsEnabled"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    NSString *sensor = status[@"sensor"];
    if (![status[@"connected"] boolValue]) {
        self.sensorDot.stringValue = @"○"; self.sensorDot.textColor = NSColor.tertiaryLabelColor;
        self.sensorLabel.stringValue = [[self.host settingValue:@"bluetoothAddress"] length] ? @"AirPods not connected" : @"Choose your AirPods above";
    } else if ([sensor isEqual:@"covered"]) {
        self.sensorDot.stringValue = @"●"; self.sensorDot.textColor = NSColor.systemGreenColor;
        self.sensorLabel.stringValue = @"Covered";
    } else if ([sensor isEqual:@"worn"]) {
        self.sensorDot.stringValue = @"◐"; self.sensorDot.textColor = NSColor.secondaryLabelColor;
        self.sensorLabel.stringValue = @"Worn — ignored until removed";
    } else {
        self.sensorDot.stringValue = @"○"; self.sensorDot.textColor = NSColor.tertiaryLabelColor;
        self.sensorLabel.stringValue = @"Not covered";
    }
    BOOL microphone = [status[@"microphoneAllowed"] boolValue], accessibility = [status[@"accessibilityAllowed"] boolValue];
    NSString *problem = !microphone ? @"Allow microphone access so BudDial can hear you."
                      : !accessibility ? @"Allow Accessibility so text can be pasted at your cursor." : nil;
    if (problem) {
        self.bannerText.stringValue = problem;
        self.bannerButton.title = !microphone ? @"Allow…" : @"Open Settings…";
        self.bannerFixesMicrophone = !microphone;
    }
    if (self.banner.hidden == (problem != nil)) {
        self.banner.hidden = problem == nil;
        [self fitContent];
    }
}
- (void)present {
    [self reloadChoices];
    [self refreshLive];
    if (!self.visible) [self center];
    [NSApp activateIgnoringOtherApps:YES];
    [self makeKeyAndOrderFront:nil];
    if (!self.timer) {
        __weak APSettingsWindow *weakSelf = self;
        self.timer = [NSTimer timerWithTimeInterval:.2 repeats:YES block:^(NSTimer *timer) { (void)timer; [weakSelf refreshLive]; }];
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    }
}
- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    [self.timer invalidate];
    self.timer = nil;
}

#pragma mark Actions

- (void)enabledChanged:(NSSwitch *)sender { [self.host setSettingValue:@(sender.state == NSControlStateValueOn) forKey:@"controlsEnabled"]; }
- (void)deviceChanged:(NSPopUpButton *)sender {
    id address = sender.selectedItem.representedObject;
    if (address) [self.host setSettingValue:address forKey:@"bluetoothAddress"];
}
- (void)holdChanged:(NSSlider *)sender {
    double hold = round(sender.doubleValue / .05) * .05;
    self.holdValue.stringValue = [NSString stringWithFormat:@"%.2f s", hold];
    [self.host setSettingValue:@(hold) forKey:@"holdSeconds"];
}
- (void)sendChanged:(NSSwitch *)sender { [self.host setSettingValue:@(sender.state == NSControlStateValueOn) forKey:@"tapToSend"]; }
- (void)deleteChanged:(NSSwitch *)sender { [self.host setSettingValue:@(sender.state == NSControlStateValueOn) forKey:@"silentHoldDeletes"]; }
- (void)microphoneChanged:(NSPopUpButton *)sender { [self.host setSettingValue:sender.selectedItem.representedObject forKey:@"microphone"]; }
- (void)instantChanged:(NSSwitch *)sender { [self.host setSettingValue:@(sender.state == NSControlStateValueOn) forKey:@"instantStart"]; }
- (void)modelChanged:(NSPopUpButton *)sender {
    [self.host setSettingValue:sender.selectedItem.representedObject forKey:@"model"];
    NSString *before = self.languagePopup.selectedItem.representedObject;
    [self updateLanguageAvailability];
    NSString *after = self.languagePopup.selectedItem.representedObject;
    if (![before isEqual:after]) [self.host setSettingValue:after forKey:@"language"];
}
- (void)languageChanged:(NSPopUpButton *)sender { [self.host setSettingValue:sender.selectedItem.representedObject forKey:@"language"]; }
- (void)soundChanged:(NSPopUpButton *)sender { [self.host setSettingValue:sender.selectedItem.representedObject forKey:@"cueOutput"]; }
- (void)contextChanged:(NSSwitch *)sender { [self.host setSettingValue:@(sender.state == NSControlStateValueOn) forKey:@"useContext"]; }
- (void)commandsChanged:(NSSwitch *)sender { [self.host setSettingValue:@(sender.state == NSControlStateValueOn) forKey:@"voiceCommands"]; }
- (void)editReplacements:(id)sender {
    (void)sender;
    __weak APSettingsWindow *weakSelf = self;
    self.replacementsSheet = [[APReplacementsSheet alloc] initWithPairs:[self.host settingValue:@"replacements"] completion:^(NSArray<NSDictionary *> *pairs) {
        [weakSelf.host setSettingValue:pairs forKey:@"replacements"];
        [weakSelf reloadChoices];
    }];
    [self beginSheet:self.replacementsSheet completionHandler:^(NSModalResponse response) { (void)response; weakSelf.replacementsSheet = nil; }];
}
- (void)vocabularyChanged:(NSTextField *)sender { [self.host setSettingValue:sender.stringValue forKey:@"vocabulary"]; }
- (void)testSound:(id)sender { [self.host testSound:sender]; }
- (void)diagnostics:(id)sender { [self.host showMonitor:sender]; }
- (void)fixPermission:(id)sender {
    (void)sender;
    if (self.bannerFixesMicrophone) [self.host requestMicrophoneAccess];
    else [self.host openAccessibilitySettings];
}
- (void)loginChanged:(NSSwitch *)sender {
    SMAppService *service = SMAppService.mainAppService;
    NSError *error = nil;
    BOOL on = sender.state == NSControlStateValueOn;
    BOOL done = on ? [service registerAndReturnError:&error] : [service unregisterAndReturnError:&error];
    if (on && service.status == SMAppServiceStatusRequiresApproval) [SMAppService openSystemSettingsLoginItems];
    if (!done) {
        sender.state = on ? NSControlStateValueOff : NSControlStateValueOn;
        NSAlert *alert = [NSAlert new];
        alert.messageText = on ? @"Couldn't turn on launch at login" : @"Couldn't turn off launch at login";
        alert.informativeText = error.localizedDescription ?: @"";
        [alert beginSheetModalForWindow:self completionHandler:nil];
    }
}
@end
