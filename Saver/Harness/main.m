// Offscreen checks for ScreenISOSaver.saver. Loads the bundle, renders the layer tree at
// chosen instants, measures CPU in a window and streams preview frames. Never installs the
// saver and never starts ScreenSaverEngine.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <sys/resource.h>

#import "../ScreenISOSaverView.h"

static int gFailures = 0;
static FILE *gReport = NULL;

static void Check(BOOL condition, NSString *message) {
    if (!condition) {
        gFailures += 1;
        fprintf(stderr, "FAIL %s\n", message.UTF8String);
    } else {
        fprintf(gReport, "ok   %s\n", message.UTF8String);
    }
}

#pragma mark - Rendering

@interface Frame : NSObject
@property(nonatomic) size_t width;
@property(nonatomic) size_t height;
@property(nonatomic) size_t bytesPerRow;
@property(nonatomic, strong) NSMutableData *pixels;
@property(nonatomic) CGFloat scale;
@property(nonatomic) CGFloat pointHeight;
@end

@implementation Frame

- (const uint8_t *)pixelAtX:(NSInteger)x y:(NSInteger)y {
    x = MAX(0, MIN(x, (NSInteger)self.width - 1));
    y = MAX(0, MIN(y, (NSInteger)self.height - 1));
    return (const uint8_t *)self.pixels.bytes + (size_t)y * self.bytesPerRow + (size_t)x * 4;
}

// Point coordinates are bottom-left based, like the view.
- (const uint8_t *)pixelAtPoint:(NSPoint)point {
    return [self pixelAtX:(NSInteger)floor(point.x * self.scale)
                        y:(NSInteger)floor((self.pointHeight - point.y) * self.scale)];
}

- (BOOL)writePNG:(NSString *)path {
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)self.pixels);
    CGImageRef image = CGImageCreate(self.width, self.height, 8, 32, self.bytesPerRow, colorSpace,
                                     (CGBitmapInfo)kCGImageAlphaPremultipliedLast, provider, NULL, false,
                                     kCGRenderingIntentDefault);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
    CGImageRelease(image);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES];
}

@end

static Frame *Render(NSView *view, CGFloat scale) {
    NSSize size = view.bounds.size;
    Frame *frame = [[Frame alloc] init];
    frame.width = (size_t)(size.width * scale);
    frame.height = (size_t)(size.height * scale);
    frame.bytesPerRow = frame.width * 4;
    frame.scale = scale;
    frame.pointHeight = size.height;
    frame.pixels = [NSMutableData dataWithLength:frame.bytesPerRow * frame.height];

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(frame.pixels.mutableBytes, frame.width, frame.height, 8,
                                                 frame.bytesPerRow, colorSpace,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colorSpace);
    CGContextScaleCTM(context, scale, scale);
    [view.layer renderInContext:context];
    CGContextRelease(context);
    return frame;
}

static BOOL IsCoral(const uint8_t *p) {
    return p[0] > 180 && p[1] < 140 && p[2] < 110;
}

static BOOL IsIvory(const uint8_t *p) {
    return p[0] > 200 && p[1] > 200 && p[2] > 190;
}

static double Luminance(const uint8_t *p) {
    return 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2];
}

static NSUInteger CountPixels(Frame *frame, BOOL (*predicate)(const uint8_t *)) {
    NSUInteger count = 0;
    for (size_t y = 0; y < frame.height; y += 2) {
        for (size_t x = 0; x < frame.width; x += 2) {
            if (predicate([frame pixelAtX:(NSInteger)x y:(NSInteger)y])) {
                count += 1;
            }
        }
    }
    return count;
}

static NSUInteger BrightPixels(Frame *frame, NSRect area) {
    NSUInteger count = 0;
    CGFloat px = 1.0 / frame.scale;
    for (CGFloat y = NSMinY(area); y < NSMaxY(area); y += px) {
        for (CGFloat x = NSMinX(area); x < NSMaxX(area); x += px) {
            if (Luminance([frame pixelAtPoint:NSMakePoint(x, y)]) > 128.0) {
                count += 1;
            }
        }
    }
    return count;
}

