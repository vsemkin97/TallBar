//
//  TallBarDisplayManager.m
//  TallBar - Universal Adaptive Tall Menu Bar for macOS
//

#import "TallBarDisplayManager.h"
#import <AppKit/AppKit.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <math.h>

struct SLVSizeInt {
    uint32_t width;
    uint32_t height;
};

struct SLVSizeFloat {
    float width;
    float height;
};

struct SLVPointFloat {
    float x;
    float y;
};

struct SLVChromaticities {
    struct SLVPointFloat red;
    struct SLVPointFloat green;
    struct SLVPointFloat blue;
    struct SLVPointFloat white;
};

@interface SLVirtualDisplayConfiguration : NSObject
- (instancetype)initWithName:(NSString *)name
                    vendorID:(uint64_t)vendorID
                   productID:(uint64_t)productID
                serialNumber:(uint64_t)serialNumber
           sizeInMillimeters:(struct SLVSizeFloat)sizeInMillimeters
         maximumSizeInPixels:(struct SLVSizeInt)maximumSizeInPixels
              chromaticities:(struct SLVChromaticities)chromaticities
                       error:(NSError **)error;
@property (nonatomic, assign) uint32_t subtype;
@end

@interface SLVirtualDisplayMode : NSObject
- (instancetype)initWithSizeInPixels:(struct SLVSizeInt)sizeInPixels
                        sizeInPoints:(struct SLVSizeInt)sizeInPoints
                         refreshRate:(float)refreshRate
                               error:(NSError **)error;
@end

@interface SLVirtualDisplaySettings : NSObject
- (instancetype)initWithNativeMode:(SLVirtualDisplayMode *)nativeMode
                     preferredMode:(SLVirtualDisplayMode *)preferredMode
                     optionalModes:(NSArray<SLVirtualDisplayMode *> *)optionalModes
                         rotations:(uint64_t)rotations
                             error:(NSError **)error;
@end

@interface SLVirtualDisplay : NSObject
- (instancetype)initWithConfiguration:(SLVirtualDisplayConfiguration *)configuration
                                error:(NSError **)error;
- (BOOL)applySettings:(SLVirtualDisplaySettings *)settings error:(NSError **)error;
@property (nonatomic, readonly) uint32_t displayID;
@end

@interface SecondaryDisplayPosition : NSObject
@property (nonatomic, assign) CGDirectDisplayID displayID;
@property (nonatomic, assign) int32_t relX;
@property (nonatomic, assign) int32_t relY;
@end

@implementation SecondaryDisplayPosition
@end

@interface TallBarDisplayManager () {
    id _virtualDisplay;
    id _config;
    id _settings;
    id _mode;
    NSArray *_modesArray;
    NSMutableArray<SecondaryDisplayPosition *> *_savedSecondaryPositions;
}
@end

static NSMutableArray *_retainedWindows = nil;

static void retainWindowIfNeeded(NSWindow *window) {
    if (window && ![_retainedWindows containsObject:window]) {
        [_retainedWindows addObject:window];
    }
}

static void *VDMSkyLightHandle(void) {
    static void *handle = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    });
    return handle;
}

static inline BOOL VDMIsOurVirtualDisplay(CGDirectDisplayID d) {
    uint32_t vendor = CGDisplayVendorNumber(d);
    uint32_t model = CGDisplayModelNumber(d);
    uint32_t serial = CGDisplaySerialNumber(d);
    if (vendor == 0x1234) return YES;
    if (vendor == 0x0610 && model == 0x0F93 && !CGDisplayIsBuiltin(d)) return YES;
    return (serial == 0x4731 || (serial >= 0x4860 && serial <= 0x4880));
}

