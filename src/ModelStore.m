#import "ModelStore.h"
#import <CommonCrypto/CommonDigest.h>

// Sizes and SHA-256 digests from the Hugging Face API (lfs.size, lfs.oid).
static const struct { const char *file, *repo; long long bytes; const char *sha256; } catalog[] = {
    {"ggml-large-v3-turbo-q5_0.bin", "ggerganov/whisper.cpp", 574041195, "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"},
    {"ggml-large-v3-turbo-q8_0.bin", "ggerganov/whisper.cpp", 874188075, "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1"},
    {"ggml-base.en.bin", "ggerganov/whisper.cpp", 147964211, "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"},
    {"ggml-silero-v6.2.0.bin", "ggml-org/whisper-vad", 885098, "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"},
};
static const NSUInteger catalogCount = sizeof(catalog) / sizeof(catalog[0]);

static NSInteger catalogIndex(NSString *file) {
    for (NSUInteger i = 0; i < catalogCount; i++)
        if ([file isEqualToString:@(catalog[i].file)]) return (NSInteger)i;
    return -1;
}

static NSURL *downloadURL(NSString *file) {
    NSInteger index = catalogIndex(file);
    NSString *repo = index < 0 ? @"ggerganov/whisper.cpp" : @(catalog[index].repo);
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://huggingface.co/%@/resolve/main/%@", repo, file]];
}

static NSString *sha256OfFile(NSString *path) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return nil;
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    for (;;) {
        @autoreleasepool {
            NSData *chunk = [handle readDataUpToLength:4 << 20 error:nil];
            if (!chunk.length) break;
            CC_SHA256_Update(&context, chunk.bytes, (CC_LONG)chunk.length);
        }
    }
    [handle closeAndReturnError:nil];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *hex = [NSMutableString stringWithCapacity:2 * CC_SHA256_DIGEST_LENGTH];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static long long fileSize(NSString *path) {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    return attributes ? (long long)attributes.fileSize : -1;
}

static NSString *messageForError(NSError *error) {
    if ([error.domain isEqualToString:NSURLErrorDomain]) switch (error.code) {
        case NSURLErrorNotConnectedToInternet: case NSURLErrorDataNotAllowed: case NSURLErrorInternationalRoamingOff:
        case NSURLErrorCannotFindHost: case NSURLErrorDNSLookupFailed:
            return @"No internet connection";
        case NSURLErrorCannotCreateFile: case NSURLErrorCannotWriteToFile:
            return @"Not enough disk space";
    }
    return @"Download interrupted. Try again.";
}

@interface APModelStore ()
@property(readwrite) NSString *directory, *downloadingFile, *error;
@property(readwrite) long long receivedBytes, totalBytes;
@property NSURLSession *session;
@property NSURLSessionDownloadTask *task;
@property NSMutableDictionary<NSString *, NSData *> *resumeData;   // file -> where its last download stopped
- (void)task:(NSURLSessionTask *)task received:(long long)received;
- (void)task:(NSURLSessionTask *)task endedWithError:(NSString *)error resumeData:(NSData *)resumeData restart:(BOOL)restart;
@end

// The session delegate. It holds the store weakly (a session retains its delegate until invalidated)
// and runs on a private serial queue, so moving and verifying a finished file never blocks the main thread.
@interface APModelDownloadDelegate : NSObject <NSURLSessionDownloadDelegate>
@property(weak) APModelStore *store;
@property NSString *directory;
@property double lastProgress;
@property NSMutableSet<NSNumber *> *resumed;                        // tasks that continued earlier resume data
@property NSMutableDictionary<NSNumber *, id> *outcomes;            // task -> NSNull (installed), error message, or @restart
@end

static NSString *const restartOutcome = @"restart";

