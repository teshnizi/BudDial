// Draws BudDial's app icon and writes src/AppIcon.icns and docs/icon.png.
// Run: tools/make_icon.sh. The mark (an earbud that is also a speech bubble, with typing dots) comes
// from src/BudMark.m, shared with the menu bar glyph. It is drawn by hand: the SF Symbols license
// does not allow symbols in app icons.
#import <AppKit/AppKit.h>
#import "../src/BudMark.h"

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
    NSGradient *gloss = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:1 alpha:.16] endingColor:[NSColor colorWithWhite:1 alpha:0]];
    [gloss drawInBezierPath:squircle angle:-90];

    // The mark, white with a soft shadow; its dots are cut through so the tile shows in them.
    NSRect box = NSMakeRect(512 - 300 + 12, 512 - 300 - 4, 600, 600);
    NSShadow *markShadow = [NSShadow new];
    markShadow.shadowColor = [NSColor colorWithSRGBRed:.10 green:.08 blue:.40 alpha:.35];
    markShadow.shadowBlurRadius = 34;
    markShadow.shadowOffset = NSMakeSize(0, -18);
    [NSGraphicsContext saveGraphicsState];
    [markShadow set];
    CGContextBeginTransparencyLayer(context, NULL);
    [NSColor.whiteColor setFill];
    [APBudMarkShape(box) fill];
    [NSGraphicsContext.currentContext setCompositingOperation:NSCompositingOperationDestinationOut];
    for (NSBezierPath *dot in APBudMarkDots(box)) [dot fill];
    CGContextEndTransparencyLayer(context);
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