// Horizontal extent, in points, of the pixels inside `area` that differ between two renders.
static CGFloat DifferenceWidth(Frame *first, Frame *second, NSRect area) {
    CGFloat px = 1.0 / first.scale;
    CGFloat minX = CGFLOAT_MAX;
    CGFloat maxX = -CGFLOAT_MAX;
    for (CGFloat y = NSMinY(area); y < NSMaxY(area); y += px) {
        for (CGFloat x = NSMinX(area); x < NSMaxX(area); x += px) {
            NSPoint point = NSMakePoint(x, y);
            if (memcmp([first pixelAtPoint:point], [second pixelAtPoint:point], 4) != 0) {
                minX = MIN(minX, x);
                maxX = MAX(maxX, x);
            }
        }
    }
    return maxX >= minX ? maxX - minX + px : 0.0;
}

#pragma mark - View helpers

static ScreenISOSaverView *MakeView(Class cls, NSRect frame, BOOL isPreview) {
    typedef id (*InitFn)(id, SEL, NSRect, BOOL);
    InitFn init = (InitFn)[cls instanceMethodForSelector:@selector(initWithFrame:isPreview:)];
    return init([cls alloc], @selector(initWithFrame:isPreview:), frame, isPreview);
}

static void SetFractions(NSView *view, CGFloat horizontal, CGFloat vertical) {
    [view setValue:@(horizontal) forKey:@"horizontalFraction"];
    [view setValue:@(vertical) forKey:@"verticalFraction"];
}

static NSTimeInterval FindTime(NSTimeInterval from, BOOL (^match)(NSTimeInterval)) {
    for (NSTimeInterval t = from; t < from + 2000.0; t += 0.05) {
        if (match(t)) {
            return t;
        }
    }
    return -1.0;
}

// Every shared tile edge is crossed by exactly one arc end on each side. At rest the two
// luminance profiles along the edge must match: any step or gap shows up as a mismatch.
static NSUInteger SeamMismatches(ScreenISOSaverView *view, Frame *frame, NSUInteger *edgesChecked) {
    CGFloat side = view.tileSize;
    NSPoint origin = view.gridOrigin;
    NSRect panel = NSInsetRect(view.textBlockFrame, -side, -side);
    NSRect visible = NSInsetRect(view.bounds, 2.0, 2.0);
    CGFloat px = 1.0 / frame.scale;
    CGFloat halfSpan = side * 0.2;
    NSUInteger mismatches = 0;
    NSUInteger checked = 0;

    for (NSInteger row = 0; row < view.gridRows; row++) {
        for (NSInteger column = 0; column < view.gridColumns; column++) {
            CGFloat left = origin.x + (CGFloat)column * side;
            CGFloat bottom = origin.y + (CGFloat)row * side;
            NSPoint verticalMid = NSMakePoint(left + side, bottom + side / 2.0);
            NSPoint horizontalMid = NSMakePoint(left + side / 2.0, bottom + side);
            for (int orientation = 0; orientation < 2; orientation++) {
                NSPoint mid = orientation == 0 ? verticalMid : horizontalMid;
                if (orientation == 0 && column == view.gridColumns - 1) {
                    continue;
                }
                if (orientation == 1 && row == view.gridRows - 1) {
                    continue;
                }
                NSRect probe = NSMakeRect(mid.x - halfSpan, mid.y - halfSpan, 2.0 * halfSpan, 2.0 * halfSpan);
                if (NSIntersectsRect(probe, panel) || !NSContainsRect(visible, probe)) {
                    continue;
                }
                checked += 1;
                BOOL centreIsIvory = YES;
                for (CGFloat k = -halfSpan; k <= halfSpan; k += px) {
                    NSPoint before = orientation == 0 ? NSMakePoint(mid.x - 1.5 * px, mid.y + k)
                                                      : NSMakePoint(mid.x + k, mid.y - 1.5 * px);
                    NSPoint after = orientation == 0 ? NSMakePoint(mid.x + 0.5 * px, mid.y + k)
                                                     : NSMakePoint(mid.x + k, mid.y + 0.5 * px);
                    const uint8_t *a = [frame pixelAtPoint:before];
                    const uint8_t *b = [frame pixelAtPoint:after];
                    if (fabs(Luminance(a) - Luminance(b)) > 48.0) {
                        mismatches += 1;
                        break;
                    }
                    if (fabs(k) < px && !(IsIvory(a) && IsIvory(b))) {
                        centreIsIvory = NO;
                    }
                }
                if (!centreIsIvory) {
                    mismatches += 1;
                }
            }
        }
    }
    *edgesChecked = checked;
    return mismatches;
}

