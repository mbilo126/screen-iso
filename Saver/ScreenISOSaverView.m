#import "ScreenISOSaverView.h"

#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <os/log.h>
#import <stdlib.h>

#import "ScreenISOTruchetField.h"

static NSString *const kTitleText = @"Claude is working in the background";
static const NSInteger kTitleDotCount = 3;
static const NSTimeInterval kTitleDotStepInterval = 0.5;
static NSString *const kMessageText = @"Questo computer è in uso. Sblocco con password o Touch ID.";

static NSString *const kWillStopNotification = @"com.apple.screensaver.willstop";
static NSString *const kDidStartNotification = @"com.apple.screensaver.didstart";
static NSString *const kDidStopNotification = @"com.apple.screensaver.didstop";

static const NSTimeInterval kFrameInterval = 1.0 / 30.0;
static const NSTimeInterval kClockCheckInterval = 1.0;
static const NSTimeInterval kRelocationInterval = 20.0;

static const CGFloat kColumnsOnLongSide = 17.0;
static const CGFloat kPreviewColumnsOnLongSide = 8.0;

// The legacyScreenSaver host reports isPreview unreliably (always YES before macOS 26,
// sometimes NO for the Settings thumbnail on macOS 26), so preview is inferred from size.
static const CGFloat kPreviewMaxWidth = 400.0;
static const CGFloat kPreviewMaxHeight = 300.0;

static NSInteger gLiveInstances = 0;

static os_log_t ScreenISOLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("it.yellowtech.screeniso.saver", "lifecycle");
    });
    return log;
}

static BOOL IsPreviewSized(NSSize size) {
    return size.width < kPreviewMaxWidth || size.height < kPreviewMaxHeight;
}

static NSInteger VisibleTitleDotsAtTime(NSTimeInterval time) {
    NSInteger step = (NSInteger)floor(MAX(time, 0.0) / kTitleDotStepInterval);
    return step % kTitleDotCount + 1;
}

static CGFloat RandomUnit(void) {
    return (CGFloat)arc4random_uniform(10001) / 10000.0;
}

static NSColor *BackgroundColor(void) {
    return [NSColor colorWithSRGBRed:10.0 / 255.0 green:10.0 / 255.0 blue:12.0 / 255.0 alpha:1.0];
}

static NSColor *IvoryColor(void) {
    return [NSColor colorWithSRGBRed:242.0 / 255.0 green:239.0 / 255.0 blue:230.0 / 255.0 alpha:1.0];
}

static NSColor *CoralColor(void) {
    return [NSColor colorWithSRGBRed:242.0 / 255.0 green:84.0 / 255.0 blue:45.0 / 255.0 alpha:1.0];
}

static id CreateImage(NSSize size, CGFloat scale, void (^draw)(void)) {
    size_t width = (size_t)ceil(size.width * scale);
    size_t height = (size_t)ceil(size.height * scale);
    if (width == 0 || height == 0) {
        return nil;
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, colorSpace,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) {
        return nil;
    }
    CGContextScaleCTM(context, scale, scale);
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:context flipped:NO]];
    draw();
    [NSGraphicsContext restoreGraphicsState];
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return CFBridgingRelease(image);
}

static id CreateTileImage(CGFloat side, CGFloat scale, NSColor *color) {
    CGFloat lineWidth = MAX(round(side / 5.0 * scale), 1.0) / scale;
    return CreateImage(NSMakeSize(side, side), scale, ^{
        [color setStroke];
        NSBezierPath *lower = [NSBezierPath bezierPath];
        [lower appendBezierPathWithArcWithCenter:NSMakePoint(0.0, 0.0) radius:side / 2.0 startAngle:0.0 endAngle:90.0];
        NSBezierPath *upper = [NSBezierPath bezierPath];
        [upper appendBezierPathWithArcWithCenter:NSMakePoint(side, side)
                                          radius:side / 2.0
                                      startAngle:180.0
                                        endAngle:270.0];
        for (NSBezierPath *path in @[ lower, upper ]) {
            path.lineWidth = lineWidth;
            path.lineCapStyle = NSLineCapStyleButt;
            [path stroke];
        }
    });
}

