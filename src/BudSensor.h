#import <Foundation/Foundation.h>

// Reads AirPods ear-detection changes from bluetoothd's log stream. Whichever
// bud changes is the "button"; both buds in ear means the AirPods are worn.
@interface APBudSensor : NSObject
@property(copy) void (^onChange)(BOOL covered, NSString *source);
@property(copy) void (^onWorn)(BOOL worn);
@property(copy) void (^onEvent)(NSString *line);
@property(readonly) BOOL running;
@property(readonly) BOOL known;
@property(readonly) BOOL worn;
@property(readonly) NSString *rawStates;
@property(readonly) double lastDeliveryMs;
@property(readonly) double lastEventUptime;
- (instancetype)initWithAddress:(NSString *)address;
- (void)start;
- (void)stop;
- (void)simulate:(BOOL)covered;
// After an over-long hold: the covering bud is being worn; ignore it until it leaves the ear.
- (void)markCoveredBudsWorn;
@end
