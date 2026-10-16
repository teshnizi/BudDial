#import "Commands.h"
#import <assert.h>
#import <stdio.h>

static void expect(NSString *transcript, APCommandKind kind, NSString *text) {
    APCommand *command = [APCommand parse:transcript];
    if (command.kind != kind || (text && ![command.text isEqual:text])) {
        fprintf(stderr, "parse(\"%s\") gave kind %ld, text \"%s\"\n", transcript.UTF8String, (long)command.kind, command.text.UTF8String ?: "(nil)");
        assert(0);
    }
}

int main(void) { @autoreleasepool {
    // Spotlight: first word only, punctuation Whisper adds is dropped, the query keeps its own words.
    expect(@"Spotlight Codex.", APCommandSpotlight, @"Codex");
    expect(@" spotlight, Claude Code!", APCommandSpotlight, @"Claude Code");
    expect(@"Spot light: calendar", APCommandSpotlight, @"calendar");
    expect(@"Smart white cloud coat.", APCommandSpotlight, @"cloud coat");
    expect(@"Spot white.", APCommandSpotlight, @"");
    expect(@"Spotlights, Codex", APCommandSpotlight, @"Codex");
    expect(@"Smart whiteboards are useful.", APCommandNone, nil);
    expect(@"A smart white shirt.", APCommandNone, nil);
    expect(@"Spotlight node.js docs", APCommandSpotlight, @"node.js docs");
    expect(@"Spotlighting the issue is useful.", APCommandNone, nil);
    expect(@"I opened spotlight and searched.", APCommandNone, nil);
    // Whole-utterance commands only: the same words inside a sentence are dictation.
    expect(@"Scratch that.", APCommandScratch, nil);
    expect(@"delete that", APCommandScratch, nil);
    expect(@"Please delete that file.", APCommandNone, nil);
    expect(@"New line.", APCommandNewLine, nil);
    expect(@"Start a new line here.", APCommandNone, nil);

    // Replacements: whole words and phrases, any case, any spacing; the written form is exact.
    NSArray *pairs = @[@{@"heard": @"clawed code", @"write": @"Claude Code"}, @{@"heard": @"code x", @"write": @"Codex"}, @{@"heard": @" ", @"write": @"ignored"}];
    assert([APApplyReplacements(@"Open Clawed  code, then clawed code.", pairs) isEqual:@"Open Claude Code, then Claude Code."]);
    assert([APApplyReplacements(@"Unclawed code stays.", pairs) isEqual:@"Unclawed code stays."]);
    assert([APApplyReplacements(@"Ask Code X about it", pairs) isEqual:@"Ask Codex about it"]);
    assert([APApplyReplacements(@"$1 and \\ survive", @[@{@"heard": @"survive", @"write": @"$0 \\1"}]) isEqual:@"$1 and \\ $0 \\1"]);
    assert([APReplacementSpellings(pairs) isEqual:(@[@"Claude Code", @"Codex", @"ignored"])]);
    puts("Command checks passed: Spotlight queries, whole-utterance commands, sentences left alone, replacements.");
}}
