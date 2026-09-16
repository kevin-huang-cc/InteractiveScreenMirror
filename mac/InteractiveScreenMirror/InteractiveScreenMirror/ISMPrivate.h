// Private CoreGraphics virtual-display API.
// No public headers exist; these declarations were verified against the
// Objective-C runtime on macOS 26.2 (see tools/probe.m in the repo history).
// ponytail: private API, personal use only. If a macOS update changes these
// selectors, VirtualDisplayManager.create() returns nil and the app falls back
// to mirroring the real display.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

/// Turns a display off entirely (it leaves Displays settings), the way Mac
/// Virtual Display blanks the built-in panel. Exported by CoreGraphics; used
/// by BetterDisplay and DisableMonitor for the same purpose.
CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef _Nonnull config,
                                   CGDirectDisplayID display, bool enabled);

@interface CGVirtualDisplayDescriptor : NSObject
@property(strong) dispatch_queue_t queue;
@property(copy) NSString *name;
@property CGSize sizeInMillimeters;
@property unsigned int maxPixelsWide;
@property unsigned int maxPixelsHigh;
@property unsigned int vendorID;
@property unsigned int productID;
@property unsigned int serialNum;
@property CGPoint redPrimary;
@property CGPoint greenPrimary;
@property CGPoint bluePrimary;
@property CGPoint whitePoint;
@property(copy) void (^terminationHandler)(id _Nullable, id _Nullable);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(strong) NSArray<CGVirtualDisplayMode *> *modes;
@property unsigned int hiDPI;
@property unsigned int rotation;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(readonly) CGDirectDisplayID displayID;
@end