static CFArrayRef VDMCopyDesktopModes(CGDirectDisplayID displayID) {
    NSDictionary *opts = @{ (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES };
    return CGDisplayCopyAllDisplayModes(displayID, (__bridge CFDictionaryRef)opts);
}

static const uint32_t kVDMDisplayModeNativeFlag = 0x02000000;

static BOOL VDMIsOneToOne(CGDisplayModeRef mode) {
    return CGDisplayModeGetWidth(mode) == CGDisplayModeGetPixelWidth(mode) &&
           CGDisplayModeGetHeight(mode) == CGDisplayModeGetPixelHeight(mode);
}

static BOOL VDMNativePixelSizeInModes(CFArrayRef modes, size_t *outWidth, size_t *outHeight) {
    size_t flaggedW = 0, flaggedH = 0, flaggedPixels = 0;
    size_t oneToOneW = 0, oneToOneH = 0, oneToOnePixels = 0;

    CFIndex count = CFArrayGetCount(modes);
    for (CFIndex i = 0; i < count; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (!CGDisplayModeIsUsableForDesktopGUI(mode)) continue;
        if (!VDMIsOneToOne(mode)) continue;

        size_t w = CGDisplayModeGetPixelWidth(mode);
        size_t h = CGDisplayModeGetPixelHeight(mode);

        if ((CGDisplayModeGetIOFlags(mode) & kVDMDisplayModeNativeFlag) && w * h > flaggedPixels) {
            flaggedPixels = w * h;
            flaggedW = w;
            flaggedH = h;
        }
        if (w * h > oneToOnePixels) {
            oneToOnePixels = w * h;
            oneToOneW = w;
            oneToOneH = h;
        }
    }

    size_t w = flaggedPixels > 0 ? flaggedW : oneToOneW;
    size_t h = flaggedPixels > 0 ? flaggedH : oneToOneH;
    if (w == 0 || h == 0) return NO;
    if (outWidth) *outWidth = w;
    if (outHeight) *outHeight = h;
    return YES;
}

static BOOL VDMNativePixelSize(CGDirectDisplayID displayID, size_t *outWidth, size_t *outHeight) {
    CFArrayRef modes = VDMCopyDesktopModes(displayID);
    if (!modes) return NO;
    BOOL found = VDMNativePixelSizeInModes(modes, outWidth, outHeight);
    CFRelease(modes);
    return found;
}

typedef bool (*SLSIsDisplayModeVRRFn)(int displayID, int modeNum);

static BOOL VDMDisplayModeIsVRR(CGDirectDisplayID displayID, CGDisplayModeRef mode) {
    if (!mode) return NO;
    static SLSIsDisplayModeVRRFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (SLSIsDisplayModeVRRFn)dlsym(VDMSkyLightHandle(), "SLSIsDisplayModeVRR");
    });
    if (!fn) return NO;
    return fn((int)displayID, CGDisplayModeGetIODisplayModeID(mode)) ? YES : NO;
}

static CGDisplayModeRef CopyBestModeAtRate(CGDirectDisplayID displayID, double refreshRate) {
    CFArrayRef modes = VDMCopyDesktopModes(displayID);
    if (!modes) return NULL;

    size_t nativeW = 0, nativeH = 0;
    BOOL haveNative = VDMNativePixelSizeInModes(modes, &nativeW, &nativeH);

    CGDisplayModeRef nativeAtRate = NULL;
    CGDisplayModeRef nativeFastest = NULL;
    CGDisplayModeRef nativeVRRAtRate = NULL;
    CGDisplayModeRef anyAtRate = NULL;
    double nativeFastestRate = -1;
    size_t anyAtRatePixels = 0;

    CFIndex count = CFArrayGetCount(modes);
    for (CFIndex i = 0; i < count; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (!CGDisplayModeIsUsableForDesktopGUI(mode)) continue;
        if (!VDMIsOneToOne(mode)) continue;

        double rate = CGDisplayModeGetRefreshRate(mode);
        BOOL rateMatches = fabs(rate - refreshRate) <= 0.5;

        size_t pw = CGDisplayModeGetPixelWidth(mode);
        size_t ph = CGDisplayModeGetPixelHeight(mode);
        BOOL isNativeSize = haveNative && pw == nativeW && ph == nativeH;

        if (VDMDisplayModeIsVRR(displayID, mode)) {
            if (isNativeSize && rateMatches && !nativeVRRAtRate) nativeVRRAtRate = mode;
            continue;
        }

        if (isNativeSize) {
            if (rateMatches && !nativeAtRate) nativeAtRate = mode;
            if (rate > nativeFastestRate) {
                nativeFastestRate = rate;
                nativeFastest = mode;
            }
        }

        if (rateMatches && pw * ph > anyAtRatePixels) {
            anyAtRatePixels = pw * ph;
            anyAtRate = mode;
        }
    }

    CGDisplayModeRef best = nativeAtRate;
    if (!best) best = nativeFastest;
    if (!best && nativeVRRAtRate) best = nativeVRRAtRate;
    if (!best && anyAtRate) best = anyAtRate;

    CGDisplayModeRef retained = best ? (CGDisplayModeRef)CGDisplayModeRetain(best) : NULL;
    CFRelease(modes);
    return retained;
}