static CGAffineTransform TileTransform(ScreenISOTileState state) {
    if (state.glow <= 0.0 && state.scale >= 1.0) {
        // Exact matrices at rest keep tile edges pixel-aligned, so neighbouring arcs join seamlessly.
        BOOL quarterTurn = (lround(state.angle / M_PI_2) % 2) == 1;
        return quarterTurn ? CGAffineTransformMake(0.0, 1.0, -1.0, 0.0, 0.0, 0.0) : CGAffineTransformIdentity;
    }
    return CGAffineTransformScale(CGAffineTransformMakeRotation(state.angle), state.scale, state.scale);
}

@interface ScreenISOPanelLayout : NSObject
@property(nonatomic) NSRect frame;
@property(nonatomic) CGFloat cornerRadius;
@property(nonatomic, copy) NSArray<NSAttributedString *> *lines;
@property(nonatomic, copy) NSArray<NSValue *> *lineFrames;
@end

@implementation ScreenISOPanelLayout
@end

@interface ScreenISOSaverView ()
@property(nonatomic, strong, nullable) NSTimer *redrawTimer;
@property(nonatomic, strong) NSDateFormatter *timeFormatter;
@property(nonatomic) CGFloat horizontalFraction;
@property(nonatomic) CGFloat verticalFraction;
@property(nonatomic, strong) NSDate *lastRelocation;
@property(nonatomic, strong) NSMutableArray<id<NSObject>> *distributedObservers;
@property(nonatomic) BOOL redrawLoopActive;

@property(nonatomic, strong, nullable) ScreenISOTruchetField *field;
@property(nonatomic, strong, nullable) CALayer *tilesLayer;
@property(nonatomic, strong, nullable) CALayer *panelLayer;
@property(nonatomic, copy) NSArray<CALayer *> *tileLayers;
@property(nonatomic, copy) NSArray<CALayer *> *glowLayers;
@property(nonatomic, strong) NSMutableData *appliedStates;
@property(nonatomic, strong) NSMutableData *scratchStates;
@property(nonatomic) BOOL hasAppliedStates;
@property(nonatomic, readwrite) CGFloat tileSize;
@property(nonatomic, readwrite) NSPoint gridOrigin;
@property(nonatomic, readwrite) NSInteger gridColumns;
@property(nonatomic, readwrite) NSInteger gridRows;
@property(nonatomic) NSSize builtSize;
@property(nonatomic) CGFloat builtScale;
@property(nonatomic) CFTimeInterval timeOrigin;
@property(nonatomic, copy, nullable) NSString *panelClockString;
@property(nonatomic) NSInteger panelVisibleDots;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, id> *panelImages;
@property(nonatomic) CFTimeInterval lastClockCheck;
@property(nonatomic) BOOL panelNeedsLayout;
@property(nonatomic) BOOL sceneReady;
@property(nonatomic) BOOL sceneSuspended;
@property(nonatomic, strong, nullable) NSDate *clockDate;
@end

@implementation ScreenISOSaverView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self == nil) {
        return nil;
    }

    self.animationTimeInterval = 1.0;
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    self.layer.backgroundColor = BackgroundColor().CGColor;

    _timeFormatter = [[NSDateFormatter alloc] init];
    _timeFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"it_IT"];
    _timeFormatter.timeZone = [NSTimeZone localTimeZone];
    _timeFormatter.dateFormat = @"HH:mm";

    _tileLayers = @[];
    _glowLayers = @[];
    _appliedStates = [NSMutableData data];
    _scratchStates = [NSMutableData data];
    _panelImages = [NSMutableDictionary dictionary];
    _animationSeed =((uint64_t)arc4random() << 32) | (uint64_t)arc4random();
    _timeOrigin = CACurrentMediaTime();

    _distributedObservers = [NSMutableArray array];
    [self registerDistributedObservers];
    [self relocateTextBlock];
    _sceneReady = YES;
    [self rebuildScene];

    gLiveInstances += 1;
    os_log_info(ScreenISOLog(),
                "saver_init width=%.0f height=%.0f is_preview=%d host=%{public}@ live_instances=%ld",
                frame.size.width, frame.size.height, isPreview, [NSProcessInfo processInfo].processName,
                (long)gLiveInstances);
    return self;
}

