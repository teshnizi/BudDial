#import <AVFoundation/AVFoundation.h>

// 16 kHz mono capture. With keepOpen, the microphone runs continuously into an
// in-memory ring so a take can start preRollSeconds before the touch event
// arrived; nothing outside a committed take leaves memory.
@interface APRecording : NSObject
@property NSData *pcm;              // 16-bit little-endian mono, 16 kHz
@property double seconds;
@property double speechSeconds;     // frames well above the take's noise floor
@property double preRollMs;         // audio kept from before the touch event (after pause trimming)
@property double firstAudioMs;      // cold start only: touch to first sample
// How long continuous speech had already been running when the touch event arrived
// (measured on the 3 s ring): the AirPod-side delay when you talk as you touch. -1 if unknown.
@property double speechLeadMs;
@property BOOL speechLeadAtLeast;   // speech ran through the whole ring: lead is a lower bound
@property NSString *microphone;
- (NSData *)wave;
@end

@interface APRecorder : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate>
@property(nonatomic) BOOL keepOpen;
@property double preRollSeconds;
@property NSString *microphonePreference;   // "builtin", "default", or a device name
@property(readonly) NSString *microphoneName;
@property(readonly) BOOL open;
@property(readonly) BOOL taking;
@property(copy) void (^onLevel)(double db);        // main queue, ~20 Hz while taking
@property(copy) void (^onSpeech)(double seconds);  // main queue, ~10 Hz for a take's first 15 s: speech heard so far
@property(copy) void (^onEvent)(NSString *line);   // main queue
- (void)applyKeepOpen;
- (void)reopen;
- (void)beginAt:(double)uptime;
- (void)finishWithTail:(double)tail completion:(void (^)(APRecording *recording))completion;
- (void)discard;
@end
