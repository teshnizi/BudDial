#import <AppKit/AppKit.h>

@class IOBluetoothDevice;
NSArray<IOBluetoothDevice *> *APPairedBuds(void);          // paired AirPods and Beats
NSString *APBluetoothAddress(IOBluetoothDevice *device);   // as bluetoothd logs it, e.g. AA:BB:CC:DD:EE:FF

// The app side of the settings window: values are config keys, applied live.
@protocol APSettingsHost <NSObject>
- (id)settingValue:(NSString *)key;
- (void)setSettingValue:(id)value forKey:(NSString *)key;
// state (NSString), tone (0 ready, 1 active, 2 needs attention), sensor ("covered", "uncovered",
// "worn", "unknown"), connected, microphoneAllowed, accessibilityAllowed (NSNumber BOOLs).
- (NSDictionary *)liveStatus;
- (void)requestMicrophoneAccess;
- (void)openAccessibilitySettings;
- (void)testSound:(id)sender;
- (void)showMonitor:(id)sender;
@end

@interface APSettingsWindow : NSWindow
- (instancetype)initWithHost:(id<APSettingsHost>)host modelsDirectory:(NSString *)modelsDirectory version:(NSString *)version;
- (void)present;   // reloads the choices (devices, microphones, models) and brings the window forward
@end