- (void)dealloc {
    [_redrawTimer invalidate];
    NSDistributedNotificationCenter *center = [NSDistributedNotificationCenter defaultCenter];
    for (id<NSObject> observer in _distributedObservers) {
        [center removeObserver:observer];
    }
    gLiveInstances -= 1;
    os_log_info(ScreenISOLog(), "saver_dealloc live_instances=%ld", (long)gLiveInstances);
}

- (BOOL)isOpaque {
    return YES;
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)updateLayer {
    self.layer.backgroundColor = BackgroundColor().CGColor;
}

- (void)drawRect:(NSRect)dirtyRect {
    [BackgroundColor() setFill];
    NSRectFill(dirtyRect);
}

- (BOOL)hasConfigureSheet {
    return NO;
}

- (nullable NSWindow *)configureSheet {
    return nil;
}

#pragma mark - Animation lifecycle

- (void)startAnimation {
    if (self.redrawLoopActive) {
        return;
    }
    if (self.sceneSuspended) {
        self.sceneSuspended = NO;
        [self rebuildScene];
    }
    [super startAnimation];
    self.redrawLoopActive = YES;
    [self startRedrawTimer];

    NSWindow *window = self.window;
    NSSize screenSize = window.screen.frame.size;
    os_log_info(ScreenISOLog(),
                "saver_start_animation has_window=%d window_visible=%d occlusion_visible=%d "
                "screen_width=%.0f screen_height=%.0f live_instances=%ld",
                window != nil, window.isVisible, (window.occlusionState & NSWindowOcclusionStateVisible) != 0,
                screenSize.width, screenSize.height, (long)gLiveInstances);
}

- (void)stopAnimation {
    [self stopRedrawTimer];
    if (!self.redrawLoopActive) {
        return;
    }
    self.redrawLoopActive = NO;
    [super stopAnimation];
    os_log_info(ScreenISOLog(), "saver_stop_animation");
}

- (void)animateOneFrame {
    // Frames are driven by redrawTimer: the host's animateOneFrame cadence is not reliable.
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window == nil) {
        [self stopRedrawTimer];
    } else if (self.redrawLoopActive && self.redrawTimer == nil) {
        [self startRedrawTimer];
    }
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    if (self.sceneReady && [self renderScale] != self.builtScale) {
        [self rebuildScene];
    }
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    if (self.sceneReady && !NSEqualSizes(newSize, self.builtSize)) {
        [self rebuildScene];
    }
}

- (void)startRedrawTimer {
    [self.redrawTimer invalidate];
    __weak typeof(self) weakSelf = self;
    NSTimer *timer = [NSTimer timerWithTimeInterval:kFrameInterval
                                            repeats:YES
                                              block:^(NSTimer *firedTimer) {
                                                  ScreenISOSaverView *strongSelf = weakSelf;
                                                  if (strongSelf == nil) {
                                                      [firedTimer invalidate];
                                                      return;
                                                  }
                                                  [strongSelf tick];
                                              }];
    timer.tolerance = 0.004;
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.redrawTimer = timer;
}

- (void)stopRedrawTimer {
    [self.redrawTimer invalidate];
    self.redrawTimer = nil;
}

- (void)tick {
    if (-[self.lastRelocation timeIntervalSinceNow] >= kRelocationInterval) {
        [self relocateTextBlock];
    }
    [self applyAnimationStateAtTime:CACurrentMediaTime() - self.timeOrigin];
}

#pragma mark - Host workarounds

- (void)registerDistributedObservers {
    NSDistributedNotificationCenter *center = [NSDistributedNotificationCenter defaultCenter];
    __weak typeof(self) weakSelf = self;

    id<NSObject> willStop = [center addObserverForName:kWillStopNotification
                                                object:nil
                                                 queue:[NSOperationQueue mainQueue]
                                            usingBlock:^(NSNotification *note) {
                                                [weakSelf screenSaverWillStop:note];
                                            }];
    id<NSObject> didStart = [center addObserverForName:kDidStartNotification
                                                object:nil
                                                 queue:[NSOperationQueue mainQueue]
                                            usingBlock:^(__unused NSNotification *note) {
                                                os_log_info(ScreenISOLog(), "saver_did_start_received animating=%d",
                                                            weakSelf.redrawLoopActive);
                                            }];
    id<NSObject> didStop = [center addObserverForName:kDidStopNotification
                                               object:nil
                                                queue:[NSOperationQueue mainQueue]
                                           usingBlock:^(__unused NSNotification *note) {
                                               os_log_info(ScreenISOLog(), "saver_did_stop_received animating=%d",
                                                           weakSelf.redrawLoopActive);
                                           }];
    [self.distributedObservers addObject:willStop];
    [self.distributedObservers addObject:didStart];
    [self.distributedObservers addObject:didStop];
}