static void CheckPlacement(ScreenISOSaverView *view, NSString *name) {
    NSRect bounds = view.bounds;
    BOOL allInside = YES;
    NSRect lastFrame = NSZeroRect;
    NSUInteger distinct = 0;
    for (int i = 0; i < 500; i++) {
        [view relocateTextBlock];
        NSRect frame = view.textBlockFrame;
        if (!NSContainsRect(bounds, frame)) {
            allInside = NO;
            fprintf(stderr, "     %s outside %s\n", NSStringFromRect(frame).UTF8String,
                    NSStringFromRect(bounds).UTF8String);
            break;
        }
        if (!NSEqualRects(frame, lastFrame)) {
            distinct += 1;
        }
        lastFrame = frame;
    }
    Check(allInside, [NSString stringWithFormat:@"%@: 500 random panel positions stay inside bounds", name]);
    Check(distinct > 400, [NSString stringWithFormat:@"%@: relocation moves the panel (%lu distinct)", name,
                                                     (unsigned long)distinct]);
}

static void CheckPanelOpaque(ScreenISOSaverView *view, Frame *frame, NSString *name) {
    NSRect panel = view.textBlockFrame;
    NSPoint inset = NSMakePoint(NSMinX(panel) + 6.0, NSMinY(panel) + 6.0);
    const uint8_t *p = [frame pixelAtPoint:inset];
    Check(p[0] < 20 && p[1] < 20 && p[2] < 24,
          [NSString stringWithFormat:@"%@: text panel is dark and opaque over the pattern", name]);
}

static Class LoadPrincipalClass(NSString *bundlePath) {
    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    NSError *loadError = nil;
    Check(bundle != nil && [bundle loadAndReturnError:&loadError],
          [NSString stringWithFormat:@"bundle loads (%@)", loadError.localizedDescription ?: @"no error"]);
    if (gFailures > 0) {
        return Nil;
    }
    Check([bundle.bundleIdentifier isEqualToString:@"it.yellowtech.screeniso.saver"], @"bundle identifier");
    Class principal = bundle.principalClass;
    Check([NSStringFromClass(principal) isEqualToString:@"ScreenISOSaverView"], @"principal class name");
    Class screenSaverView = NSClassFromString(@"ScreenSaverView");
    Check(screenSaverView != Nil && [principal isSubclassOfClass:screenSaverView],
          @"principal class is a ScreenSaverView");
    return gFailures > 0 ? Nil : principal;
}

static uint64_t SeedWithOverlappingWaves(Class principal) {
    ScreenISOSaverView *probe = MakeView(principal, NSMakeRect(0, 0, 1512, 982), NO);
    for (uint64_t seed = 42; seed < 4000; seed++) {
        probe.animationSeed = seed;
        for (NSTimeInterval t = 0.0; t < 20.0; t += 0.1) {
            if ([probe activeWaveCountAtTime:t] >= 2) {
                return seed;
            }
        }
    }
    return 42;
}

#pragma mark - Modes

