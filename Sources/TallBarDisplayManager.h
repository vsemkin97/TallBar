//
//  TallBarDisplayManager.h
//  TallBar - Universal Adaptive Tall Menu Bar for macOS
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface TallBarDisplayManager : NSObject

+ (instancetype)sharedManager;

@property (nonatomic, readonly) BOOL isActive;
@property (nonatomic, readonly) CGDirectDisplayID virtualDisplayID;
@property (nonatomic, readonly) CGDirectDisplayID targetDisplayID;
@property (nonatomic, readonly) CGSize activeLogicalSize;
@property (nonatomic, readonly) double activeRefreshRate;

/// Enables the tall menu bar adaptively on the current main display
- (void)enableTallBarWithCompletion:(nullable void (^)(BOOL success))completion;

/// Disables the tall menu bar and cleanly restores the physical display arrangement
- (void)disableTallBar;

/// Finds the most suitable display (the active main display where the menu bar resides)
- (CGDirectDisplayID)findTargetDisplay;

@end

NS_ASSUME_NONNULL_END
