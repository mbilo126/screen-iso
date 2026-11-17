#import <ScreenSaver/ScreenSaver.h>

NS_ASSUME_NONNULL_BEGIN

@interface ScreenISOSaverView : ScreenSaverView

@property(nonatomic, readonly) NSRect textBlockFrame;
@property(nonatomic, readonly) CGFloat tileSize;
@property(nonatomic, readonly) NSPoint gridOrigin;
@property(nonatomic, readonly) NSInteger gridColumns;
@property(nonatomic, readonly) NSInteger gridRows;
@property(nonatomic) uint64_t animationSeed;

- (void)relocateTextBlock;

// Applies the deterministic animation state for `time` seconds since the field origin.
- (void)applyAnimationStateAtTime:(NSTimeInterval)time;
- (NSInteger)activeWaveCountAtTime:(NSTimeInterval)time;
- (NSArray<NSNumber *> *)waveFrontFractionsAtTime:(NSTimeInterval)time;
- (NSTimeInterval)nextWaveStartAfter:(NSTimeInterval)time;

@end

NS_ASSUME_NONNULL_END