static CGFloat cfDictGetFixed16(CFDictionaryRef dict, CFStringRef key) {
    CFNumberRef ref = CFDictionaryGetValue(dict, key);
    if (!ref) return 0;
    int32_t raw = 0;
    CFNumberGetValue(ref, kCFNumberSInt32Type, &raw);
    return (CGFloat)raw / 65536.0;
}

static struct SLVChromaticities getAdaptiveChromaticities(CGDirectDisplayID displayID) {
    struct SLVChromaticities chrom = {
        { 0.6400f, 0.3300f },
        { 0.3000f, 0.6000f },
        { 0.1500f, 0.0600f },
        { 0.3127f, 0.3290f }
    };

    io_iterator_t iter;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iter) != KERN_SUCCESS) {
        return chrom;
    }

    uint32_t targetVendor = CGDisplayVendorNumber(displayID);
    uint32_t targetProduct = CGDisplayModelNumber(displayID);
    io_service_t serv;

    while ((serv = IOIteratorNext(iter)) != 0) {
        CFDictionaryRef info = (CFDictionaryRef)IORegistryEntryCreateCFProperty(serv, CFSTR(kIODisplayParametersKey), kCFAllocatorDefault, 0);
        if (!info) {
            IOObjectRelease(serv);
            continue;
        }

        CFDictionaryRef attrs = CFDictionaryGetValue(info, CFSTR("DisplayAttributes"));
        if (attrs) {
            CFDictionaryRef productAttrs = CFDictionaryGetValue(attrs, CFSTR("ProductAttributes"));
            if (productAttrs) {
                uint32_t vendor = 0, product = 0;
                CFNumberRef vRef = CFDictionaryGetValue(productAttrs, CFSTR("LegacyManufacturerID"));
                if (vRef) CFNumberGetValue(vRef, kCFNumberSInt32Type, &vendor);
                CFNumberRef pRef = CFDictionaryGetValue(productAttrs, CFSTR("ProductID"));
                if (pRef) CFNumberGetValue(pRef, kCFNumberSInt32Type, &product);

                if (vendor == targetVendor && product == targetProduct) {
                    CFDictionaryRef chroma = CFDictionaryGetValue(attrs, CFSTR("Chromaticity"));
                    CFDictionaryRef wp = CFDictionaryGetValue(attrs, CFSTR("DefaultWhitePoint"));
                    if (chroma && wp) {
                        CFDictionaryRef red = CFDictionaryGetValue(chroma, CFSTR("Red"));
                        CFDictionaryRef green = CFDictionaryGetValue(chroma, CFSTR("Green"));
                        CFDictionaryRef blue = CFDictionaryGetValue(chroma, CFSTR("Blue"));
                        if (red && green && blue) {
                            chrom.red.x = (float)cfDictGetFixed16(red, CFSTR("X"));
                            chrom.red.y = (float)cfDictGetFixed16(red, CFSTR("Y"));
                            chrom.green.x = (float)cfDictGetFixed16(green, CFSTR("X"));
                            chrom.green.y = (float)cfDictGetFixed16(green, CFSTR("Y"));
                            chrom.blue.x = (float)cfDictGetFixed16(blue, CFSTR("X"));
                            chrom.blue.y = (float)cfDictGetFixed16(blue, CFSTR("Y"));
                            chrom.white.x = (float)cfDictGetFixed16(wp, CFSTR("X"));
                            chrom.white.y = (float)cfDictGetFixed16(wp, CFSTR("Y"));
                            NSLog(@"[TallBar] Loaded native EDID chromaticities for display %u", displayID);
                            CFRelease(info);
                            IOObjectRelease(serv);
                            IOObjectRelease(iter);
                            return chrom;
                        }
                    }
                }
            }
        }
        CFRelease(info);
        IOObjectRelease(serv);
    }
    IOObjectRelease(iter);
    return chrom;
}

