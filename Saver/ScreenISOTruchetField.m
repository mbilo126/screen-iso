#import "ScreenISOTruchetField.h"

#import <math.h>

static const double kEpochLength = 20.0;
static const double kMinimumPause = 3.5;
enum { kMaxWaves = 3 };
static const NSInteger kFinalLayer = 99;

typedef struct {
    BOOL empty;
    NSInteger waveCount;
    BOOL radial;
    double directionX;
    double directionY;
    double originX;
    double originY;
    double minDistance;
    double crossTime;
    double speed;
    double duration;
    double lag;
    double start;
    double spin[kMaxWaves];
} EpochPlan;

static uint64_t SplitMix(uint64_t *state) {
    uint64_t z = (*state += 0x9E3779B97F4A7C15ULL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}

static uint64_t Mix(uint64_t value) {
    uint64_t state = value;
    return SplitMix(&state);
}

static double UnitRandom(uint64_t *state) {
    return (double)(SplitMix(state) >> 11) * (1.0 / 9007199254740992.0);
}

static double Clamp01(double value) {
    return value < 0.0 ? 0.0 : (value > 1.0 ? 1.0 : value);
}

static double EaseInOutCubic(double p) {
    return p < 0.5 ? 4.0 * p * p * p : 1.0 - pow(-2.0 * p + 2.0, 3.0) / 2.0;
}

@implementation ScreenISOTruchetField

- (instancetype)initWithColumns:(NSInteger)columns rows:(NSInteger)rows seed:(uint64_t)seed {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _columns = MAX(columns, 1);
    _rows = MAX(rows, 1);
    _seed = seed;
    return self;
}

- (NSUInteger)patternBitForEpoch:(int64_t)epoch layer:(NSInteger)layer tile:(NSInteger)tile {
    uint64_t value = Mix(self.seed ^ Mix((uint64_t)epoch ^ 0x5851F42D4C957F2DULL));
    value = Mix(value ^ (uint64_t)layer);
    value = Mix(value ^ (uint64_t)tile);
    return (NSUInteger)(value & 1ULL);
}

- (EpochPlan)planForEpoch:(int64_t)epoch {
    EpochPlan plan = {0};
    if (epoch < 0) {
        plan.empty = YES;
        return plan;
    }
    uint64_t state = Mix(self.seed ^ ((uint64_t)epoch * 0xD1B54A32D192ED03ULL));
    double width = (double)self.columns;
    double height = (double)self.rows;

    plan.empty = epoch > 0 && UnitRandom(&state) < 0.2;
    plan.radial = UnitRandom(&state) < 0.25;

    double minDistance = 0.0;
    double maxDistance = 0.0;
    double cornersX[4] = {0.0, width, 0.0, width};
    double cornersY[4] = {0.0, 0.0, height, height};
    if (plan.radial) {
        plan.originX = (-0.15 + 1.3 * UnitRandom(&state)) * width;
        plan.originY = (-0.15 + 1.3 * UnitRandom(&state)) * height;
        double nearestX = fmin(fmax(plan.originX, 0.0), width);
        double nearestY = fmin(fmax(plan.originY, 0.0), height);
        minDistance = hypot(plan.originX - nearestX, plan.originY - nearestY);
        for (int i = 0; i < 4; i++) {
            maxDistance = fmax(maxDistance, hypot(cornersX[i] - plan.originX, cornersY[i] - plan.originY));
        }
    } else {
        double angle = floor(UnitRandom(&state) * 8.0) * M_PI_4;
        plan.directionX = cos(angle);
        plan.directionY = sin(angle);
        minDistance = INFINITY;
        maxDistance = -INFINITY;
        for (int i = 0; i < 4; i++) {
            double projection = cornersX[i] * plan.directionX + cornersY[i] * plan.directionY;
            minDistance = fmin(minDistance, projection);
            maxDistance = fmax(maxDistance, projection);
        }
    }
    plan.minDistance = minDistance;
    plan.crossTime = 5.0 + 3.0 * UnitRandom(&state);
    plan.speed = fmax(maxDistance - minDistance, 1.0) / plan.crossTime;
    plan.duration = 1.8 + 0.8 * UnitRandom(&state);
    plan.lag = plan.duration + 0.6 + 1.8 * UnitRandom(&state);

    double countRoll = UnitRandom(&state);
    plan.waveCount = countRoll < 0.5 ? 1 : (countRoll < 0.85 ? 2 : 3);
    double budget = kEpochLength - kMinimumPause;
    double activity = 0.0;
    do {
        activity = (double)(plan.waveCount - 1) * plan.lag + plan.crossTime + plan.duration;
        if (activity <= budget || plan.waveCount == 1) {
            break;
        }
        plan.waveCount -= 1;
    } while (YES);

    double slack = fmax(budget - activity, 0.0);
    double startRoll = UnitRandom(&state);
    plan.start = epoch == 0 ? fmin(1.0 + 1.5 * startRoll, slack) : slack * startRoll;
    for (NSInteger w = 0; w < kMaxWaves; w++) {
        plan.spin[w] = UnitRandom(&state) < 0.5 ? 1.0 : -1.0;
    }
    return plan;
}

- (int64_t)lastWavingEpochAtOrBefore:(int64_t)epoch {
    int64_t current = epoch;
    while (current >= 0 && [self planForEpoch:current].empty) {
        current -= 1;
    }
    return current;
}

- (double)distanceForPlan:(const EpochPlan *)plan x:(double)x y:(double)y {
    if (plan->radial) {
        return hypot(x - plan->originX, y - plan->originY) - plan->minDistance;
    }
    return x * plan->directionX + y * plan->directionY - plan->minDistance;
}

- (BOOL)evaluateAtTime:(NSTimeInterval)time states:(ScreenISOTileState *)states {
    int64_t epoch = (int64_t)floor(time / kEpochLength);
    double local = time - (double)epoch * kEpochLength;
    EpochPlan plan = [self planForEpoch:epoch];
    int64_t previous = [self lastWavingEpochAtOrBefore:epoch - 1];

    for (NSInteger row = 0; row < self.rows; row++) {
        for (NSInteger column = 0; column < self.columns; column++) {
            NSInteger tile = row * self.columns + column;
            NSUInteger bit = [self patternBitForEpoch:previous layer:kFinalLayer tile:tile];
            double angle = (double)bit * M_PI_2;
            double glow = 0.0;
            double dip = 0.0;

            if (!plan.empty) {
                double offset = [self distanceForPlan:&plan x:(double)column + 0.5 y:(double)row + 0.5] / plan.speed;
                NSUInteger current = bit;
                for (NSInteger w = 0; w < plan.waveCount; w++) {
                    NSInteger layer = (w == plan.waveCount - 1) ? kFinalLayer : w + 1;
                    NSUInteger target = [self patternBitForEpoch:epoch layer:layer tile:tile];
                    double turns = target != current ? 1.0 : 2.0;
                    current = target;
                    double arrival = plan.start + (double)w * plan.lag + offset;
                    double progress = Clamp01((local - arrival) / plan.duration);
                    if (progress <= 0.0) {
                        continue;
                    }
                    angle += plan.spin[w] * turns * M_PI_2 * EaseInOutCubic(progress);
                    double hump = sin(M_PI * progress);
                    glow = fmax(glow, fmin(1.0, 1.7 * hump));
                    dip = fmax(dip, hump);
                }
            }

            angle = fmod(angle, M_PI);
            if (angle < 0.0) {
                angle += M_PI;
            }
            states[tile].angle = angle;
            states[tile].glow = glow;
            states[tile].scale = 1.0 - 0.14 * dip;
        }
    }
    return [self activeWaveCountForPlan:&plan local:local] > 0;
}

- (NSInteger)activeWaveCountForPlan:(const EpochPlan *)plan local:(double)local {
    if (plan->empty) {
        return 0;
    }
    NSInteger count = 0;
    for (NSInteger w = 0; w < plan->waveCount; w++) {
        double start = plan->start + (double)w * plan->lag;
        if (local >= start && local <= start + plan->crossTime + plan->duration) {
            count += 1;
        }
    }
    return count;
}

- (NSInteger)activeWaveCountAtTime:(NSTimeInterval)time {
    int64_t epoch = (int64_t)floor(time / kEpochLength);
    EpochPlan plan = [self planForEpoch:epoch];
    return [self activeWaveCountForPlan:&plan local:time - (double)epoch * kEpochLength];
}

- (NSArray<NSNumber *> *)waveFrontFractionsAtTime:(NSTimeInterval)time {
    int64_t epoch = (int64_t)floor(time / kEpochLength);
    double local = time - (double)epoch * kEpochLength;
    EpochPlan plan = [self planForEpoch:epoch];
    NSMutableArray<NSNumber *> *fractions = [NSMutableArray array];
    if (plan.empty) {
        return fractions;
    }
    for (NSInteger w = 0; w < plan.waveCount; w++) {
        double start = plan.start + (double)w * plan.lag;
        if (local >= start && local <= start + plan.crossTime + plan.duration) {
            [fractions addObject:@((local - start) / plan.crossTime)];
        }
    }
    return fractions;
}

- (NSTimeInterval)nextWaveStartAfter:(NSTimeInterval)time {
    int64_t epoch = (int64_t)floor(fmax(time, 0.0) / kEpochLength);
    for (int64_t j = epoch; j < epoch + 1000; j++) {
        EpochPlan plan = [self planForEpoch:j];
        if (plan.empty) {
            continue;
        }
        for (NSInteger w = 0; w < plan.waveCount; w++) {
            double start = (double)j * kEpochLength + plan.start + (double)w * plan.lag;
            if (start > time) {
                return start;
            }
        }
    }
    return -1.0;
}

@end
