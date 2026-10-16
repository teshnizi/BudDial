#import "BudSensor.h"

// bluetoothd reports both buds by role (primary/secondary). A bud the user
// wears must not act as a button, so "worn" buds are excluded until they
// leave the ear. The button state is: any non-worn bud reports "in ear".
@interface APBudSensor () {
    BOOL inEar[2], wornBud[2], covered, liveSeen;
}
@property NSString *address;
@property NSTask *task;
@property NSRegularExpression *pattern;
@property NSDateFormatter *formatter;
@property(readwrite) BOOL running;
@property(readwrite) BOOL known;
@property(readwrite) BOOL worn;
@property(readwrite) NSString *rawStates;
@property(readwrite) double lastDeliveryMs;
@property(readwrite) double lastEventUptime;
@end

@implementation APBudSensor
- (instancetype)initWithAddress:(NSString *)address {
    if ((self = [super init])) {
        _address = address;
        _pattern = [NSRegularExpression regularExpressionWithPattern:@"received in-ear state update from device ([0-9A-Fa-f:]{17}) primary bud state = (in ear|out of ear|in case|unknown), secondary bud state = (in ear|out of ear|in case|unknown)" options:0 error:nil];
        _formatter = [NSDateFormatter new];
        _formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        _formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSSSSSZ";
        _rawStates = @"No ear-state event yet";
        _lastDeliveryMs = -1;
    }
    return self;
}
- (NSString *)predicate {
    return [NSString stringWithFormat:@"process == \"bluetoothd\" AND eventMessage CONTAINS[c] \"received in-ear state update from device %@\"", self.address];
}
- (void)start {
    if (self.running) return;
    // Until told otherwise, assume both buds are out: gestures are armed at once.
    self.known = YES;
    if (self.onChange) self.onChange(NO, @"startup");
    [self seedFromHistory];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/log"];
    task.arguments = @[@"stream", @"--style", @"ndjson", @"--level", @"info", @"--predicate", [self predicate]];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    __weak APBudSensor *weakSelf = self;
    task.terminationHandler = ^(NSTask *t) {
        (void)t;
        dispatch_async(dispatch_get_main_queue(), ^{
            APBudSensor *strong = weakSelf;
            if (!strong || strong.task != t) return;
            strong.running = NO;
            if (strong.onEvent) strong.onEvent(@"Bluetooth event reader stopped; restarting.");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [weakSelf start]; });
        });
    };
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        if (self.onEvent) self.onEvent([NSString stringWithFormat:@"Bluetooth event reader failed to start: %@", error.localizedDescription]);
        return;
    }
    self.task = task;
    self.running = YES;
    NSFileHandle *reader = pipe.fileHandleForReading;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        NSMutableData *buffer = [NSMutableData data];
        while (YES) {
            NSData *part = [reader availableData];
            if (!part.length) break;
            [buffer appendData:part];
            while (YES) {
                const char *bytes = buffer.bytes;
                const char *newline = memchr(bytes, '\n', buffer.length);
                if (!newline) break;
                NSUInteger length = (NSUInteger)(newline - bytes);
                NSData *line = [buffer subdataWithRange:NSMakeRange(0, length)];
                [buffer replaceBytesInRange:NSMakeRange(0, length + 1) withBytes:NULL length:0];
                dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf handleLine:line live:YES]; });
            }
            if (buffer.length > 1024 * 1024) [buffer setLength:0];
        }
    });
}
- (void)stop {
    NSTask *task = self.task;
    self.task = nil;
    self.running = NO;
    if (task.running) [task terminate];
}
// The log stream only reports changes. Seed bud states from recent history so a
// bud that is already worn at launch is not mistaken for a button press.
- (void)seedFromHistory {
    NSString *predicate = [self predicate];
    __weak APBudSensor *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/log"];
        task.arguments = @[@"show", @"--last", @"6h", @"--style", @"ndjson", @"--info", @"--predicate", predicate];
        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = [NSFileHandle fileHandleWithNullDevice];
        if (![task launchAndReturnError:nil]) return;
        NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
        NSArray<NSString *> *lines = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] componentsSeparatedByString:@"\n"];
        for (NSString *line in lines.reverseObjectEnumerator) {
            if (![line containsString:@"in-ear state update"]) continue;
            NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf handleLine:lineData live:NO]; });
            break;
        }
    });
}
- (void)handleLine:(NSData *)data live:(BOOL)live {
    if (!live && liveSeen) return;
    NSDictionary *object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSString *message = [object isKindOfClass:NSDictionary.class] ? object[@"eventMessage"] : nil;
    if (![message isKindOfClass:NSString.class]) return;
    NSTextCheckingResult *match = [self.pattern firstMatchInString:message options:0 range:NSMakeRange(0, message.length)];
    if (!match) return;
    NSString *primary = [message substringWithRange:[match rangeAtIndex:2]];
    NSString *secondary = [message substringWithRange:[match rangeAtIndex:3]];
    self.rawStates = [NSString stringWithFormat:@"primary %@ · secondary %@", primary, secondary];
    BOOL p = [primary isEqual:@"in ear"], s = [secondary isEqual:@"in ear"];
    if (!live) {
        // Buds already in an ear at launch are treated as worn.
        inEar[0] = wornBud[0] = p; inEar[1] = wornBud[1] = s;
        self.worn = p && s;
        if (self.onEvent) self.onEvent([NSString stringWithFormat:@"Last known buds: %@.", self.rawStates]);
        return;
    }
    liveSeen = YES;
    self.lastEventUptime = NSProcessInfo.processInfo.systemUptime;
    NSDate *date = [object[@"timestamp"] isKindOfClass:NSString.class] ? [self.formatter dateFromString:object[@"timestamp"]] : nil;
    self.lastDeliveryMs = date ? MAX(0, -date.timeIntervalSinceNow * 1000) : -1;
    [self applyPrimary:p secondary:s source:@"Bluetooth"];
}
- (void)applyPrimary:(BOOL)p secondary:(BOOL)s source:(NSString *)source {
    BOOL next[2] = {p, s};
    if (p != s && p == inEar[1] && s == inEar[0]) {
        // Primary/secondary roles swapped between the buds; nothing moved.
        BOOL w = wornBud[0]; wornBud[0] = wornBud[1]; wornBud[1] = w;
        inEar[0] = p; inEar[1] = s;
        return;
    }
    for (int i = 0; i < 2; i++) {
        if (wornBud[i] && !next[i]) wornBud[i] = NO;  // a worn bud left the ear
        inEar[i] = next[i];
    }
    if (p && s) {
        // Both buds in ear is how people wear AirPods: never a button press, whatever happened before.
        wornBud[0] = wornBud[1] = YES;
    }
    // Worn until both buds are out: with one still in an ear, any cover makes both in-ear anyway.
    BOOL nowWorn = wornBud[0] || wornBud[1];
    if (nowWorn != self.worn) {
        self.worn = nowWorn;
        if (self.onWorn) self.onWorn(nowWorn);
    }
    BOOL nowCovered = (inEar[0] && !wornBud[0]) || (inEar[1] && !wornBud[1]);
    if (nowCovered != covered) {
        covered = nowCovered;
        if (self.onChange) self.onChange(nowCovered, source);
    }
}
- (void)markCoveredBudsWorn {
    for (int i = 0; i < 2; i++) if (inEar[i]) wornBud[i] = YES;
    covered = NO;
    self.worn = wornBud[0] || wornBud[1];
}
- (void)simulate:(BOOL)value {
    self.lastEventUptime = NSProcessInfo.processInfo.systemUptime;
    self.lastDeliveryMs = 0;
    self.rawStates = value ? @"simulated: covered" : @"simulated: uncovered";
    if (value != covered) {
        covered = value;
        if (self.onChange) self.onChange(value, @"simulated");
    }
}
@end
