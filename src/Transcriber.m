#import "Transcriber.h"
#import <libproc.h>
#import <netinet/in.h>
#import <sys/socket.h>

static double uptime(void) { return NSProcessInfo.processInfo.systemUptime; }

static NSData *silenceWave(double seconds) {
    uint32_t bytes = (uint32_t)(seconds * 16000) * 2;
    NSMutableData *data = [NSMutableData data];
    uint32_t u32; uint16_t u16;
    [data appendBytes:"RIFF" length:4]; u32 = CFSwapInt32HostToLittle(bytes + 36); [data appendBytes:&u32 length:4];
    [data appendBytes:"WAVEfmt " length:8]; u32 = CFSwapInt32HostToLittle(16); [data appendBytes:&u32 length:4];
    u16 = CFSwapInt16HostToLittle(1); [data appendBytes:&u16 length:2]; [data appendBytes:&u16 length:2];
    u32 = CFSwapInt32HostToLittle(16000); [data appendBytes:&u32 length:4];
    u32 = CFSwapInt32HostToLittle(32000); [data appendBytes:&u32 length:4];
    u16 = CFSwapInt16HostToLittle(2); [data appendBytes:&u16 length:2];
    u16 = CFSwapInt16HostToLittle(16); [data appendBytes:&u16 length:2];
    [data appendBytes:"data" length:4]; u32 = CFSwapInt32HostToLittle(bytes); [data appendBytes:&u32 length:4];
    [data increaseLengthBy:bytes];
    return data;
}

