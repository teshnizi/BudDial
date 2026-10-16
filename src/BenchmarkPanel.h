#import <AppKit/AppKit.h>

// Records the user reading fixed sentences, one take per sentence, saved with the
// reference text under bench/<session>/ for bench.py. Takes are never transcribed or pasted.
@interface APBenchmarkPanel : NSPanel
@property(readonly) BOOL recording;   // open and waiting for takes
- (instancetype)initWithDirectory:(NSString *)directory;
- (void)present;
- (NSString *)saveTake:(NSData *)wave;   // returns a short status for the pill
@end
