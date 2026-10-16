#import "BudMark.h"

// Geometry on a 100 x 100 grid, origin at the bottom left. The stem drops almost straight from under
// the head, as on an earbud; at an angle from its side it read as a magnifying glass.
static const CGFloat kHeadX = 46, kHeadY = 62, kHeadR = 28;
static const CGFloat kStemTopX = 53, kStemTopY = 44, kStemWidth = 15, kStemLength = 40, kStemTilt = 7;
static const CGFloat kDotR = 4.2, kDotGap = 12;

static NSAffineTransform *gridTo(NSRect box) {
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform translateXBy:NSMinX(box) yBy:NSMinY(box)];
    [transform scaleBy:NSWidth(box) / 100];
    return transform;
}

NSBezierPath *APBudMarkShape(NSRect box) {
    NSBezierPath *shape = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(kHeadX - kHeadR, kHeadY - kHeadR, 2 * kHeadR, 2 * kHeadR)];
    NSBezierPath *stem = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(-kStemWidth / 2, -kStemLength, kStemWidth, kStemLength + kStemWidth / 2)
                                                         xRadius:kStemWidth / 2 yRadius:kStemWidth / 2];
    NSAffineTransform *place = [NSAffineTransform transform];
    [place translateXBy:kStemTopX yBy:kStemTopY];
    [place rotateByDegrees:kStemTilt];
    [stem transformUsingAffineTransform:place];
    [shape appendBezierPath:stem];
    shape.windingRule = NSWindingRuleNonZero;
    [shape transformUsingAffineTransform:gridTo(box)];
    return shape;
}

NSArray<NSBezierPath *> *APBudMarkDots(NSRect box) {
    NSMutableArray *dots = [NSMutableArray array];
    for (int i = -1; i <= 1; i++) {
        NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(kHeadX + i * kDotGap - kDotR, kHeadY - kDotR, 2 * kDotR, 2 * kDotR)];
        [dot transformUsingAffineTransform:gridTo(box)];
        [dots addObject:dot];
    }
    return dots;
}

NSImage *APBudMarkMenuBarImage(void) {
    NSImage *image = [NSImage imageWithSize:NSMakeSize(18, 18) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        NSRect box = NSInsetRect(rect, .5, .5);
        [NSColor.blackColor setFill];
        [APBudMarkShape(box) fill];
        // Template images use alpha only: punch the dots out of the head.
        [NSGraphicsContext.currentContext setCompositingOperation:NSCompositingOperationDestinationOut];
        for (NSBezierPath *dot in APBudMarkDots(box)) [dot fill];
        return YES;
    }];
    image.template = YES;
    image.accessibilityDescription = @"BudDial";
    return image;
}