// Since macOS 14 the host often skips stopAnimation and never releases the view, so an
// instance outlives its screen. Exiting the process does not help on macOS 26: the host is
// relaunched within a second and starts a fresh offscreen instance. Instead every instance
// drops its tiles here and rebuilds them on the next startAnimation, so leftovers stay cheap.
- (void)screenSaverWillStop:(nullable NSNotification *)note {
    os_log_info(ScreenISOLog(), "saver_will_stop_received animating=%d live_instances=%ld",
                self.redrawLoopActive, (long)gLiveInstances);
    [self stopAnimation];
    [self releaseScene];
}

- (void)releaseScene {
    self.sceneSuspended = YES;
    [self rebuildScene];
    os_log_info(ScreenISOLog(), "saver_scene_released");
}

#pragma mark - Truchet field

- (CGFloat)renderScale {
    CGFloat scale = self.window.backingScaleFactor;
    if (scale <= 0.0) {
        scale = [NSScreen mainScreen].backingScaleFactor;
    }
    return scale > 0.0 ? scale : 2.0;
}

- (void)setAnimationSeed:(uint64_t)animationSeed {
    _animationSeed = animationSeed;
    if (self.field != nil) {
        self.field = [[ScreenISOTruchetField alloc] initWithColumns:self.gridColumns
                                                               rows:self.gridRows
                                                               seed:animationSeed];
        self.hasAppliedStates = NO;
    }
}

- (void)rebuildScene {
    NSSize size = self.bounds.size;
    CGFloat scale = [self renderScale];
    self.builtSize = size;
    self.builtScale = scale;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self.tilesLayer removeFromSuperlayer];
    [self.panelLayer removeFromSuperlayer];
    self.tilesLayer = nil;
    self.panelLayer = nil;
    self.tileLayers = @[];
    self.glowLayers = @[];
    self.field = nil;
    self.hasAppliedStates = NO;
    [self.panelImages removeAllObjects];
    self.panelVisibleDots = 0;

    CALayer *root = self.layer;
    if (self.sceneSuspended || root == nil || size.width < 1.0 || size.height < 1.0) {
        self.appliedStates = [NSMutableData data];
        self.scratchStates = [NSMutableData data];
        [CATransaction commit];
        return;
    }
    root.backgroundColor = BackgroundColor().CGColor;

    CGFloat columnsOnLongSide = IsPreviewSized(size) ? kPreviewColumnsOnLongSide : kColumnsOnLongSide;
    CGFloat side = MAX(floor(MAX(size.width, size.height) / columnsOnLongSide), 4.0);
    NSInteger columns = (NSInteger)ceil(size.width / side);
    NSInteger rows = (NSInteger)ceil(size.height / side);
    NSPoint origin = NSMakePoint(floor((size.width - (CGFloat)columns * side) / 2.0),
                                 floor((size.height - (CGFloat)rows * side) / 2.0));
    self.tileSize = side;
    self.gridColumns = columns;
    self.gridRows = rows;
    self.gridOrigin = origin;

    id ivory = CreateTileImage(side, scale, IvoryColor());
    id coral = CreateTileImage(side, scale, CoralColor());

    CALayer *tiles = [CALayer layer];
    tiles.frame = NSMakeRect(0.0, 0.0, size.width, size.height);
    NSMutableArray<CALayer *> *tileLayers = [NSMutableArray arrayWithCapacity:(NSUInteger)(columns * rows)];
    NSMutableArray<CALayer *> *glowLayers = [NSMutableArray arrayWithCapacity:(NSUInteger)(columns * rows)];
    for (NSInteger row = 0; row < rows; row++) {
        for (NSInteger column = 0; column < columns; column++) {
            CALayer *tile = [CALayer layer];
            tile.bounds = CGRectMake(0.0, 0.0, side, side);
            tile.position = CGPointMake(origin.x + ((CGFloat)column + 0.5) * side,
                                        origin.y + ((CGFloat)row + 0.5) * side);
            tile.contents = ivory;
            tile.contentsScale = scale;

            CALayer *glow = [CALayer layer];
            glow.frame = tile.bounds;
            glow.contents = coral;
            glow.contentsScale = scale;
            glow.opacity = 0.0f;
            glow.hidden = YES;
            [tile addSublayer:glow];

            [tiles addSublayer:tile];
            [tileLayers addObject:tile];
            [glowLayers addObject:glow];
        }
    }

    CALayer *panel = [CALayer layer];
    panel.backgroundColor = BackgroundColor().CGColor;
    panel.borderColor = [IvoryColor() colorWithAlphaComponent:0.14].CGColor;
    panel.borderWidth = 1.0;
    panel.contentsScale = scale;
    panel.masksToBounds = YES;

    [root addSublayer:tiles];
    [root addSublayer:panel];
    self.tilesLayer = tiles;
    self.panelLayer = panel;
    self.tileLayers = tileLayers;
    self.glowLayers = glowLayers;

    NSUInteger byteCount = (NSUInteger)(columns * rows) * sizeof(ScreenISOTileState);
    self.appliedStates = [NSMutableData dataWithLength:byteCount];
    self.scratchStates = [NSMutableData dataWithLength:byteCount];
    self.field = [[ScreenISOTruchetField alloc] initWithColumns:columns rows:rows seed:self.animationSeed];
    self.panelClockString = nil;
    self.panelNeedsLayout = YES;
    [CATransaction commit];

    [self applyAnimationStateAtTime:CACurrentMediaTime() - self.timeOrigin];
}