static uint16_t freePort(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    struct sockaddr_in addr = {.sin_len = sizeof(addr), .sin_family = AF_INET, .sin_port = 0, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    socklen_t length = sizeof(addr);
    uint16_t port = 0;
    if (!bind(fd, (struct sockaddr *)&addr, sizeof(addr)) && !getsockname(fd, (struct sockaddr *)&addr, &length)) port = ntohs(addr.sin_port);
    close(fd);
    return port;
}

@interface APTranscriber ()
@property NSString *support;
@property NSTask *task;
@property NSURLSession *session;
@property uint16_t port;
@property BOOL stopping;
@property NSUInteger quickExits;
@property double launchedAt;
@property NSMutableArray<dispatch_block_t> *waiting;
@property(readwrite) BOOL ready;
@property(readwrite) NSString *status;
@end

NSString *APModelTitle(NSString *file) {
    NSString *core = [[file stringByDeletingPathExtension] stringByReplacingOccurrencesOfString:@"ggml-" withString:@""];
    BOOL english = [core containsString:@".en"];
    core = [core stringByReplacingOccurrencesOfString:@".en" withString:@""];
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    NSString *quantization = nil;
    for (NSString *part in [core componentsSeparatedByString:@"-"]) {
        if ([part hasPrefix:@"q"] && part.length > 1 && isdigit([part characterAtIndex:1])) quantization = [[part componentsSeparatedByString:@"_"].firstObject uppercaseString];
        else if ([part hasPrefix:@"v"] && part.length > 1 && isdigit([part characterAtIndex:1])) [words addObject:part];
        else [words addObject:part.capitalizedString];
    }
    NSString *title = [words componentsJoinedByString:@" "];
    if (quantization) title = [title stringByAppendingFormat:@" · %@", quantization];
    return english ? [title stringByAppendingString:@" · English only"] : title;
}

@implementation APTranscriber
+ (NSString *)defaultModelFile { return @"ggml-large-v3-turbo-q5_0.bin"; }
+ (NSString *)vadModelFile { return @"ggml-silero-v6.2.0.bin"; }
+ (NSArray<NSString *> *)installedModelsIn:(NSString *)directory {
    NSMutableArray *models = [NSMutableArray array];
    for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil])
        if ([file hasPrefix:@"ggml-"] && [file hasSuffix:@".bin"] && ![file containsString:@"silero"]) [models addObject:file];
    return [models sortedArrayUsingSelector:@selector(compare:)];
}
- (instancetype)initWithSupportDirectory:(NSString *)support {
    if ((self = [super init])) {
        _support = support;
        _language = @"en";
        _modelFile = [APTranscriber defaultModelFile];
        _waiting = [NSMutableArray array];
        _status = @"Not started";
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.connectionProxyDictionary = @{};
        config.timeoutIntervalForRequest = 30;
        _session = [NSURLSession sessionWithConfiguration:config];
    }
    return self;
}
- (NSString *)modelName { return APModelTitle(self.modelFile); }
- (NSString *)modelPath { return [[self.support stringByAppendingPathComponent:@"models"] stringByAppendingPathComponent:self.modelFile]; }
- (NSString *)pidPath { return [self.support stringByAppendingPathComponent:@"whisper-server.pid"]; }
// The engine ships inside the app (Contents/MacOS/whisper-server, placed there by build.sh).
- (NSString *)executable {
    NSString *path = [NSBundle.mainBundle pathForAuxiliaryExecutable:@"whisper-server"];
    return path && [NSFileManager.defaultManager isExecutableFileAtPath:path] ? path : nil;
}
- (void)emit:(NSString *)line { if (self.onEvent) self.onEvent(line); }
- (void)setState:(NSString *)status ready:(BOOL)ready {
    self.status = status;
    self.ready = ready;
}
// A previous instance that crashed may have left its server running.
- (void)killStaleServer {
    pid_t pid = (pid_t)[[NSString stringWithContentsOfFile:[self pidPath] encoding:NSUTF8StringEncoding error:nil] intValue];
    if (pid <= 0) return;
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) > 0 && strstr(path, "whisper-server")) kill(pid, SIGTERM);
    [NSFileManager.defaultManager removeItemAtPath:[self pidPath] error:nil];
}
- (void)start {
    if (self.task.running) return;
    self.stopping = NO;
    NSString *executable = [self executable];
    if (!executable) {
        [self setState:@"Engine missing from the app; reinstall Buddial" ready:NO];
        [self emit:@"Speech engine unavailable: whisper-server is missing from the app bundle (broken build)."];
        [self flushWaiting];
        return;
    }
    if (![NSFileManager.defaultManager fileExistsAtPath:[self modelPath]]) {
        [self setState:@"Speech model not downloaded" ready:NO];
        [self emit:[NSString stringWithFormat:@"Speech engine unavailable: the speech model %@ is not downloaded.", self.modelFile]];
        [self flushWaiting];
        return;
    }
    [self killStaleServer];
    self.port = freePort();
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:executable];
    NSMutableArray *arguments = [@[@"-m", [self modelPath], @"--host", @"127.0.0.1", @"--port", [NSString stringWithFormat:@"%u", self.port],
                                   @"-l", self.language, @"-nt", @"-sns", @"-t", @"4"] mutableCopy];
    if (self.beamSize > 1) [arguments addObjectsFromArray:@[@"-bs", [NSString stringWithFormat:@"%ld", (long)self.beamSize]]];
    // Speech detection drops silent stretches before decoding, where Whisper tends to invent text.
    NSString *vad = [[self.support stringByAppendingPathComponent:@"models"] stringByAppendingPathComponent:APTranscriber.vadModelFile];
    if (self.useVAD && [NSFileManager.defaultManager fileExistsAtPath:vad]) [arguments addObjectsFromArray:@[@"--vad", @"-vm", vad]];
    task.arguments = arguments;
    NSString *logPath = [self.support stringByAppendingPathComponent:@"whisper-server.log"];
    [NSData.data writeToFile:logPath atomically:YES];
    NSFileHandle *log = [NSFileHandle fileHandleForWritingAtPath:logPath];
    task.standardOutput = log;
    task.standardError = log;
    __weak APTranscriber *weakSelf = self;
    task.terminationHandler = ^(NSTask *ended) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf serverEnded:ended]; });
    };
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        [self setState:@"whisper-server failed to launch" ready:NO];
        [self emit:[NSString stringWithFormat:@"Speech engine failed to launch: %@", error.localizedDescription]];
        [self flushWaiting];
        return;
    }
    self.task = task;
    self.launchedAt = uptime();
    [[NSString stringWithFormat:@"%d", task.processIdentifier] writeToFile:[self pidPath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self setState:@"Loading model…" ready:NO];
    [self emit:[NSString stringWithFormat:@"Speech engine starting on 127.0.0.1:%u.", self.port]];
    [self pollUntilListening:task];
}
- (void)serverEnded:(NSTask *)ended {
    if (ended != self.task) return;
    self.task = nil;
    [NSFileManager.defaultManager removeItemAtPath:[self pidPath] error:nil];
    [self setState:@"Stopped" ready:NO];
    if (self.stopping) return;
    self.quickExits = uptime() - self.launchedAt < 10 ? self.quickExits + 1 : 0;
    if (self.quickExits >= 3) {
        [self setState:@"whisper-server keeps exiting; see whisper-server.log" ready:NO];
        [self emit:@"Speech engine exited repeatedly; see whisper-server.log."];
        [self flushWaiting];
        return;
    }
    [self emit:@"Speech engine exited; restarting."];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self start]; });
}
- (void)pollUntilListening:(NSTask *)task {
    if (task != self.task || !task.running) return;
    if (uptime() - self.launchedAt > 120) {
        self.quickExits = 3;   // treat as failed: stop queueing requests behind it
        [self setState:@"Model load timed out" ready:NO];
        [self emit:@"Speech engine did not start within 120 s."];
        [self flushWaiting];
        return;
    }
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/", self.port]];
    NSURLRequest *request = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:2];
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        (void)data; (void)error;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (task != self.task) return;
            if (![response isKindOfClass:NSHTTPURLResponse.class]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{ [self pollUntilListening:task]; });
                return;
            }
            // Warm the GPU kernels so the first real transcript is fast.
            double warmStart = uptime();
            [self post:silenceWave(.5) prompt:nil completion:^(NSString *text, NSString *failure) {
                (void)text;
                if (task != self.task) return;
                [self setState:@"Ready" ready:YES];
                [self emit:[NSString stringWithFormat:@"Speech engine ready (%.1f s to load, warm-up %.0f ms%@).", uptime() - self.launchedAt, (uptime() - warmStart) * 1000, failure ? [@"; warm-up error: " stringByAppendingString:failure] : @""]];
                [self flushWaiting];
            }];
        });
    }] resume];
}
// Each waiting request re-checks readiness: it runs if ready, else fails with the current status.
- (void)flushWaiting {
    NSArray<dispatch_block_t> *blocks = [self.waiting copy];
    [self.waiting removeAllObjects];
    for (dispatch_block_t block in blocks) block();
}
- (void)stop {
    self.stopping = YES;
    if (self.task.running) [self.task terminate];
    self.task = nil;
    [NSFileManager.defaultManager removeItemAtPath:[self pidPath] error:nil];
    [self setState:@"Stopped" ready:NO];
}
// Applies a new model or language: requests already waiting are served by the new server.
- (void)restart {
    [self stop];
    self.quickExits = 0;
    [self start];
}
- (void)post:(NSData *)wave prompt:(NSString *)prompt completion:(void (^)(NSString *text, NSString *error))completion {
    NSString *boundary = [@"apd-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSMutableData *body = [NSMutableData data];
    void (^field)(NSString *, NSString *) = ^(NSString *name, NSString *value) {
        [body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"%@\"\r\n\r\n%@\r\n", boundary, name, value] dataUsingEncoding:NSUTF8StringEncoding]];
    };
    field(@"response_format", @"json");
    field(@"temperature", @"0.0");
    if (prompt.length) field(@"prompt", prompt);
    [body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:wave];
    [body appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/inference", self.port]]];
    request.HTTPMethod = @"POST";
    [request setValue:[@"multipart/form-data; boundary=" stringByAppendingString:boundary] forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = body;
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *text = nil, *failure = nil;
        NSInteger code = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSDictionary *object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (error) failure = error.localizedDescription;
        else if (code != 200 || ![object isKindOfClass:NSDictionary.class] || ![object[@"text"] isKindOfClass:NSString.class]) failure = [NSString stringWithFormat:@"Speech engine returned HTTP %ld", (long)code];
        else {
            NSArray *words = [object[@"text"] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            text = [[words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(text, failure); });
    }] resume];
}
- (void)transcribeWave:(NSData *)wave prompt:(NSString *)prompt completion:(void (^)(NSString *, NSString *, double))completion {
    double requested = uptime();
    dispatch_block_t run = ^{
        if (!self.ready) { completion(nil, self.status ?: @"Speech engine unavailable", (uptime() - requested) * 1000); return; }
        double started = uptime();
        [self post:wave prompt:prompt completion:^(NSString *text, NSString *failure) {
            completion(text, failure, (uptime() - started) * 1000);
        }];
    };
    // Wait while the server is loading or restarting; fail fast only when it cannot come back.
    BOOL recoverable = !self.stopping && self.quickExits < 3 && [self executable] && [NSFileManager.defaultManager fileExistsAtPath:[self modelPath]];
    if (!self.ready && recoverable) [self.waiting addObject:run];
    else run();
}
@end
