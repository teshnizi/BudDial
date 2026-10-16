// Draws BudDial's app icon and writes src/AppIcon.icns and docs/icon.png.
// Run: tools/make_icon.sh. The bud is drawn here, not taken from Apple's symbols: the SF Symbols
// license does not allow them in app icons.
#import <AppKit/AppKit.h>

static const CGFloat kCanvas = 1024;

static void drawIcon(CGFloat size) {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextScaleCTM(context, size / kCanvas, size / kCanvas);

    // The macOS icon grid: an 824 pt rounded square centered on a 1024 pt canvas, with a soft shadow.
    NSRect tile = NSMakeRect(100, 100, 824, 824);
    NSBezierPath *squircle = [NSBezierPath bezierPathWithRoundedRect:tile xRadius:185 yRadius:185];
    [NSGraphicsContext saveGraphicsState];
    NSShadow *tileShadow = [NSShadow new];
    tileShadow.shadowColor = [NSColor colorWithWhite:0 alpha:.28];
    tileShadow.shadowBlurRadius = 24;
    tileShadow.shadowOffset = NSMakeSize(0, -10);
    [tileShadow set];
    [[NSColor colorWithSRGBRed:.30 green:.42 blue:.96 alpha:1] setFill];
    [squircle fill];
    [NSGraphicsContext restoreGraphicsState];
    NSGradient *background = [[NSGradient alloc] initWithColors:@[
        [NSColor colorWithSRGBRed:.36 green:.62 blue:1.00 alpha:1],
        [NSColor colorWithSRGBRed:.33 green:.36 blue:.95 alpha:1],
        [NSColor colorWithSRGBRed:.42 green:.25 blue:.86 alpha:1]]];
    [background drawInBezierPath:squircle angle:-60];
    // A faint highlight along the top edge, as on Apple's own icons.
    NSGradient *gloss = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:1 alpha:.16] endingColor:[NSColor colorWithWhite:1 alpha:0]];
    [gloss drawInBezierPath:squircle angle:-90];

    [NSGraphicsContext saveGraphicsState];
    [squircle addClip];

    // The bud: a tilted bean-shaped head and a stem, white, with a soft shadow.
    NSPoint head = NSMakePoint(360, 590);
    NSAffineTransform *headTilt = [NSAffineTransform transform];
    [headTilt translateXBy:head.x yBy:head.y];
    [headTilt rotateByDegrees:-22];
    NSAffineTransform *stemTilt = [NSAffineTransform transform];
    [stemTilt translateXBy:head.x + 58 yBy:head.y - 40];
    [stemTilt rotateByDegrees:9];
    NSBezierPath *stem = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(-52, -370, 104, 380) xRadius:52 yRadius:52];
    [stem transformUsingAffineTransform:stemTilt];
    NSBezierPath *bud = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(-160, -128, 320, 256)];
    [bud transformUsingAffineTransform:headTilt];
    [bud appendBezierPath:stem];
    [NSGraphicsContext saveGraphicsState];
    NSShadow *budShadow = [NSShadow new];
    budShadow.shadowColor = [NSColor colorWithSRGBRed:.10 green:.08 blue:.40 alpha:.35];
    budShadow.shadowBlurRadius = 30;
    budShadow.shadowOffset = NSMakeSize(8, -16);
    [budShadow set];
    [[NSColor colorWithWhite:1 alpha:1] setFill];
    [bud fill];
    [NSGraphicsContext restoreGraphicsState];
    // The speaker grille, on the side that goes into the ear.
    NSBezierPath *grille = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(-118, -10, 92, 62)];
    [grille transformUsingAffineTransform:headTilt];
    [[NSColor colorWithSRGBRed:.24 green:.27 blue:.62 alpha:.85] setFill];
    [grille fill];

    // The voice: three arcs to the right of the head.
    NSArray<NSNumber *> *alphas = @[@.95, @.7, @.45];
    for (NSUInteger i = 0; i < alphas.count; i++) {
        NSBezierPath *arc = [NSBezierPath bezierPath];
        [arc appendBezierPathWithArcWithCenter:NSMakePoint(head.x + 60, head.y) radius:235 + i * 78 startAngle:-38 endAngle:38];
        arc.lineWidth = 40;
        arc.lineCapStyle = NSLineCapStyleRound;
        [[NSColor colorWithWhite:1 alpha:alphas[i].doubleValue] setStroke];
        [arc stroke];
    }
    [NSGraphicsContext restoreGraphicsState];
}

static NSData *png(CGFloat pixels) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)pixels pixelsHigh:(NSInteger)pixels
                                                                 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                                colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
    drawIcon(pixels);
    [NSGraphicsContext restoreGraphicsState];
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: make_icon <iconset dir> <preview png>\n"); return 1; }
    NSString *iconset = [NSString stringWithUTF8String:argv[1]];
    [NSFileManager.defaultManager createDirectoryAtPath:iconset withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSNumber *points in @[@16, @32, @128, @256, @512]) {
        int p = points.intValue;
        [png(p) writeToFile:[iconset stringByAppendingPathComponent:[NSString stringWithFormat:@"icon_%dx%d.png", p, p]] atomically:YES];
        [png(p * 2) writeToFile:[iconset stringByAppendingPathComponent:[NSString stringWithFormat:@"icon_%dx%d@2x.png", p, p]] atomically:YES];
    }
    [png(512) writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES];
}}
