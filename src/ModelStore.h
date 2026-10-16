#import <Foundation/Foundation.h>
// Downloads whisper.cpp speech models into a directory, one at a time, verifying size and SHA-256.
@interface APModelStore : NSObject
- (instancetype)initWithDirectory:(NSString *)directory;
@property(readonly) NSString *directory;
- (BOOL)isInstalled:(NSString *)file;                 // file exists with the catalog size (or any size if not in the catalog)
+ (long long)expectedBytesForModel:(NSString *)file;  // 0 when not in the catalog
- (void)download:(NSString *)file;                    // no-op if installed or already downloading
- (void)cancel;
@property(readonly) NSString *downloadingFile;        // nil when idle
@property(readonly) long long receivedBytes, totalBytes;
@property(readonly) NSString *error;                  // user-facing message of the last failure, nil otherwise; cleared by download:
@property(copy) void (^onChange)(void);               // main queue: progress (throttled to about 10 per second), success, failure
@end
