#import <Foundation/Foundation.h>

// Readable name for a whisper.cpp model file, e.g. "ggml-large-v3-turbo-q5_0.bin" -> "Large v3 Turbo · Q5".
NSString *APModelTitle(NSString *file);

// Keeps one whisper.cpp server running with the model loaded, so a transcript
// costs inference time only (no per-clip model load).
@interface APTranscriber : NSObject
@property(readonly) BOOL ready;
@property(readonly) NSString *status;
@property(readonly) NSString *modelName;
@property NSString *modelFile;   // file name inside models/; restart to apply
@property NSString *language;    // whisper language code or "auto"; restart to apply
@property BOOL useVAD;           // drop silent stretches before decoding; restart to apply
@property NSInteger beamSize;    // 1 = greedy; restart to apply
@property(copy) void (^onEvent)(NSString *line);   // main queue
+ (NSString *)defaultModelFile;
+ (NSArray<NSString *> *)installedModelsIn:(NSString *)directory;
+ (NSString *)vadModelFile;
- (instancetype)initWithSupportDirectory:(NSString *)support;
- (void)start;
- (void)stop;
- (void)restart;
// prompt: prose the speech should continue (context and vocabulary); may be nil.
// completion on main queue; text is nil when error is set.
- (void)transcribeWave:(NSData *)wave prompt:(NSString *)prompt completion:(void (^)(NSString *text, NSString *error, double elapsedMs))completion;
@end