@implementation TallBarDisplayManager

+ (void)initialize {
    if (self == [TallBarDisplayManager class]) {
        _retainedWindows = [[NSMutableArray alloc] init];
        NSArray *notifications = @[
            NSWindowDidBecomeMainNotification,
            NSWindowDidBecomeKeyNotification,
            NSWindowDidUpdateNotification,
            NSWindowDidChangeScreenNotification
        ];
        for (NSNotificationName notifName in notifications) {
            [[NSNotificationCenter defaultCenter]
                addObserverForName:notifName
                object:nil
                queue:nil
                usingBlock:^(NSNotification *notification) {
                    retainWindowIfNeeded(notification.object);
                }];
        }
    }
}

+ (instancetype)sharedManager {
    static TallBarDisplayManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[TallBarDisplayManager alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isActive = NO;
        _virtualDisplayID = kCGNullDirectDisplay;
        _targetDisplayID = kCGNullDirectDisplay;
        _activeLogicalSize = CGSizeZero;
        _activeRefreshRate = 60.0;
        _savedSecondaryPositions = [[NSMutableArray alloc] init];
    }
    return self;
}

- (CGDirectDisplayID)findTargetDisplay {
    if (_targetDisplayID != kCGNullDirectDisplay) {
        return _targetDisplayID;
    }

    CGDirectDisplayID mainID = CGMainDisplayID();
    
    if (!VDMIsOurVirtualDisplay(mainID)) {
        return mainID;
    }

    CGDirectDisplayID displays[16];
    uint32_t count = 0;
    CGDirectDisplayID bestDisplay = kCGNullDirectDisplay;
    CGFloat bestWidth = 0;

    if (CGGetOnlineDisplayList(16, displays, &count) == kCGErrorSuccess) {
        for (uint32_t i = 0; i < count; i++) {
            CGDirectDisplayID d = displays[i];
            if (!VDMIsOurVirtualDisplay(d) && CGDisplayVendorNumber(d) != 0x756E6B6E) {
                CGRect bounds = CGDisplayBounds(d);
                if (bounds.size.width > bestWidth) {
                    bestWidth = bounds.size.width;
                    bestDisplay = d;
                }
            }
        }
    }

    return (bestDisplay != kCGNullDirectDisplay) ? bestDisplay : mainID;
}

