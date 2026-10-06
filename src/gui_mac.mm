// MacInfo.app -- native AppKit window, no third party UI toolkit.
// Objective-C++ so it can call straight into src/sysinfo.cpp.

#import <AppKit/AppKit.h>

#include <cstdio>
#include <cstring>

#include "sysinfo.h"

static NSString *ReportText()
{
    return [NSString stringWithUTF8String:macinfo::report().c_str()];
}

@interface MacInfoAppDelegate : NSObject <NSApplicationDelegate>
@property(strong) NSWindow *window;
@end

@implementation MacInfoAppDelegate

- (void)installMainMenu:(NSApplication *)app
{
    NSMenu *mainMenu = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appItem];

    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"MacInfo"];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit MacInfo"
                                                  action:@selector(terminate:)
                                           keyEquivalent:@"q"];
    [appMenu addItem:quit];
    [appItem setSubmenu:appMenu];

    [app setMainMenu:mainMenu];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    NSApplication *app = [NSApplication sharedApplication];
    [self installMainMenu:app];

    const NSRect frame = NSMakeRect(0, 0, 460, 280);
    self.window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    [self.window setTitle:@"MacInfo"];

    NSView *content = [self.window contentView];

    NSTextField *heading = [NSTextField labelWithString:@"Built natively on Apple hardware"];
    [heading setFont:[NSFont systemFontOfSize:15 weight:NSFontWeightSemibold]];
    [heading setAlignment:NSTextAlignmentLeft];
    [heading setFrame:NSMakeRect(20, frame.size.height - 48, frame.size.width - 40, 22)];
    [content addSubview:heading];

    NSTextField *body = [NSTextField labelWithString:ReportText()];
    [body setFont:[NSFont userFixedPitchFontOfSize:12.0]];
    [body setLineBreakMode:NSLineBreakByCharWrapping];
    [body setMaximumNumberOfLines:0];
    [body setFrame:NSMakeRect(20, 62, frame.size.width - 40, frame.size.height - 130)];
    [content addSubview:body];

    NSButton *copy = [NSButton buttonWithTitle:@"Copy to clipboard"
                                        target:self
                                        action:@selector(copyReport:)];
    [copy setFrame:NSMakeRect(20, 18, 180, 32)];
    [content addSubview:copy];

    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [app activateIgnoringOtherApps:YES];
}

- (void)copyReport:(id)sender
{
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:ReportText() forType:NSPasteboardTypeString];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    return YES;
}

@end

int main(int argc, const char *argv[])
{
    // "--report" prints to stdout and exits: lets CI (which has no window server) smoke test the app binary.
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--report") == 0) {
            std::printf("%s", macinfo::report().c_str());
            return 0;
        }
    }

    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        MacInfoAppDelegate *delegate = [[MacInfoAppDelegate alloc] init];
        [app setDelegate:delegate];

        [app run];
    }
    return 0;
}
