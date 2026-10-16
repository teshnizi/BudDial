#import "Feedback.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>

static const double kRate = 44100;

// A soft "bump": one sine gliding between two low pitches, with rounded (raised-cosine)
// fade-in and fade-out. No click at the start and little high-frequency content.
static void glide(NSMutableData *pcm, double fromHz, double toHz, double ms, double amplitude) {
    NSUInteger n = (NSUInteger)(kRate * ms / 1000);
    double attack = kRate * .018, release = kRate * .06, phase = 0;
    for (NSUInteger i = 0; i < n; i++) {
        double t = (double)i / n, hz = fromHz + (toHz - fromHz) * (1 - (1 - t) * (1 - t));
        phase += 2 * M_PI * hz / kRate;
        double in = i < attack ? .5 - .5 * cos(M_PI * i / attack) : 1;
        double out = n - i < release ? .5 - .5 * cos(M_PI * (n - i) / release) : 1;
        int16_t sample = (int16_t)(amplitude * in * out * sin(phase) * 32767);
        [pcm appendBytes:&sample length:2];
    }
}
static void gap(NSMutableData *pcm, double ms) { [pcm increaseLengthBy:(NSUInteger)(kRate * ms / 1000) * 2]; }
static NSData *wave(NSData *pcm) {
    NSMutableData *data = [NSMutableData data];
    uint32_t u32; uint16_t u16;
    [data appendBytes:"RIFF" length:4]; u32 = CFSwapInt32HostToLittle((uint32_t)pcm.length + 36); [data appendBytes:&u32 length:4];
    [data appendBytes:"WAVEfmt " length:8]; u32 = CFSwapInt32HostToLittle(16); [data appendBytes:&u32 length:4];
    u16 = CFSwapInt16HostToLittle(1); [data appendBytes:&u16 length:2]; [data appendBytes:&u16 length:2];
    u32 = CFSwapInt32HostToLittle((uint32_t)kRate); [data appendBytes:&u32 length:4];
    u32 = CFSwapInt32HostToLittle((uint32_t)kRate * 2); [data appendBytes:&u32 length:4];
    u16 = CFSwapInt16HostToLittle(2); [data appendBytes:&u16 length:2];
    u16 = CFSwapInt16HostToLittle(16); [data appendBytes:&u16 length:2];
    [data appendBytes:"data" length:4]; u32 = CFSwapInt32HostToLittle((uint32_t)pcm.length); [data appendBytes:&u32 length:4];
    [data appendData:pcm];
    return data;
}
static NSData *cueSound(APCue cue) {
    NSMutableData *pcm = [NSMutableData data];
    switch (cue) {
        case APCueStart: glide(pcm, 330, 440, 140, .75); break;                        // rising: listening
        case APCueStop:  glide(pcm, 440, 330, 140, .65); break;                        // falling: done
        case APCueEnter: glide(pcm, 392, 370, 70, .65); gap(pcm, 45); glide(pcm, 392, 370, 70, .65); break;
        case APCueDelete: glide(pcm, 349, 294, 80, .6); gap(pcm, 35); glide(pcm, 294, 247, 90, .6); break;  // two steps down: removed
        case APCueError: glide(pcm, 262, 196, 230, .75); break;
    }
    return wave(pcm);
}
static NSString *builtInOutputUID(NSString **name) {
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) || !size) return nil;
    NSMutableData *ids = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, ids.mutableBytes)) return nil;
    for (NSUInteger i = 0; i < size / sizeof(AudioObjectID); i++) {
        AudioObjectID device = ((const AudioObjectID *)ids.bytes)[i];
        AudioObjectPropertyAddress streams = {kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
        UInt32 streamSize = 0;
        if (AudioObjectGetPropertyDataSize(device, &streams, 0, NULL, &streamSize) || !streamSize) continue;
        AudioObjectPropertyAddress transportAddress = {kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        UInt32 transport = 0, transportSize = sizeof(transport);
        if (AudioObjectGetPropertyData(device, &transportAddress, 0, NULL, &transportSize, &transport) || transport != kAudioDeviceTransportTypeBuiltIn) continue;
        CFStringRef uid = NULL, label = NULL; UInt32 stringSize = sizeof(CFStringRef);
        AudioObjectPropertyAddress uidAddress = {kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        if (AudioObjectGetPropertyData(device, &uidAddress, 0, NULL, &stringSize, &uid) || !uid) continue;
        AudioObjectPropertyAddress nameAddress = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        stringSize = sizeof(CFStringRef);
        if (name && !AudioObjectGetPropertyData(device, &nameAddress, 0, NULL, &stringSize, &label) && label) *name = CFBridgingRelease(label);
        return CFBridgingRelease(uid);
    }
    return nil;
}

@interface APFeedback () {
    dispatch_queue_t queue;
    NSArray<AVAudioPlayer *> *players;
}
@property(readwrite) NSString *outputName;
@end

@implementation APFeedback
- (instancetype)init {
    if ((self = [super init])) {
        queue = dispatch_queue_create("dev.buddial.feedback", DISPATCH_QUEUE_SERIAL);
        _mode = @"speakers";
        _outputName = @"Not prepared";
        [self prepare];
    }
    return self;
}
- (void)setMode:(NSString *)mode {
    _mode = mode.length ? mode : @"speakers";
    [self prepare];
}
- (void)prepare {
    NSString *mode = self.mode;
    dispatch_async(queue, ^{
        NSString *name = nil;
        NSString *uid = [mode isEqual:@"speakers"] ? builtInOutputUID(&name) : nil;
        NSMutableArray *next = [NSMutableArray array];
        for (APCue cue = APCueStart; cue <= APCueError; cue++) {
            AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithData:cueSound(cue) error:nil];
            if (uid) player.currentDevice = uid;
            [player prepareToPlay];
            if (player) [next addObject:player];
        }
        self->players = next;
        self.outputName = [mode isEqual:@"off"] ? @"Off" : name ?: @"System output";
    });
}
- (void)play:(APCue)cue {
    if ([self.mode isEqual:@"off"]) return;
    dispatch_async(queue, ^{
        if ((NSUInteger)cue >= self->players.count) return;
        AVAudioPlayer *player = self->players[cue];
        [player stop];
        player.currentTime = 0;
        [player play];
    });
}
@end