@implementation APModelDownloadDelegate
- (void)report:(NSURLSessionTask *)task received:(long long)received force:(BOOL)force {
    double now = NSProcessInfo.processInfo.systemUptime;
    if (!force && now - self.lastProgress < .1) return;
    self.lastProgress = now;
    APModelStore *store = self.store;
    dispatch_async(dispatch_get_main_queue(), ^{ [store task:task received:received]; });
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didResumeAtOffset:(int64_t)offset expectedTotalBytes:(int64_t)total {
    [self.resumed addObject:@(task.taskIdentifier)];
    [self report:task received:offset force:YES];
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)written
    totalBytesWritten:(int64_t)totalWritten totalBytesExpectedToWrite:(int64_t)expected {
    [self report:task received:totalWritten force:NO];
}
// The file at location is deleted when this returns, so it is moved next to its destination first.
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
    NSString *file = task.taskDescription;
    NSNumber *key = @(task.taskIdentifier);
    NSInteger status = [task.response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)task.response).statusCode : 0;
    if (status < 200 || status > 299) {
        // Resume data points at a signed download link that expires; start over from the beginning.
        self.outcomes[key] = [self.resumed containsObject:key] ? restartOutcome : @"The download server is not responding. Try again later.";
        return;
    }
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *destination = [self.directory stringByAppendingPathComponent:file];
    NSString *partial = [self.directory stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.download", file]];
    NSError *error = nil;
    [files removeItemAtPath:partial error:nil];
    if (![files createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:&error] ||
        ![files moveItemAtPath:location.path toPath:partial error:&error]) {
        BOOL full = [error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSFileWriteOutOfSpaceError;
        self.outcomes[key] = full ? @"Not enough disk space" : @"Could not save the model.";
        return;
    }
    long long expected = [APModelStore expectedBytesForModel:file];
    NSInteger index = catalogIndex(file);
    BOOL valid = expected ? fileSize(partial) == expected : fileSize(partial) > 0;
    if (valid && index >= 0) valid = [sha256OfFile(partial) isEqualToString:@(catalog[index].sha256)];
    if (!valid) {
        [files removeItemAtPath:partial error:nil];
        self.outcomes[key] = @"The download was corrupted. Try again.";
        return;
    }
    // rename(2) replaces any existing file atomically: the model is either absent or complete.
    if (rename(partial.fileSystemRepresentation, destination.fileSystemRepresentation) != 0) {
        [files removeItemAtPath:partial error:nil];
        self.outcomes[key] = @"Could not save the model.";
        return;
    }
    self.outcomes[key] = NSNull.null;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSNumber *key = @(task.taskIdentifier);
    id outcome = self.outcomes[key];
    [self.outcomes removeObjectForKey:key];
    [self.resumed removeObject:key];
    NSString *message = nil;
    NSData *resumeData = nil;
    if (error) {
        message = messageForError(error);
        resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData];
    } else if (!outcome) message = @"Download interrupted. Try again.";
    else if (outcome != NSNull.null && outcome != restartOutcome) message = outcome;
    BOOL restart = outcome == restartOutcome;
    APModelStore *store = self.store;
    dispatch_async(dispatch_get_main_queue(), ^{ [store task:task endedWithError:message resumeData:resumeData restart:restart]; });
}
@end

@implementation APModelStore
- (instancetype)initWithDirectory:(NSString *)directory {
    if ((self = [super init])) {
        _directory = [directory copy];
        _resumeData = [NSMutableDictionary dictionary];
        APModelDownloadDelegate *delegate = [APModelDownloadDelegate new];
        delegate.store = self;
        delegate.directory = _directory;
        delegate.resumed = [NSMutableSet set];
        delegate.outcomes = [NSMutableDictionary dictionary];
        NSOperationQueue *queue = [NSOperationQueue new];
        queue.maxConcurrentOperationCount = 1;
        queue.qualityOfService = NSQualityOfServiceUtility;
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.defaultSessionConfiguration;
        config.timeoutIntervalForRequest = 60;
        _session = [NSURLSession sessionWithConfiguration:config delegate:delegate delegateQueue:queue];
    }
    return self;
}
- (void)dealloc { [_session invalidateAndCancel]; }
+ (long long)expectedBytesForModel:(NSString *)file {
    NSInteger index = catalogIndex(file);
    return index < 0 ? 0 : catalog[index].bytes;
}
- (BOOL)isInstalled:(NSString *)file {
    long long size = fileSize([self.directory stringByAppendingPathComponent:file]);
    long long expected = [APModelStore expectedBytesForModel:file];
    return expected ? size == expected : size >= 0;
}
- (void)changed { if (self.onChange) self.onChange(); }
- (void)download:(NSString *)file {
    if (self.downloadingFile || [self isInstalled:file]) return;
    NSData *resumeData = self.resumeData[file];
    [self.resumeData removeObjectForKey:file];
    NSURLSessionDownloadTask *task = resumeData ? [self.session downloadTaskWithResumeData:resumeData] : [self.session downloadTaskWithURL:downloadURL(file)];
    task.taskDescription = file;
    self.task = task;
    self.downloadingFile = file;
    self.error = nil;
    self.receivedBytes = 0;
    self.totalBytes = [APModelStore expectedBytesForModel:file];
    [task resume];
    [self changed];
}
- (void)cancel {
    NSURLSessionDownloadTask *task = self.task;
    if (!task) return;
    NSString *file = self.downloadingFile;
    [task cancelByProducingResumeData:^(NSData *resumeData) {
        if (!resumeData) return;
        dispatch_async(dispatch_get_main_queue(), ^{ if (![self.downloadingFile isEqualToString:file]) self.resumeData[file] = resumeData; });
    }];
    self.task = nil;
    self.downloadingFile = nil;
    [self changed];
}
- (void)task:(NSURLSessionTask *)task received:(long long)received {
    if (task != self.task) return;
    self.receivedBytes = received;
    if (!self.totalBytes && task.countOfBytesExpectedToReceive > 0) self.totalBytes = task.countOfBytesExpectedToReceive;
    [self changed];
}
- (void)task:(NSURLSessionTask *)task endedWithError:(NSString *)error resumeData:(NSData *)resumeData restart:(BOOL)restart {
    if (task != self.task) return;
    NSString *file = self.downloadingFile;
    self.task = nil;
    self.downloadingFile = nil;
    if (restart) { [self download:file]; return; }
    if (resumeData) self.resumeData[file] = resumeData;
    if (!error) self.receivedBytes = self.totalBytes;
    self.error = error;
    [self changed];
}
@end