- (void)applyAnimationStateAtTime:(NSTimeInterval)time {
    ScreenISOTruchetField *field = self.field;
    if (field == nil) {
        return;
    }
    ScreenISOTileState *states = self.scratchStates.mutableBytes;
    ScreenISOTileState *applied = self.appliedStates.mutableBytes;
    [field evaluateAtTime:time states:states];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    NSUInteger count = self.tileLayers.count;
    for (NSUInteger index = 0; index < count; index++) {
        ScreenISOTileState state = states[index];
        ScreenISOTileState previous = applied[index];
        if (self.hasAppliedStates && fabs(state.angle - previous.angle) < 1e-4 &&
            fabs(state.glow - previous.glow) < 2e-3 && fabs(state.scale - previous.scale) < 1e-4) {
            continue;
        }
        self.tileLayers[index].affineTransform = TileTransform(state);
        CALayer *glow = self.glowLayers[index];
        glow.opacity = (float)state.glow;
        glow.hidden = state.glow <= 0.0;
        applied[index] = state;
    }
    self.hasAppliedStates = YES;
    [self updatePanelAtTime:time];
    [CATransaction commit];
}

- (NSInteger)activeWaveCountAtTime:(NSTimeInterval)time {
    return [self.field activeWaveCountAtTime:time];
}

- (NSArray<NSNumber *> *)waveFrontFractionsAtTime:(NSTimeInterval)time {
    return self.field != nil ? [self.field waveFrontFractionsAtTime:time] : @[];
}

- (NSTimeInterval)nextWaveStartAfter:(NSTimeInterval)time {
    return self.field != nil ? [self.field nextWaveStartAfter:time] : -1.0;
}

#pragma mark - Text panel

- (void)relocateTextBlock {
    self.horizontalFraction = RandomUnit();
    self.verticalFraction = RandomUnit();
    self.lastRelocation = [NSDate date];
}

- (void)setHorizontalFraction:(CGFloat)horizontalFraction {
    _horizontalFraction = horizontalFraction;
    self.panelNeedsLayout = YES;
}

- (void)setVerticalFraction:(CGFloat)verticalFraction {
    _verticalFraction = verticalFraction;
    self.panelNeedsLayout = YES;
}

