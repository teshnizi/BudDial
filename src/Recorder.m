#import "Recorder.h"
#import <IOKit/audio/IOAudioTypes.h>
#import <CoreMedia/CoreMedia.h>

static const double kRate = 16000;
static const double kRingSeconds = 3;
static double uptime(void) { return NSProcessInfo.processInfo.systemUptime; }

static void append32(NSMutableData *data, uint32_t value) { uint32_t v = CFSwapInt32HostToLittle(value); [data appendBytes:&v length:4]; }
static void append16(NSMutableData *data, uint16_t value) { uint16_t v = CFSwapInt16HostToLittle(value); [data appendBytes:&v length:2]; }

typedef struct { NSUInteger cut; double speechSeconds; } APTakeAnalysis;

// 20 ms frame energies against the take's own noise floor (capped, so a take that
// is speech throughout still counts as speech). Pre-roll audio is kept only for
// speech that runs across the touch: walking back from the touch, the first pause
// of 200 ms or more ends the utterance, and everything before it is cut.
// The start cue comes back through the mic 100-200 ms after the touch. Frames in the 0.6 s after
// the touch with at least half their power in its band (300-470 Hz) are not counted as speech: on
// the 2026-10-15 takes the cue added 0.06-0.10 s to every touch, and no real speech frame in that
// window looked like it (tools/eval_speech_detection.c measures both).
static APTakeAnalysis analyzeTake(const int16_t *x, NSUInteger n, NSUInteger touch) {
    const NSUInteger frame = 320;
    NSUInteger frames = n / frame;
    APTakeAnalysis result = {0, 0};
    if (frames < 5) return result;
    double *db = malloc(frames * sizeof(double)), *sorted = malloc(frames * sizeof(double)), *cueShare = malloc(frames * sizeof(double));
    // RBJ band-pass biquad, 0 dB peak at 375 Hz, 170 Hz wide: the start cue's band.
    double w0 = 2 * M_PI * 375 / kRate, q = 375.0 / 170, alpha = sin(w0) / (2 * q), a0 = 1 + alpha;
    double b0 = alpha / a0, b2 = -alpha / a0, a1 = -2 * cos(w0) / a0, a2 = (1 - alpha) / a0;
    double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    for (NSUInteger f = 0; f < frames; f++) {
        double sum = 0, band = 0;
        for (NSUInteger i = 0; i < frame; i++) {
            double v = x[f * frame + i] / 32768.0, y = b0 * v + b2 * x2 - a1 * y1 - a2 * y2;
            x2 = x1; x1 = v; y2 = y1; y1 = y;
            sum += v * v; band += y * y;
        }
        db[f] = sorted[f] = 20 * log10(MAX(1e-5, sqrt(sum / frame)));
        cueShare[f] = sum > 0 ? band / sum : 0;
    }
    for (NSUInteger i = 1; i < frames; i++) {   // insertion sort: frames ≤ 9000
        double v = sorted[i]; NSUInteger j = i;
        while (j > 0 && sorted[j - 1] > v) { sorted[j] = sorted[j - 1]; j--; }
        sorted[j] = v;
    }
    double threshold = MAX(MIN(sorted[frames / 5], -45) + 10, -52);
    NSUInteger touchFrame = MIN(frames, touch / frame), quiet = 0, first = 0;
    for (NSInteger f = (NSInteger)touchFrame - 1; f >= 0; f--) {
        if (db[f] > threshold) { quiet = 0; continue; }
        if (++quiet == 10) {
            NSUInteger speechStart = (NSUInteger)f + quiet;   // first frame after the pause
            first = speechStart > 5 ? speechStart - 5 : 0;    // keep 100 ms of lead-in
            break;
        }
    }
    NSUInteger speech = 0, cueEnd = touchFrame + 30;   // 0.6 s
    for (NSUInteger f = first; f < frames; f++)
        if (db[f] > threshold && !(f >= touchFrame && f < cueEnd && cueShare[f] >= .5)) speech++;
    free(db); free(sorted); free(cueShare);
    result.cut = first * frame;
    result.speechSeconds = speech * 0.02;
    return result;
}

@implementation APRecording
- (NSData *)wave {
    NSMutableData *data = [NSMutableData data];
    [data appendBytes:"RIFF" length:4]; append32(data, (uint32_t)self.pcm.length + 36);
    [data appendBytes:"WAVEfmt " length:8]; append32(data, 16); append16(data, 1); append16(data, 1);
    append32(data, (uint32_t)kRate); append32(data, (uint32_t)kRate * 2); append16(data, 2); append16(data, 16);
    [data appendBytes:"data" length:4]; append32(data, (uint32_t)self.pcm.length); [data appendData:self.pcm];
    return data;
}
@end

@interface APRecorder () {
    dispatch_queue_t queue;
    AVCaptureSession *session;
    AVCaptureAudioDataOutput *output;
    NSMutableData *ring, *take;
    double lastArrival, takeRequested, firstSampleAt, lastLevelPost, lastSpeechPost, preRollMs, speechLeadMs;
    BOOL speechLeadAtLeast;
    NSUInteger generation;
    id runtimeObserver;
}
@property(readwrite) NSString *microphoneName;
@property(readwrite) BOOL open;
@property(readwrite) BOOL taking;
@end