- (void)enableTallBarWithCompletion:(void (^)(BOOL success))completion {
    if (_isActive) {
        NSLog(@"[TallBar] Already active");
        if (completion) completion(YES);
        return;
    }

    CGDirectDisplayID targetID = [self findTargetDisplay];
    if (targetID == kCGNullDirectDisplay) {
        NSLog(@"[TallBar] No valid display found");
        if (completion) completion(NO);
        return;
    }

    _targetDisplayID = targetID;
    NSLog(@"[TallBar] Target display ID: %u", targetID);

    // 1. Universally read the target monitor's current user desktop bounds
    CGRect targetBounds = CGDisplayBounds(targetID);
    uint32_t logicalW = (uint32_t)round(targetBounds.size.width);
    uint32_t logicalH = (uint32_t)round(targetBounds.size.height);

    if (logicalW == 0 || logicalH == 0) {
        logicalW = (uint32_t)CGDisplayPixelsWide(targetID);
        logicalH = (uint32_t)CGDisplayPixelsHigh(targetID);
    }

    // 2. Read target refresh rate
    CGDisplayModeRef curMode = CGDisplayCopyDisplayMode(targetID);
    double refreshRate = curMode ? CGDisplayModeGetRefreshRate(curMode) : 60.0;
    if (refreshRate <= 0.0) refreshRate = 60.0;
    if (curMode) CGDisplayModeRelease(curMode);

    _activeLogicalSize = CGSizeMake(logicalW, logicalH);
    _activeRefreshRate = refreshRate;
    NSLog(@"[TallBar] Target desktop: %ux%u @ %.1f Hz", logicalW, logicalH, refreshRate);

    // 3. Save multi-monitor arrangement: all other screens stay in exact relative position
    [_savedSecondaryPositions removeAllObjects];
    CGDirectDisplayID displays[32];
    uint32_t displayCount = 0;
    if (CGGetOnlineDisplayList(32, displays, &displayCount) == kCGErrorSuccess) {
        for (uint32_t i = 0; i < displayCount; i++) {
            CGDirectDisplayID d = displays[i];
            if (d == targetID || VDMIsOurVirtualDisplay(d)) continue;
            
            CGRect b = CGDisplayBounds(d);
            SecondaryDisplayPosition *pos = [[SecondaryDisplayPosition alloc] init];
            pos.displayID = d;
            pos.relX = (int32_t)(b.origin.x - targetBounds.origin.x);
            pos.relY = (int32_t)(b.origin.y - targetBounds.origin.y);
            [_savedSecondaryPositions addObject:pos];
            NSLog(@"[TallBar] Preserving secondary display %u at (%d, %d)", d, pos.relX, pos.relY);
        }
    }

    // 4. Pin the physical display to fixed rate mode to prevent VRR/adaptive sync glitch
    CGDisplayModeRef pinMode = CopyBestModeAtRate(targetID, refreshRate);
    if (pinMode) {
        CGDisplayConfigRef pinConfig;
        if (CGBeginDisplayConfiguration(&pinConfig) == kCGErrorSuccess) {
            CGConfigureDisplayWithDisplayMode(pinConfig, targetID, pinMode, NULL);
            CGCompleteDisplayConfiguration(pinConfig, kCGConfigureForSession);
        }
        CGDisplayModeRelease(pinMode);
    }

    // 5. SkyLight framework classes
    Class slvDispCls = NSClassFromString(@"SLVirtualDisplay");
    Class slvCfgCls = NSClassFromString(@"SLVirtualDisplayConfiguration");
    Class slvModeCls = NSClassFromString(@"SLVirtualDisplayMode");
    Class slvSettingsCls = NSClassFromString(@"SLVirtualDisplaySettings");

    if (!slvDispCls || !slvCfgCls || !slvModeCls || !slvSettingsCls) {
        NSLog(@"[TallBar] SLVirtualDisplay classes unavailable");
        if (completion) completion(NO);
        return;
    }

    // 6. Adaptive physical millimeter dimensions
    CGSize realSize = CGDisplayScreenSize(targetID);
    struct SLVSizeFloat sizeMm;
    if (realSize.width > 50.0f && realSize.height > 50.0f) {
        sizeMm.width = (float)realSize.width;
        sizeMm.height = (float)realSize.height;
    } else {
        float ppi = 110.0f;
        sizeMm.width = (float)logicalW / ppi * 25.4f;
        sizeMm.height = (float)logicalH / ppi * 25.4f;
    }

    // 7. Retina 2x backing store: matches user logical points with razor-sharp 2x backing buffer
    uint32_t backingW = logicalW * 2;
    uint32_t backingH = logicalH * 2;

    struct SLVSizeInt maxPx = { backingW, backingH };
    struct SLVChromaticities chrom = getAdaptiveChromaticities(targetID);

    NSError *err = nil;
    SLVirtualDisplayConfiguration *config = [[slvCfgCls alloc] initWithName:@"Color LCD"
                                                                vendorID:0x0610
                                                               productID:0x0F93
                                                            serialNumber:0x4871
                                                       sizeInMillimeters:sizeMm
                                                    maximumSizeInPixels:maxPx
                                                          chromaticities:chrom
                                                                   error:&err];
    if (!config) {
        NSLog(@"[TallBar] Config creation error: %@", err);
        if (completion) completion(NO);
        return;
    }

    // Subtype 1665 activates native MacBook Notch geometry in WindowServer (41-50 pt tall menu bar)
    config.subtype = 1665;
    _config = config;

    struct SLVSizeInt mPx = { backingW, backingH };
    struct SLVSizeInt mPtNative = { backingW, backingH };
    struct SLVSizeInt mPtHiDPI = { logicalW, logicalH };

    SLVirtualDisplayMode *nativeMode = [[slvModeCls alloc] initWithSizeInPixels:mPx
                                                                   sizeInPoints:mPtNative
                                                                    refreshRate:(float)refreshRate
                                                                          error:&err];
    SLVirtualDisplayMode *hidpiMode = [[slvModeCls alloc] initWithSizeInPixels:mPx
                                                                  sizeInPoints:mPtHiDPI
                                                                   refreshRate:(float)refreshRate
                                                                         error:&err];

    _mode = hidpiMode;
    _modesArray = @[nativeMode, hidpiMode];

    SLVirtualDisplaySettings *settings = [[slvSettingsCls alloc] initWithNativeMode:nativeMode
                                                              preferredMode:hidpiMode
                                                              optionalModes:_modesArray
                                                                  rotations:1
                                                                      error:&err];
    _settings = settings;

    SLVirtualDisplay *display = [[slvDispCls alloc] initWithConfiguration:config error:&err];
    if (!display) {
        NSLog(@"[TallBar] Display creation error: %@", err);
        [self cleanupObjects];
        if (completion) completion(NO);
        return;
    }
    _virtualDisplay = display;

    if (![display applySettings:settings error:&err]) {
        NSLog(@"[TallBar] Apply settings error: %@", err);
        [self cleanupObjects];
        if (completion) completion(NO);
        return;
    }

    _virtualDisplayID = display.displayID;
    NSLog(@"[TallBar] Created adaptive virtual display ID: %u", _virtualDisplayID);

    // 8. Wait 1.5 seconds for WindowServer registration, then mirror and position
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Step 1: Establish mirror
        CGDisplayConfigRef mirrorConfig;
        if (CGBeginDisplayConfiguration(&mirrorConfig) != kCGErrorSuccess) {
            NSLog(@"[TallBar] Begin mirror config failed");
            [self cleanupObjects];
            if (completion) completion(NO);
            return;
        }

        CGConfigureDisplayMirrorOfDisplay(mirrorConfig, self->_targetDisplayID, self->_virtualDisplayID);
        if (CGCompleteDisplayConfiguration(mirrorConfig, kCGConfigureForSession) != kCGErrorSuccess) {
            NSLog(@"[TallBar] Complete mirror config failed");
            [self cleanupObjects];
            if (completion) completion(NO);
            return;
        }

        NSLog(@"[TallBar] Mirror established");

        // Step 2: Position virtual display at (0, 0) and preserve all secondaries
        CGDisplayConfigRef arrangeConfig;
        if (CGBeginDisplayConfiguration(&arrangeConfig) == kCGErrorSuccess) {
            CGConfigureDisplayOrigin(arrangeConfig, self->_virtualDisplayID, 0, 0);

            for (SecondaryDisplayPosition *pos in self->_savedSecondaryPositions) {
                CGConfigureDisplayOrigin(arrangeConfig, pos.displayID, pos.relX, pos.relY);
            }

            CGCompleteDisplayConfiguration(arrangeConfig, kCGConfigureForSession);
        }

        self->_isActive = YES;
        NSLog(@"[TallBar] Tall menu bar successfully activated on %ux%u!", logicalW, logicalH);
        if (completion) completion(YES);
    });
}