- (NSRect)textBlockFrame {
    NSString *clock = [self.timeFormatter stringFromDate:self.clockDate ?: [NSDate date]];
    return [self panelLayoutForBounds:self.bounds clock:clock visibleDots:kTitleDotCount].frame;
}

- (void)updatePanelAtTime:(NSTimeInterval)time {
    CALayer *panel = self.panelLayer;
    if (panel == nil) {
        return;
    }
    NSInteger visibleDots = VisibleTitleDotsAtTime(time);
    BOOL dotsChanged = visibleDots != self.panelVisibleDots;
    CFTimeInterval now = CACurrentMediaTime();
    if (!self.panelNeedsLayout && !dotsChanged && now - self.lastClockCheck < kClockCheckInterval) {
        return;
    }
    self.lastClockCheck = now;
    NSString *clock = [self.timeFormatter stringFromDate:self.clockDate ?: [NSDate date]];
    BOOL clockChanged = ![clock isEqualToString:self.panelClockString];
    if (!clockChanged && !dotsChanged && !self.panelNeedsLayout) {
        return;
    }

    ScreenISOPanelLayout *layout = [self panelLayoutForBounds:self.bounds clock:clock visibleDots:visibleDots];
    if (clockChanged || !NSEqualSizes(panel.bounds.size, layout.frame.size)) {
        [self.panelImages removeAllObjects];
    }
    // The dots cycle twice a second: each phase is drawn once and reused until the clock or the size changes.
    NSNumber *phase = @(visibleDots);
    id image = self.panelImages[phase];
    if (image == nil) {
        NSArray<NSAttributedString *> *lines = layout.lines;
        NSArray<NSValue *> *frames = layout.lineFrames;
        image = CreateImage(layout.frame.size, self.builtScale, ^{
            for (NSUInteger index = 0; index < lines.count; index++) {
                [lines[index] drawInRect:frames[index].rectValue];
            }
        });
        if (image != nil) {
            self.panelImages[phase] = image;
        }
    }
    panel.contents = image;
    panel.cornerRadius = layout.cornerRadius;
    panel.frame = layout.frame;
    self.panelClockString = clock;
    self.panelVisibleDots = visibleDots;
    self.panelNeedsLayout = NO;
}

- (ScreenISOPanelLayout *)panelLayoutForBounds:(NSRect)bounds
                                         clock:(NSString *)clock
                                   visibleDots:(NSInteger)visibleDots {
    CGFloat width = NSWidth(bounds);
    CGFloat height = NSHeight(bounds);
    CGFloat margin = floor(MIN(width, height) * 0.05);
    CGFloat availableWidth = MAX(width - 2.0 * margin, 1.0);
    CGFloat availableHeight = MAX(height - 2.0 * margin, 1.0);

    CGFloat baseSize = MIN(width * 0.026, height * 0.04);
    if (IsPreviewSized(bounds.size)) {
        baseSize *= 1.6;
    }
    baseSize = MAX(baseSize, 1.0);

    NSArray<NSAttributedString *> *lines = [self linesWithBaseSize:baseSize clock:clock visibleDots:visibleDots];
    NSSize panelSize = [self panelSizeForLines:lines baseSize:baseSize];
    CGFloat fit = MIN(availableWidth / panelSize.width, availableHeight / panelSize.height);
    if (fit < 1.0) {
        baseSize = floor(baseSize * fit * 10.0) / 10.0;
        lines = [self linesWithBaseSize:baseSize clock:clock visibleDots:visibleDots];
        panelSize = [self panelSizeForLines:lines baseSize:baseSize];
    }
    panelSize = NSMakeSize(ceil(panelSize.width), ceil(panelSize.height));

    CGFloat originX = margin + floor(MAX(availableWidth - panelSize.width, 0.0) * self.horizontalFraction);
    CGFloat originY = margin + floor(MAX(availableHeight - panelSize.height, 0.0) * self.verticalFraction);

    NSMutableArray<NSValue *> *frames = [NSMutableArray arrayWithCapacity:lines.count];
    CGFloat cursorY = panelSize.height - [self verticalPaddingForBaseSize:baseSize];
    NSArray<NSNumber *> *gaps = [self gapsForBaseSize:baseSize];
    for (NSUInteger index = 0; index < lines.count; index++) {
        NSSize size = lines[index].size;
        cursorY -= size.height;
        CGFloat x = floor((panelSize.width - size.width) / 2.0);
        [frames addObject:[NSValue valueWithRect:NSMakeRect(x, cursorY, size.width, size.height)]];
        if (index < gaps.count) {
            cursorY -= gaps[index].doubleValue;
        }
    }

    ScreenISOPanelLayout *layout = [[ScreenISOPanelLayout alloc] init];
    layout.frame = NSMakeRect(NSMinX(bounds) + originX, NSMinY(bounds) + originY, panelSize.width, panelSize.height);
    layout.cornerRadius = MAX(round(baseSize * 0.18), 2.0);
    layout.lines = lines;
    layout.lineFrames = frames;
    return layout;
}

