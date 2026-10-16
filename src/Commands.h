#import <Foundation/Foundation.h>

// What a transcript asks for. Commands only count at the very start of what was said, so a
// sentence that merely mentions "spotlight" later on is typed as usual.
typedef NS_ENUM(NSInteger, APCommandKind) {
    APCommandNone,        // ordinary dictation: type it
    APCommandSpotlight,   // "Spotlight <query>": open Spotlight and type the query (may be empty)
    APCommandScratch,     // "Scratch that" / "Delete that" / "Undo that": remove the last dictation
    APCommandNewLine,     // "New line": a line break that does not send (Shift+Return)
};

@interface APCommand : NSObject
@property APCommandKind kind;
@property NSString *text;   // the query for Spotlight; nil otherwise
+ (APCommand *)parse:(NSString *)transcript;
@end

// Replaces whole words and phrases, ignoring case: each pair is @{@"heard": ..., @"write": ...}.
// "clawed code" matches "Clawed code," but not "unclawed code".
NSString *APApplyReplacements(NSString *text, NSArray<NSDictionary *> *pairs);
// The "write" spellings, for the vocabulary Whisper is given.
NSArray<NSString *> *APReplacementSpellings(NSArray<NSDictionary *> *pairs);
