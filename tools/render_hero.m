// Renders tools/hero.html at exact times, one PNG per frame, for docs/hero.gif. Run tools/make_hero_gif.sh.
// The page draws any moment from render(seconds); WebKit snapshots it at twice its size, offscreen.
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

@interface PageLoad : NSObject <WKNavigationDelegate>
@property BOOL finished;
@end
@implementation PageLoad
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation { (void)webView; (void)navigation; self.finished = YES; }
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    (void)webView; (void)navigation;
    fprintf(stderr, "page failed to load: %s\n", error.localizedDescription.UTF8String);
    exit(1);
}
@end

static void waitUntil(BOOL (^done)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
    while (!done()) {
        if (deadline.timeIntervalSinceNow < 0) { fprintf(stderr, "timed out waiting for WebKit\n"); exit(1); }
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
    }
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 6) { fprintf(stderr, "usage: render_hero <page.html> <frames dir> <fps> <seconds> <start seconds>\n"); return 1; }
    NSURL *page = [NSURL fileURLWithPath:@(argv[1])];
    NSString *frames = @(argv[2]);
    double fps = atof(argv[3]), seconds = atof(argv[4]), start = atof(argv[5]);
    [NSApplication sharedApplication];
    NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;

    NSRect bounds = NSMakeRect(0, 0, 1200, 675);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:bounds styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    WKWebView *web = [[WKWebView alloc] initWithFrame:bounds configuration:[WKWebViewConfiguration new]];
    window.contentView = web;
    [window setFrameOrigin:NSMakePoint(-6000, -6000)];
    [window orderFrontRegardless];

    PageLoad *load = [PageLoad new];
    web.navigationDelegate = load;
    NSURLComponents *url = [NSURLComponents componentsWithURL:page resolvingAgainstBaseURL:NO];
    url.query = @"frames";
    [web loadFileURL:url.URL allowingReadAccessToURL:page.URLByDeletingLastPathComponent];
    waitUntil(^{ return load.finished; });

    WKSnapshotConfiguration *snapshot = [WKSnapshotConfiguration new];
    snapshot.rect = bounds;
    snapshot.snapshotWidth = @(NSWidth(bounds) * 2);
    int count = (int)llround(seconds * fps);
    for (int i = 0; i < count; i++) {
        __block BOOL drawn = NO, saved = NO;
        NSString *script = [NSString stringWithFormat:@"render(%.4f)", start + i / fps];
        [web evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
            (void)result;
            if (error) { fprintf(stderr, "render failed: %s\n", error.localizedDescription.UTF8String); exit(1); }
            drawn = YES;
        }];
        waitUntil(^{ return drawn; });
        [web takeSnapshotWithConfiguration:snapshot completionHandler:^(NSImage *image, NSError *error) {
            if (!image) { fprintf(stderr, "snapshot failed: %s\n", error.localizedDescription.UTF8String); exit(1); }
            CGImageRef cg = [image CGImageForProposedRect:NULL context:nil hints:nil];
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cg];
            NSString *path = [frames stringByAppendingPathComponent:[NSString stringWithFormat:@"f%04d.png", i]];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:NO];
            saved = YES;
        }];
        waitUntil(^{ return saved; });
    }
    printf("%d frames\n", count);
}}