- (CGFloat)horizontalPaddingForBaseSize:(CGFloat)baseSize {
    return round(baseSize * 0.9);
}

- (CGFloat)verticalPaddingForBaseSize:(CGFloat)baseSize {
    return round(baseSize * 0.7);
}

- (NSAttributedString *)titleWithAttributes:(NSDictionary *)attributes visibleDots:(NSInteger)visibleDots {
    NSString *dots = [@"" stringByPaddingToLength:(NSUInteger)kTitleDotCount withString:@"." startingAtIndex:0];
    NSMutableAttributedString *title =
        [[NSMutableAttributedString alloc] initWithString:[kTitleText stringByAppendingString:dots]
                                               attributes:attributes];
    // Hidden dots stay in the string, transparent: the title keeps its width, so the centred text never shifts.
    NSInteger hiddenDots = kTitleDotCount - MAX(MIN(visibleDots, kTitleDotCount), 0);
    if (hiddenDots > 0) {
        [title addAttribute:NSForegroundColorAttributeName
                      value:[NSColor clearColor]
                      range:NSMakeRange(title.length - (NSUInteger)hiddenDots, (NSUInteger)hiddenDots)];
    }
    return title;
}

- (NSArray<NSAttributedString *> *)linesWithBaseSize:(CGFloat)baseSize
                                               clock:(NSString *)clock
                                         visibleDots:(NSInteger)visibleDots {
    NSColor *secondary = [NSColor colorWithSRGBRed:0.62 green:0.61 blue:0.59 alpha:1.0];

    NSDictionary *titleAttributes = @{
        NSFontAttributeName : [NSFont systemFontOfSize:baseSize weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName : [NSColor whiteColor],
    };
    NSDictionary *messageAttributes = @{
        NSFontAttributeName : [NSFont systemFontOfSize:baseSize * 0.5 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName : secondary,
    };
    NSDictionary *timeAttributes = @{
        NSFontAttributeName : [NSFont monospacedDigitSystemFontOfSize:baseSize * 0.6 weight:NSFontWeightLight],
        NSForegroundColorAttributeName : secondary,
    };

    return @[
        [self titleWithAttributes:titleAttributes visibleDots:visibleDots],
        [[NSAttributedString alloc] initWithString:kMessageText attributes:messageAttributes],
        [[NSAttributedString alloc] initWithString:clock attributes:timeAttributes],
    ];
}

- (NSArray<NSNumber *> *)gapsForBaseSize:(CGFloat)baseSize {
    return @[ @(round(baseSize * 0.35)), @(round(baseSize * 0.6)) ];
}

- (NSSize)panelSizeForLines:(NSArray<NSAttributedString *> *)lines baseSize:(CGFloat)baseSize {
    CGFloat width = 0.0;
    CGFloat height = 0.0;
    for (NSAttributedString *line in lines) {
        NSSize size = line.size;
        width = MAX(width, size.width);
        height += size.height;
    }
    for (NSNumber *gap in [self gapsForBaseSize:baseSize]) {
        height += gap.doubleValue;
    }
    width += 2.0 * [self horizontalPaddingForBaseSize:baseSize];
    height += 2.0 * [self verticalPaddingForBaseSize:baseSize];
    return NSMakeSize(MAX(width, 1.0), MAX(height, 1.0));
}

@end
