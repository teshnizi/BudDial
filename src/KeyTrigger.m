#import "KeyTrigger.h"

// Left/right modifier bits, from IOKit/hidsystem/IOLLEvent.h (NX_DEVICE…KEYMASK).
enum {
    kLeftControl = 0x0001, kLeftShift = 0x0002, kRightShift = 0x0004, kLeftCommand = 0x0008,
    kRightCommand = 0x0010, kLeftOption = 0x0020, kRightOption = 0x0040, kRightControl = 0x2000,
    kFunction = 0x800000,   // fn, NSEventModifierFlagFunction
    kModifierBits = kLeftControl | kLeftShift | kRightShift | kLeftCommand | kRightCommand | kLeftOption | kRightOption | kRightControl | kFunction,
};

typedef struct { const char *value, *title; uint64_t bit; } APKeyChoice;
static const APKeyChoice kChoices[] = {
    {"rightOption", "Right Option ⌥", kRightOption},
    {"rightCommand", "Right Command ⌘", kRightCommand},
    {"rightShift", "Right Shift ⇧", kRightShift},
    {"rightControl", "Right Control ⌃", kRightControl},
};

static const APKeyChoice *choice(NSString *key) {
    for (size_t i = 0; i < sizeof kChoices / sizeof *kChoices; i++)
        if ([key isEqualToString:@(kChoices[i].value)]) return &kChoices[i];
    return NULL;
}

NSArray<NSArray<NSString *> *> *APKeyTriggerChoices(void) {
    NSMutableArray *choices = [NSMutableArray arrayWithObject:@[@"off", @"Off"]];
    for (size_t i = 0; i < sizeof kChoices / sizeof *kChoices; i++) [choices addObject:@[@(kChoices[i].value), @(kChoices[i].title)]];
    return choices;
}

NSString *APKeyTriggerTitle(NSString *key) {
    const APKeyChoice *entry = choice(key);
    return entry ? @(entry->title) : nil;
}

APKeyState APKeyTriggerState(NSString *key, uint64_t flags) {
    const APKeyChoice *entry = choice(key);
    if (!entry || !(flags & entry->bit)) return APKeyUp;
    return flags & kModifierBits & ~entry->bit ? APKeyShortcut : APKeyDown;
}

@implementation APKeyTrigger {
    id globalMonitor, localMonitor;
    BOOL ignoring;        // pressed as part of a shortcut: ignored until released
    BOOL shortcutSent;    // onShortcut already called for this press
    int disagreements;    // polls in a row whose key state differs from the events'
    double downAt;
}

- (void)setKey:(NSString *)key {
    [self stop];
    _key = [key copy];
    if (!choice(key)) return;
    __weak APKeyTrigger *weakSelf = self;
    // Global: key events for other apps (needs Accessibility, which BudDial has to paste). Local: BudDial's own windows.
    globalMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged handler:^(NSEvent *event) {
        [weakSelf apply:APKeyTriggerState(weakSelf.key, event.modifierFlags)];
    }];
    localMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged handler:^NSEvent *(NSEvent *event) {
        [weakSelf apply:APKeyTriggerState(weakSelf.key, event.modifierFlags)];
        return event;
    }];
}

- (void)stop {
    if (globalMonitor) [NSEvent removeMonitor:globalMonitor];
    if (localMonitor) [NSEvent removeMonitor:localMonitor];
    globalMonitor = localMonitor = nil;
    _down = ignoring = shortcutSent = NO;
    disagreements = 0;
}

- (void)dealloc { [self stop]; }

- (void)apply:(APKeyState)state {
    if (state == APKeyUp) {
        ignoring = NO;
        if (!_down) return;
        _down = NO;
        if (self.onChange) self.onChange(NO);
        return;
    }
    if (_down) {
        if (state == APKeyShortcut) [self shortcut];
        return;
    }
    if (ignoring) return;
    // Pressed while another modifier is already held: a shortcut from the start, never a touch.
    if (state == APKeyShortcut) { ignoring = YES; return; }
    _down = YES;
    shortcutSent = NO;
    downAt = NSProcessInfo.processInfo.systemUptime;
    if (self.onChange) self.onChange(YES);
}

- (void)shortcut {
    if (shortcutSent) return;
    shortcutSent = YES;
    if (self.onShortcut) self.onShortcut();
}

- (void)poll {
    if (!choice(self.key)) return;
    // The key state comes from the keyboard itself: BudDial's own keystrokes (⌘V, Return) never show here.
    APKeyState state = APKeyTriggerState(self.key, CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState));
    // A key event arrives a few milliseconds after the state changes, so one disagreeing poll is normal.
    // Two in a row mean the event was missed.
    BOOL held = state != APKeyUp;
    if (held != (_down || ignoring)) {
        if (++disagreements >= 2) { disagreements = 0; [self apply:state]; }
    } else {
        disagreements = 0;
        if (_down && state == APKeyShortcut) [self shortcut];
    }
    // Any other key typed since the press (key events from the keyboard only) makes it a shortcut.
    if (_down && CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateHIDSystemState, kCGEventKeyDown) < NSProcessInfo.processInfo.systemUptime - downAt)
        [self shortcut];
}
@end