static int RunChecks(Class principal, NSString *outputDir) {
    uint64_t seed = 0x2A;
    ScreenISOSaverView *full = MakeView(principal, NSMakeRect(0, 0, 1512, 982), NO);
    full.animationSeed = seed;
    Check(full.gridColumns >= 16 && full.gridColumns <= 19,
          [NSString stringWithFormat:@"fullscreen grid %ldx%ld tiles of %.0f pt", (long)full.gridColumns,
                                     (long)full.gridRows, full.tileSize]);
    Check(full.gridOrigin.x <= 0.0 && full.gridOrigin.y <= 0.0 &&
              full.gridOrigin.x + full.gridColumns * full.tileSize >= 1512.0 &&
              full.gridOrigin.y + full.gridRows * full.tileSize >= 982.0,
          @"fullscreen grid covers the whole screen");

    NSTimeInterval firstStart = [full nextWaveStartAfter:0.0];
    NSTimeInterval rest = FindTime(firstStart + 1.0, ^BOOL(NSTimeInterval t) {
        return [full activeWaveCountAtTime:t] == 0;
    }) + 0.5;
    NSTimeInterval midWave = FindTime(0.0, ^BOOL(NSTimeInterval t) {
        NSArray<NSNumber *> *fronts = [full waveFrontFractionsAtTime:t];
        return fronts.count == 1 && fabs(fronts.firstObject.doubleValue - 0.5) < 0.02;
    });
    NSTimeInterval twoWaves = FindTime(0.0, ^BOOL(NSTimeInterval t) {
        NSArray<NSNumber *> *fronts = [full waveFrontFractionsAtTime:t];
        return fronts.count >= 2 && fronts.lastObject.doubleValue > 0.25;
    });
    Check(rest > 0 && midWave > 0 && twoWaves > 0,
          [NSString stringWithFormat:@"schedule has rest (t=%.2f), mid wave (t=%.2f), two waves (t=%.2f)", rest,
                                     midWave, twoWaves]);

    SetFractions(full, 0.5, 0.5);
    struct {
        NSString *name;
        NSTimeInterval time;
        BOOL expectCoral;
    } cases[] = {
        {@"full-before-first-wave", firstStart - 0.5, NO},
        {@"full-rest-after-wave", rest, NO},
        {@"full-wave-mid-screen", midWave, YES},
        {@"full-two-waves", twoWaves, YES},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        [full applyAnimationStateAtTime:cases[i].time];
        Frame *frame = Render(full, 2.0);
        NSString *path = [outputDir stringByAppendingPathComponent:[cases[i].name stringByAppendingString:@".png"]];
        Check([frame writePNG:path], [NSString stringWithFormat:@"%@: PNG written (t=%.2f)", cases[i].name,
                                                                cases[i].time]);
        NSUInteger coral = CountPixels(frame, IsCoral);
        NSUInteger ivory = CountPixels(frame, IsIvory);
        if (cases[i].expectCoral) {
            Check(coral > 2000, [NSString stringWithFormat:@"%@: coral band present (%lu px)", cases[i].name,
                                                           (unsigned long)coral]);
        } else {
            Check(coral == 0, [NSString stringWithFormat:@"%@: no coral at rest", cases[i].name]);
            NSUInteger edges = 0;
            NSUInteger mismatches = SeamMismatches(full, frame, &edges);
            Check(edges > 200 && mismatches == 0,
                  [NSString stringWithFormat:@"%@: arcs join without steps on %lu shared edges (%lu mismatches)",
                                             cases[i].name, (unsigned long)edges, (unsigned long)mismatches]);
        }
        Check(ivory > 20000, [NSString stringWithFormat:@"%@: ivory pattern drawn", cases[i].name]);
        CheckPanelOpaque(full, frame, cases[i].name);
    }

    [full applyAnimationStateAtTime:midWave];
    Frame *first = Render(full, 1.0);
    [full applyAnimationStateAtTime:twoWaves];
    [full applyAnimationStateAtTime:rest];
    [full applyAnimationStateAtTime:midWave];
    Frame *second = Render(full, 1.0);
    Check([first.pixels isEqualToData:second.pixels], @"state is a pure function of (time, seed)");

    NSMutableArray<Frame *> *dotFrames = [NSMutableArray array];
    NSMutableArray<NSValue *> *dotPanels = [NSMutableArray array];
    for (int dots = 1; dots <= 3; dots++) {
        [full applyAnimationStateAtTime:0.25 + 0.5 * (dots - 1)];
        Frame *frame = Render(full, 2.0);
        NSString *file = [NSString stringWithFormat:@"full-title-dots-%d.png", dots];
        Check([frame writePNG:[outputDir stringByAppendingPathComponent:file]],
              [NSString stringWithFormat:@"title with %d dots: PNG written", dots]);
        [dotFrames addObject:frame];
        [dotPanels addObject:[NSValue valueWithRect:[(CALayer *)[full valueForKey:@"panelLayer"] frame]]];
    }
    NSRect dotPanel = dotPanels[0].rectValue;
    Check(NSEqualRects(dotPanel, dotPanels[1].rectValue) && NSEqualRects(dotPanel, dotPanels[2].rectValue) &&
              NSEqualRects(dotPanel, full.textBlockFrame),
          @"title dots: the panel keeps its frame in every phase");
    NSUInteger oneDot = BrightPixels(dotFrames[0], dotPanel);
    NSUInteger twoDots = BrightPixels(dotFrames[1], dotPanel);
    NSUInteger threeDots = BrightPixels(dotFrames[2], dotPanel);
    Check(oneDot > 0 && oneDot < twoDots && twoDots < threeDots,
          [NSString stringWithFormat:@"title dots: one more dot every half second (%lu < %lu < %lu bright px)",
                                     (unsigned long)oneDot, (unsigned long)twoDots, (unsigned long)threeDots]);
    CGFloat changedWidth = DifferenceWidth(dotFrames[0], dotFrames[2], dotPanel);
    Check(changedWidth > 0.0 && changedWidth < NSWidth(dotPanel) * 0.1,
          [NSString stringWithFormat:@"title dots: only the dots change, the text does not shift (%.1f of %.0f pt)",
                                     changedWidth, NSWidth(dotPanel)]);
    [full applyAnimationStateAtTime:0.25 + 0.5 * 3];
    Check(BrightPixels(Render(full, 2.0), dotPanel) == oneDot, @"title dots: the cycle restarts from one dot");

    SetFractions(full, 0.0, 0.0);
    [full applyAnimationStateAtTime:rest];
    Check([Render(full, 2.0) writePNG:[outputDir stringByAppendingPathComponent:@"full-panel-bottom-left.png"]],
          @"panel bottom-left render");
    SetFractions(full, 1.0, 1.0);
    [full applyAnimationStateAtTime:rest];
    Check([Render(full, 2.0) writePNG:[outputDir stringByAppendingPathComponent:@"full-panel-top-right.png"]],
          @"panel top-right render");
    CheckPlacement(full, @"fullscreen");

    ScreenISOSaverView *preview = MakeView(principal, NSMakeRect(0, 0, 296, 184), YES);
    preview.animationSeed = seed;
    Check(preview.gridColumns < full.gridColumns,
          [NSString stringWithFormat:@"preview uses fewer tiles (%ldx%ld)", (long)preview.gridColumns,
                                     (long)preview.gridRows]);
    NSTimeInterval previewWave = FindTime(0.0, ^BOOL(NSTimeInterval t) {
        NSArray<NSNumber *> *fronts = [preview waveFrontFractionsAtTime:t];
        return fronts.count == 1 && fabs(fronts.firstObject.doubleValue - 0.45) < 0.02;
    });
    SetFractions(preview, 0.5, 0.5);
    [preview applyAnimationStateAtTime:previewWave];
    Frame *previewFrame = Render(preview, 2.0);
    Check([previewFrame writePNG:[outputDir stringByAppendingPathComponent:@"preview-wave.png"]],
          @"preview-wave: PNG written");
    Check(CountPixels(previewFrame, IsCoral) > 50, @"preview-wave: coral band present");
    [preview applyAnimationStateAtTime:[preview nextWaveStartAfter:0.0] - 0.5];
    Frame *previewRest = Render(preview, 2.0);
    Check([previewRest writePNG:[outputDir stringByAppendingPathComponent:@"preview-rest.png"]],
          @"preview-rest: PNG written");
    CheckPanelOpaque(preview, previewRest, @"preview-rest");
    CheckPlacement(preview, @"preview");

    ScreenISOSaverView *portrait = MakeView(principal, NSMakeRect(0, 0, 640, 1136), NO);
    portrait.animationSeed = seed;
    [portrait applyAnimationStateAtTime:[portrait nextWaveStartAfter:0.0] + 3.0];
    Check([Render(portrait, 2.0) writePNG:[outputDir stringByAppendingPathComponent:@"portrait-640x1136.png"]],
          @"portrait: PNG written");
    CheckPlacement(portrait, @"portrait");

    ScreenISOSaverView *ghost = MakeView(principal, NSZeroRect, YES);
    [ghost applyAnimationStateAtTime:5.0];
    [ghost startAnimation];
    [ghost stopAnimation];
    Check(ghost != nil && ghost.gridColumns == 0, @"zero-size instance builds no tiles and does not crash");

    __weak ScreenISOSaverView *weakView = nil;
    @autoreleasepool {
        ScreenISOSaverView *live = MakeView(principal, NSMakeRect(0, 0, 1512, 982), NO);
        weakView = live;
        live.animationSeed = seed;
        SetFractions(live, 0.3, 0.6);
        [live setValue:[NSDate dateWithTimeIntervalSince1970:1795449600] forKey:@"clockDate"];
        [live startAnimation];
        Check(live.isAnimating, @"startAnimation starts the animation");
        Check([live valueForKey:@"redrawTimer"] != nil, @"frame timer is scheduled");
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
        [live applyAnimationStateAtTime:midWave];
        Frame *beforeStop = Render(live, 1.0);
        NSUInteger tileCount = [[live valueForKey:@"tileLayers"] count];
        Check(tileCount == (NSUInteger)(live.gridColumns * live.gridRows) && tileCount > 0,
              [NSString stringWithFormat:@"running instance owns %lu tile layers", (unsigned long)tileCount]);

        [live performSelector:@selector(screenSaverWillStop:) withObject:nil];
        Check(!live.isAnimating, @"willstop handler stops the animation");
        Check([live valueForKey:@"redrawTimer"] == nil, @"willstop handler invalidates the frame timer");
        Check([[live valueForKey:@"tileLayers"] count] == 0 && [live valueForKey:@"tilesLayer"] == nil &&
                  [live valueForKey:@"panelLayer"] == nil && [live valueForKey:@"field"] == nil,
              @"willstop handler releases tile layers, images, panel and field");
        Check(live.layer.sublayers.count == 0, @"released instance keeps no sublayers");
        live.frame = NSMakeRect(0, 0, 1512, 982);
        [live applyAnimationStateAtTime:midWave];
        Check([[live valueForKey:@"tileLayers"] count] == 0, @"released instance stays empty until restarted");
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2.5]];
        Check(!live.isAnimating && [live valueForKey:@"redrawTimer"] == nil,
              @"no timer restarts by itself after willstop (no scheduled exit, no relaunch logic)");

        [live startAnimation];
        Check(live.isAnimating && [live valueForKey:@"redrawTimer"] != nil, @"startAnimation after willstop restarts");
        Check([[live valueForKey:@"tileLayers"] count] == tileCount, @"startAnimation rebuilds the tile layers");
        [live applyAnimationStateAtTime:midWave];
        Frame *afterRestart = Render(live, 1.0);
        Check([beforeStop.pixels isEqualToData:afterRestart.pixels],
              @"render after rebuild is identical at the same instant");
        [live stopAnimation];
    }
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    Check(weakView == nil, @"view is deallocated after release (no retain cycle via timer or observers)");

    fprintf(gReport, "%s\n", gFailures == 0 ? "all checks passed" : "checks failed");
    return gFailures == 0 ? 0 : 1;
}

