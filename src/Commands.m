#import "Commands.h"

// Whisper punctuates and capitalizes freely ("Spotlight, Codex." / "Scratch that."), so commands
// are matched on lowercase words with punctuation removed.
static NSString *plainWords(NSString *text) {
    NSMutableString *plain = [NSMutableString string];
    for (NSString *word in [text.lowercaseString componentsSeparatedByCharactersInSet:[NSCharacterSet.alphanumericCharacterSet invertedSet]])
        if (word.length) [plain appendFormat:plain.length ? @" %@" : @"%@", word];
    return plain;
}

@implementation APCommand
+ (APCommand *)parse:(NSString *)transcript {
    APCommand *command = [APCommand new];
    NSString *plain = plainWords(transcript);
    if ([@[@"scratch that", @"delete that", @"undo that"] containsObject:plain]) { command.kind = APCommandScratch; return command; }
    if ([@[@"new line", @"newline"] containsObject:plain]) { command.kind = APCommandNewLine; return command; }
    // "Spotlight" (or "Spot light") as the first word, then the query as said, minus the
    // punctuation Whisper puts around it.
    NSRegularExpression *spotlight = [NSRegularExpression regularExpressionWithPattern:@"^\\s*spot\\s?light(?![\\p{L}\\p{N}])[\\s\\p{P}]*(.*?)[\\s\\p{P}]*$"
                                                                              options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators error:nil];
    NSTextCheckingResult *match = [spotlight firstMatchInString:transcript options:0 range:NSMakeRange(0, transcript.length)];
    if (match) {
        command.kind = APCommandSpotlight;
        command.text = [transcript substringWithRange:[match rangeAtIndex:1]];
    }
    return command;
}
@end

NSString *APApplyReplacements(NSString *text, NSArray<NSDictionary *> *pairs) {
    NSMutableString *result = [text mutableCopy];
    for (NSDictionary *pair in pairs) {
        NSString *heard = [pair[@"heard"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *write = pair[@"write"] ?: @"";
        if (!heard.length) continue;
        // Words in the phrase may be separated by any run of spaces; edges must not touch letters or digits.
        NSArray *words = [heard componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSMutableArray *escaped = [NSMutableArray array];
        for (NSString *word in words) if (word.length) [escaped addObject:[NSRegularExpression escapedPatternForString:word]];
        NSString *pattern = [NSString stringWithFormat:@"(?<![\\p{L}\\p{N}])%@(?![\\p{L}\\p{N}])", [escaped componentsJoinedByString:@"\\s+"]];
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
        [regex replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:[NSRegularExpression escapedTemplateForString:write]];
    }
    return result;
}

NSArray<NSString *> *APReplacementSpellings(NSArray<NSDictionary *> *pairs) {
    NSMutableArray *spellings = [NSMutableArray array];
    for (NSDictionary *pair in pairs) {
        NSString *write = [pair[@"write"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (write.length && ![spellings containsObject:write]) [spellings addObject:write];
    }
    return spellings;
}