@implementation APRecorder
- (instancetype)init {
    if ((self = [super init])) {
        queue = dispatch_queue_create("dev.buddial.recorder", DISPATCH_QUEUE_SERIAL);
        ring = [NSMutableData data];
        _preRollSeconds = .6;
        _microphonePreference = @"builtin";
        _microphoneName = @"Not open";
    }
    return self;
}
- (void)emit:(NSString *)line {
    void (^sink)(NSString *) = self.onEvent;
    if (sink) dispatch_async(dispatch_get_main_queue(), ^{ sink(line); });
}
- (AVCaptureDevice *)chooseDevice {
    AVCaptureDeviceDiscoverySession *discovery = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeMicrophone, AVCaptureDeviceTypeExternal] mediaType:AVMediaTypeAudio position:AVCaptureDevicePositionUnspecified];
    NSString *preference = self.microphonePreference ?: @"builtin";
    for (AVCaptureDevice *device in discovery.devices) {
        if ([preference isEqual:@"builtin"] ? device.transportType == kIOAudioDeviceTransportTypeBuiltIn
                                             : [device.localizedName localizedCaseInsensitiveContainsString:preference]) return device;
    }
    return [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
}
// Runs on queue.
- (BOOL)openSession {
    if (session) return YES;
    if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] != AVAuthorizationStatusAuthorized) return NO;
    AVCaptureDevice *device = [self chooseDevice];
    NSError *error = nil;
    AVCaptureDeviceInput *input = device ? [AVCaptureDeviceInput deviceInputWithDevice:device error:&error] : nil;
    if (!input) { [self emit:@"Microphone could not be opened."]; return NO; }
    AVCaptureSession *next = [AVCaptureSession new];
    AVCaptureAudioDataOutput *out = [AVCaptureAudioDataOutput new];
    out.audioSettings = @{AVFormatIDKey:@(kAudioFormatLinearPCM), AVSampleRateKey:@(kRate), AVNumberOfChannelsKey:@1,
        AVLinearPCMBitDepthKey:@16, AVLinearPCMIsFloatKey:@NO, AVLinearPCMIsBigEndianKey:@NO, AVLinearPCMIsNonInterleaved:@NO};
    [out setSampleBufferDelegate:self queue:queue];
    if (![next canAddInput:input] || ![next canAddOutput:out]) { [self emit:@"Microphone format unavailable."]; return NO; }
    [next addInput:input]; [next addOutput:out];
    session = next; output = out;
    [ring setLength:0]; lastArrival = 0;
    __weak APRecorder *weakSelf = self;
    runtimeObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVCaptureSessionRuntimeErrorNotification object:next queue:nil usingBlock:^(NSNotification *note) {
        (void)note;
        APRecorder *strong = weakSelf;
        if (!strong) return;
        dispatch_async(strong->queue, ^{
            [strong emit:@"Microphone stopped unexpectedly; reopening."];
            [strong closeSession];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), strong->queue, ^{ if (strong.keepOpen || strong.taking) [strong openSession]; });
        });
    }];
    [session startRunning];
    if (!session.running) { [self closeSession]; [self emit:@"Microphone did not start."]; return NO; }
    self.microphoneName = device.localizedName;
    self.open = YES;
    return YES;
}
// Runs on queue.
- (void)closeSession {
    if (runtimeObserver) { [NSNotificationCenter.defaultCenter removeObserver:runtimeObserver]; runtimeObserver = nil; }
    [output setSampleBufferDelegate:nil queue:NULL];
    [session stopRunning];
    session = nil; output = nil;
    [ring setLength:0]; lastArrival = 0;
    self.open = NO;
}
- (void)setKeepOpen:(BOOL)keepOpen { _keepOpen = keepOpen; [self applyKeepOpen]; }
- (void)applyKeepOpen {
    dispatch_async(queue, ^{
        if (self.keepOpen && !self->session) { if ([self openSession]) [self emit:[NSString stringWithFormat:@"Microphone ready: %@ (instant start).", self.microphoneName]]; }
        else if (!self.keepOpen && self->session && !self.taking) [self closeSession];
    });
}
// Applies a new microphone preference; a take in progress keeps its device until it ends.
- (void)reopen {
    dispatch_async(queue, ^{
        if (self.taking) return;
        [self closeSession];
        if (self.keepOpen && [self openSession]) [self emit:[NSString stringWithFormat:@"Microphone ready: %@.", self.microphoneName]];
    });
}
- (void)beginAt:(double)touch {
    double preRoll = MAX(0, self.preRollSeconds);
    dispatch_async(queue, ^{
        self->generation++;
        self->take = [NSMutableData data];
        self->takeRequested = touch; self->firstSampleAt = 0; self->lastSpeechPost = 0; self->preRollMs = 0; self->speechLeadMs = -1; self->speechLeadAtLeast = NO;
        self.taking = YES;
        if (self->session && self->lastArrival > 0) {
            NSUInteger available = self->ring.length / 2;
            double sinceTouch = MAX(0, (self->lastArrival - touch) * kRate);
            NSUInteger touchIndex = available - MIN(available, (NSUInteger)sinceTouch);
            APTakeAnalysis lead = analyzeTake(self->ring.bytes, available, touchIndex);
            // Whole 20 ms frames: the sub-frame remainder of the touch position is not speech.
            self->speechLeadMs = MAX(0, floor(((double)touchIndex - lead.cut) / 320) * 20 - 100);
            self->speechLeadAtLeast = lead.cut == 0 && self->speechLeadMs > 0;
            NSUInteger count = MIN(available, (NSUInteger)(sinceTouch + preRoll * kRate));
            [self->take appendBytes:(const char *)self->ring.bytes + (available - count) * 2 length:count * 2];
            self->preRollMs = MAX(0, (count - sinceTouch) / kRate * 1000);
            self->firstSampleAt = touch;
        } else if (![self openSession]) {
            self.taking = NO; self->take = nil;
        }
    });
}
- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    (void)connection;
    if (captureOutput != output) return;
    const AudioStreamBasicDescription *format = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sample));
    if (!format || format->mSampleRate != kRate || format->mChannelsPerFrame != 1 || format->mBitsPerChannel != 16 || (format->mFormatFlags & kAudioFormatFlagIsFloat)) return;
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    size_t size = block ? CMBlockBufferGetDataLength(block) : 0;
    if (!size || size > 1024 * 1024) return;
    NSMutableData *part = [NSMutableData dataWithLength:size];
    if (CMBlockBufferCopyDataBytes(block, 0, size, part.mutableBytes)) return;
    double now = uptime();
    lastArrival = now;
    [ring appendData:part];
    NSUInteger limit = (NSUInteger)(kRingSeconds * kRate) * 2;
    if (ring.length > limit) [ring replaceBytesInRange:NSMakeRange(0, ring.length - limit) withBytes:NULL length:0];
    if (!self.taking || !take) return;
    if (!firstSampleAt) firstSampleAt = now;
    if (take.length < (NSUInteger)(kRate * 2 * 180)) [take appendData:part];
    // Speech heard so far, measured exactly as the finished take will be, for the live "release to"
    // hint. Only the first 15 s: the analysis sorts every frame, and by then the hint has settled.
    if (now - lastSpeechPost >= .1 && now - takeRequested < 15) {
        lastSpeechPost = now;
        double heard = analyzeTake(take.bytes, take.length / 2, (NSUInteger)(preRollMs / 1000 * kRate)).speechSeconds;
        void (^speech)(double) = self.onSpeech;
        if (speech) dispatch_async(dispatch_get_main_queue(), ^{ speech(heard); });
    }
    if (now - lastLevelPost < .05) return;
    lastLevelPost = now;
    const int16_t *samples = part.bytes;
    double sum = 0;
    for (size_t i = 0; i < size / 2; i++) { double v = samples[i] / 32768.0; sum += v * v; }
    double db = 20 * log10(MAX(1e-5, sqrt(sum / MAX(1, size / 2))));
    void (^level)(double) = self.onLevel;
    if (level) dispatch_async(dispatch_get_main_queue(), ^{ level(db); });
}
- (void)finishWithTail:(double)tail completion:(void (^)(APRecording *))completion {
    dispatch_async(queue, ^{
        NSUInteger token = self->generation;
        // Let audio already buffered by the device arrive before closing the take.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(tail * NSEC_PER_SEC)), self->queue, ^{
            if (token != self->generation || !self.taking) return;
            NSData *pcm = self->take ?: [NSData data];
            NSUInteger touch = (NSUInteger)(self->preRollMs / 1000 * kRate);
            APTakeAnalysis analysis = analyzeTake(pcm.bytes, pcm.length / 2, touch);
            APRecording *recording = [APRecording new];
            recording.pcm = [pcm subdataWithRange:NSMakeRange(analysis.cut * 2, pcm.length - analysis.cut * 2)];
            recording.seconds = recording.pcm.length / 2 / kRate;
            recording.speechSeconds = analysis.speechSeconds;
            recording.preRollMs = MAX(0, self->preRollMs - analysis.cut / kRate * 1000);
            recording.speechLeadMs = self->speechLeadMs;
            recording.speechLeadAtLeast = self->speechLeadAtLeast;
            recording.firstAudioMs = self->firstSampleAt ? MAX(0, (self->firstSampleAt - self->takeRequested) * 1000) : -1;
            recording.microphone = self.microphoneName;
            self->take = nil;
            self.taking = NO;
            if (!self.keepOpen) [self closeSession];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(recording); });
        });
    });
}
- (void)discard {
    dispatch_async(queue, ^{
        self->generation++;
        self->take = nil;
        self.taking = NO;
        if (!self.keepOpen) [self closeSession];
    });
}
@end
