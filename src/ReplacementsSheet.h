#import <AppKit/AppKit.h>

// Edits the replacements list: what the speech engine writes, and what to write instead. Shown as a
// sheet on Settings; the completion gets the cleaned list (rows without a left side dropped).
@interface APReplacementsSheet : NSWindow
- (instancetype)initWithPairs:(NSArray<NSDictionary *> *)pairs completion:(void (^)(NSArray<NSDictionary *> *pairs))completion;
@end