static double ProcessCPUSeconds(void) {
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    return (double)usage.ru_utime.tv_sec + (double)usage.ru_utime.tv_usec / 1e6 + (double)usage.ru_stime.tv_sec +
           (double)usage.ru_stime.tv_usec / 1e6;
}

static int RunSoak(Class principal, double seconds) {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSRect screen = [NSScreen mainScreen].frame;
    NSRect frame = NSMakeRect(NSMinX(screen), NSMinY(screen), MIN(1512.0, NSWidth(screen)),
                              MIN(982.0, NSHeight(screen)));
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.releasedWhenClosed = NO;
    ScreenISOSaverView *view = MakeView(principal, NSMakeRect(0, 0, NSWidth(frame), NSHeight(frame)), NO);
    view.animationSeed = SeedWithOverlappingWaves(principal);
    window.contentView = view;
    [window orderFrontRegardless];
    [view startAnimation];
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];

    CFTimeInterval origin = [[view valueForKey:@"timeOrigin"] doubleValue];
    double waveTotal = 0.0, idleTotal = 0.0, peak = 0.0;
    int waveSamples = 0, idleSamples = 0, samples = 0;
    double startCPU = ProcessCPUSeconds();
    CFTimeInterval startWall = CACurrentMediaTime();
    while (CACurrentMediaTime() - startWall < seconds) {
        double cpuBefore = ProcessCPUSeconds();
        CFTimeInterval wallBefore = CACurrentMediaTime();
        NSInteger waves = [view activeWaveCountAtTime:wallBefore - origin + 0.5];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
        double share = (ProcessCPUSeconds() - cpuBefore) / (CACurrentMediaTime() - wallBefore) * 100.0;
        samples += 1;
        peak = MAX(peak, share);
        if (waves > 0) {
            waveTotal += share;
            waveSamples += 1;
        } else {
            idleTotal += share;
            idleSamples += 1;
        }
        fprintf(gReport, "sample %2d waves=%ld cpu=%.2f%%\n", samples, (long)waves, share);
    }
    double overall = (ProcessCPUSeconds() - startCPU) / (CACurrentMediaTime() - startWall) * 100.0;
    [view stopAnimation];
    [window orderOut:nil];
    [window close];

    fprintf(gReport, "window %.0fx%.0f, scale %.0f, grid %ldx%ld, %d s measured\n", NSWidth(frame), NSHeight(frame),
            window.backingScaleFactor, (long)view.gridColumns, (long)view.gridRows, samples);
    fprintf(gReport, "cpu overall %.2f%% of one core, during waves %.2f%% (%d s), idle %.2f%% (%d s), peak %.2f%%\n",
            overall, waveSamples ? waveTotal / waveSamples : 0.0, waveSamples,
            idleSamples ? idleTotal / idleSamples : 0.0, idleSamples, peak);
    return 0;
}