- (void)disableTallBar {
    if (!_isActive && _virtualDisplayID == kCGNullDirectDisplay) {
        return;
    }

    NSLog(@"[TallBar] Restoring standard menu bar display...");

    if (_targetDisplayID != kCGNullDirectDisplay) {
        CGDisplayConfigRef configRef;
        if (CGBeginDisplayConfiguration(&configRef) == kCGErrorSuccess) {
            CGConfigureDisplayMirrorOfDisplay(configRef, _targetDisplayID, kCGNullDirectDisplay);
            CGConfigureDisplayOrigin(configRef, _targetDisplayID, 0, 0);

            for (SecondaryDisplayPosition *pos in _savedSecondaryPositions) {
                CGConfigureDisplayOrigin(configRef, pos.displayID, pos.relX, pos.relY);
            }

            CGCompleteDisplayConfiguration(configRef, kCGConfigureForSession);
        }
    }

    [self cleanupObjects];
    _isActive = NO;
    _virtualDisplayID = kCGNullDirectDisplay;
    _targetDisplayID = kCGNullDirectDisplay;
    _activeLogicalSize = CGSizeZero;
    NSLog(@"[TallBar] Standard display arrangement restored.");
}

- (void)cleanupObjects {
    _virtualDisplay = nil;
    _config = nil;
    _settings = nil;
    _mode = nil;
    _modesArray = nil;
}

@end
