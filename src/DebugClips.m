#import "DebugClips.h"
#import <sys/stat.h>

@interface APDebugClips ()
@property NSString *root;
@property(readwrite) NSUInteger remaining;
@end
@implementation APDebugClips
- (NSDictionary *)session {
    NSData *data = [NSData dataWithContentsOfFile:[self.root stringByAppendingPathComponent:@"session.json"]];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : @{};
}
- (NSUInteger)quota {
    NSInteger value = [[self session][@"remaining"] integerValue];
    return value > 0 ? MIN(5, value) : 0;
}
- (instancetype)initWithRoot:(NSString *)root {
    if ((self = [super init])) { self.root = root; self.remaining = [self quota]; }
    return self;
}
- (NSString *)reserveAudio:(NSData *)audio metadata:(NSDictionary *)metadata {
    NSUInteger count = [self quota];
    self.remaining = count;
    if (!count) return nil;
    NSString *directory = [self.root stringByAppendingPathComponent:[NSString stringWithFormat:@"clip-%02lu-%@", (unsigned long)(6-count), NSUUID.UUID.UUIDString]];
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil]) return nil;
    chmod(self.root.fileSystemRepresentation, 0700);
    NSMutableDictionary *session = [[self session] mutableCopy];
    session[@"remaining"] = @(count-1);
    NSString *state = [self.root stringByAppendingPathComponent:@"session.json"];
    NSData *json = [NSJSONSerialization dataWithJSONObject:session options:NSJSONWritingPrettyPrinted error:nil];
    if (![json writeToFile:state options:NSDataWritingAtomic error:nil]) {
        [NSFileManager.defaultManager removeItemAtPath:directory error:nil]; return nil;
    }
    chmod(state.fileSystemRepresentation, 0600);
    self.remaining = count-1;
    NSString *path = [directory stringByAppendingPathComponent:@"audio.wav"];
    if (![audio writeToFile:path options:NSDataWritingAtomic error:nil]) {
        [NSFileManager.defaultManager removeItemAtPath:directory error:nil]; return nil;
    }
    chmod(path.fileSystemRepresentation, 0600);
    [self finishDirectory:directory text:nil metadata:metadata];
    return directory;
}
- (void)finishDirectory:(NSString *)directory text:(NSString *)text metadata:(NSDictionary *)metadata {
    if (!directory || ![directory hasPrefix:[self.root stringByAppendingString:@"/"]]) return;
    NSString *path = [directory stringByAppendingPathComponent:@"metadata.json"];
    NSData *old = [NSData dataWithContentsOfFile:path];
    id object = old ? [NSJSONSerialization JSONObjectWithData:old options:0 error:nil] : nil;
    NSMutableDictionary *combined = [object isKindOfClass:NSDictionary.class] ? [object mutableCopy] : [NSMutableDictionary dictionary];
    [combined addEntriesFromDictionary:metadata ?: @{}];
    [[NSJSONSerialization dataWithJSONObject:combined options:NSJSONWritingPrettyPrinted error:nil] writeToFile:path options:NSDataWritingAtomic error:nil];
    chmod(path.fileSystemRepresentation, 0600);
    if (text) {
        NSString *transcript = [directory stringByAppendingPathComponent:@"transcript.txt"];
        [text writeToFile:transcript atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod(transcript.fileSystemRepresentation, 0600);
    }
}
@end