static int RunVideo(Class principal, double seconds, double fps) {
    uint64_t seed = SeedWithOverlappingWaves(principal);
    ScreenISOSaverView *view = MakeView(principal, NSMakeRect(0, 0, 1512, 982), NO);
    view.animationSeed = seed;
    SetFractions(view, 0.18, 0.72);
    [view setValue:[NSDate dateWithTimeIntervalSince1970:1795449600] forKey:@"clockDate"];
    NSTimeInterval start = MAX([view nextWaveStartAfter:0.0] - 1.5, 0.0);
    int frames = (int)lround(seconds * fps);
    for (int i = 0; i < frames; i++) {
        @autoreleasepool {
            if (i == frames / 2) {
                SetFractions(view, 0.74, 0.22);
            }
            [view applyAnimationStateAtTime:start + (double)i / fps];
            Frame *frame = Render(view, 1.0);
            fwrite(frame.pixels.bytes, 1, frame.pixels.length, stdout);
        }
    }
    fflush(stdout);
    fprintf(stderr, "video: seed %llu, %d frames from t=%.2f\n", (unsigned long long)seed, frames, start);
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        gReport = stdout;
        if (argc < 3) {
            fprintf(stderr,
                    "usage: %s check <saver> <output-dir>\n"
                    "       %s soak <saver> <seconds>\n"
                    "       %s video <saver> <seconds> <fps>   (raw RGBA 1512x982 on stdout)\n",
                    argv[0], argv[0], argv[0]);
            return 2;
        }
        NSString *mode = @(argv[1]);
        if ([mode isEqualToString:@"video"]) {
            gReport = stderr;
        }
        [NSApplication sharedApplication];
        Class principal = LoadPrincipalClass(@(argv[2]));
        if (principal == Nil) {
            return 1;
        }
        if ([mode isEqualToString:@"check"] && argc == 4) {
            return RunChecks(principal, @(argv[3]));
        }
        if ([mode isEqualToString:@"soak"] && argc == 4) {
            return RunSoak(principal, atof(argv[3]));
        }
        if ([mode isEqualToString:@"video"] && argc == 5) {
            return RunVideo(principal, atof(argv[3]), atof(argv[4]));
        }
        fprintf(stderr, "unknown mode or wrong arguments\n");
        return 2;
    }
}
