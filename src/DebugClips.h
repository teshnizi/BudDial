#import <Foundation/Foundation.h>

@interface APDebugClips : NSObject
@property(readonly) NSUInteger remaining;
- (instancetype)initWithRoot:(NSString *)root;
- (NSString *)reserveAudio:(NSData *)audio metadata:(NSDictionary *)metadata;
- (void)finishDirectory:(NSString *)directory text:(NSString *)text metadata:(NSDictionary *)metadata;
@end
