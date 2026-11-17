#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    double angle;
    double glow;
    double scale;
} ScreenISOTileState;

// Deterministic Truchet wave field: the state of every tile is a pure function of
// (columns, rows, seed, time). Time is split into fixed epochs; each epoch holds either
// a pause or a group of one to three waves that all finish before the epoch ends.
@interface ScreenISOTruchetField : NSObject

@property(nonatomic, readonly) NSInteger columns;
@property(nonatomic, readonly) NSInteger rows;
@property(nonatomic, readonly) uint64_t seed;

- (instancetype)initWithColumns:(NSInteger)columns rows:(NSInteger)rows seed:(uint64_t)seed NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Fills `states` (columns * rows entries, row-major from the bottom-left tile).
// Returns YES when at least one wave is in flight at `time`.
- (BOOL)evaluateAtTime:(NSTimeInterval)time states:(ScreenISOTileState *)states;

- (NSInteger)activeWaveCountAtTime:(NSTimeInterval)time;
- (NSArray<NSNumber *> *)waveFrontFractionsAtTime:(NSTimeInterval)time;
- (NSTimeInterval)nextWaveStartAfter:(NSTimeInterval)time;

@end

NS_ASSUME_NONNULL_END
