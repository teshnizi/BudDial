#import "DebugClips.h"
#include <assert.h>
int main(void) { @autoreleasepool {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    APDebugClips *clips = [[APDebugClips alloc] initWithRoot:root];
    assert(clips.remaining == 0);
    assert([clips reserveAudio:NSData.data metadata:@{}] == nil);
    NSData *authorization = [@"{\"remaining\":5,\"sessionID\":\"test\"}" dataUsingEncoding:NSUTF8StringEncoding];
    [authorization writeToFile:[root stringByAppendingPathComponent:@"session.json"] atomically:YES];
    for (int i=0;i<5;i++) {
        clips = [[APDebugClips alloc] initWithRoot:root];
        NSString *path = [clips reserveAudio:[@"test audio" dataUsingEncoding:NSUTF8StringEncoding] metadata:@{@"test":@YES}];
        assert(path != nil && clips.remaining == (NSUInteger)(4-i));
        [clips finishDirectory:path text:@"test transcript" metadata:@{@"outcome":@"pasted"}];
        NSString *text = [NSString stringWithContentsOfFile:[path stringByAppendingPathComponent:@"transcript.txt"] encoding:NSUTF8StringEncoding error:nil];
        assert([text isEqual:@"test transcript"]);
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        assert(([attrs[NSFilePosixPermissions] unsignedIntValue] & 0777) == 0700);
        for (NSString *name in @[@"audio.wav", @"transcript.txt", @"metadata.json"]) {
            NSDictionary *file = [NSFileManager.defaultManager attributesOfItemAtPath:[path stringByAppendingPathComponent:name] error:nil];
            assert(([file[NSFilePosixPermissions] unsignedIntValue] & 0777) == 0600);
        }
        NSData *data = [NSData dataWithContentsOfFile:[path stringByAppendingPathComponent:@"metadata.json"]];
        NSDictionary *metadata = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        assert([metadata[@"test"] boolValue] && [metadata[@"outcome"] isEqual:@"pasted"]);
    }
    clips = [[APDebugClips alloc] initWithRoot:root];
    assert(clips.remaining == 0);
    assert([clips reserveAudio:NSData.data metadata:@{}] == nil);
    assert([NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil].count == 6);
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    puts("Debug retention checks passed: default off, five-clip limit across restarts, private files, transcript/metadata output.");
} return 0; }
