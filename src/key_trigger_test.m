#import "KeyTrigger.h"
#import <assert.h>
#import <stdio.h>

static void expect(NSString *key, uint64_t flags, APKeyState state) {
    APKeyState got = APKeyTriggerState(key, flags);
    if (got != state) {
        fprintf(stderr, "APKeyTriggerState(%s, %#llx) gave %ld, expected %ld\n", key.UTF8String, flags, (long)got, (long)state);
        assert(0);
    }
}

int main(void) { @autoreleasepool {
    // Flags as macOS reports them: device-independent family bit plus the left/right bit.
    const uint64_t rightOption = 0x80040, leftOption = 0x80020, rightCommand = 0x100010, leftCommand = 0x100008;
    const uint64_t rightShift = 0x20004, leftShift = 0x20002, rightControl = 0x42000, capsLock = 0x10000, fn = 0x800000;
    // Bits macOS adds that are not keys (non-coalesced event markers).
    const uint64_t noise = 0x20000100;

    expect(@"rightOption", rightOption, APKeyDown);
    expect(@"rightOption", rightOption | noise, APKeyDown);
    expect(@"rightOption", 0, APKeyUp);
    expect(@"rightOption", noise, APKeyUp);
    // The left-hand twin is a different key.
    expect(@"rightOption", leftOption, APKeyUp);
    expect(@"rightCommand", leftCommand, APKeyUp);
    expect(@"rightShift", leftShift, APKeyUp);
    // Any other modifier held with it makes a shortcut, its left twin included; caps lock does not.
    expect(@"rightOption", rightOption | leftOption, APKeyShortcut);
    expect(@"rightOption", rightOption | leftCommand, APKeyShortcut);
    expect(@"rightOption", rightOption | rightShift, APKeyShortcut);
    expect(@"rightOption", rightOption | fn, APKeyShortcut);
    expect(@"rightOption", rightOption | capsLock, APKeyDown);
    // Each choice reads its own bit.
    expect(@"rightCommand", rightCommand, APKeyDown);
    expect(@"rightShift", rightShift, APKeyDown);
    expect(@"rightControl", rightControl, APKeyDown);
    expect(@"rightCommand", rightOption, APKeyUp);
    // Off and unknown values never trigger.
    expect(@"off", rightOption, APKeyUp);
    expect(nil, rightOption, APKeyUp);
    expect(@"leftOption", leftOption, APKeyUp);
    assert(APKeyTriggerTitle(@"off") == nil && [APKeyTriggerTitle(@"rightOption") isEqual:@"Right Option ⌥"]);
    printf("Key trigger checks passed: left and right apart, shortcuts, noise bits, off.\n");
}}
