#import <AppKit/AppKit.h>

// A keyboard key held as BudDial's button, instead of or alongside an AirPod. It drives the same
// gestures: hold and talk, tap to send, hold silently to undo. Only right-hand modifier keys are
// offered: held alone they type nothing, and macOS reports them apart from their left-hand twins.

// {setting value, title}, "off" first.
NSArray<NSArray<NSString *> *> *APKeyTriggerChoices(void);
NSString *APKeyTriggerTitle(NSString *key);   // nil for "off" and unknown values

typedef NS_ENUM(NSInteger, APKeyState) {
    APKeyUp,
    APKeyDown,       // held alone
    APKeyShortcut,   // held with another modifier: part of a shortcut, not a touch
};
// The trigger's state in a set of modifier flags (CGEventFlags, or an NSEvent's raw modifierFlags),
// read from the left/right ("device-dependent") bits.
APKeyState APKeyTriggerState(NSString *key, uint64_t flags);

@interface APKeyTrigger : NSObject
@property (nonatomic, copy) NSString *key;   // a choice's setting value; "off" or nil stops it
@property (readonly) BOOL down;
@property (copy) void (^onChange)(BOOL down);
@property (copy) void (^onShortcut)(void);   // another key pressed while it is down
// Call every 50 ms or so. Catches presses and releases the key events missed (macOS hides key events
// from other apps while a password field has focus) and keys pressed alongside the trigger.
- (void)poll;
@end
