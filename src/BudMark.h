#import <AppKit/AppKit.h>

// BudDial's mark: an earbud that is also a speech bubble (round head, one stem for the tail), with
// the "typing" dots inside. Shared by the menu bar glyph and the app icon so both stay identical.
NSBezierPath *APBudMarkShape(NSRect box);                // head and stem, filling a square box
NSArray<NSBezierPath *> *APBudMarkDots(NSRect box);      // the three dots, in the same box
NSImage *APBudMarkMenuBarImage(void);                    // 18 pt template image, dots cut out
