#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "Core/MotionQuality.h"
#include "BrowserAgent/stream_bridge/BrowserStreamBridge.h"
#include "Metal/MotionMetalRuntime.h"
#include "Video/MotionOfflineProcessor.h"
#include "Video/MotionOnlineProcessor.h"
#include "Video/MotionVideoSource.h"

#include <cmath>

using namespace Stellaria::Motion;

@interface SMFlippedView : NSView
@end

@implementation SMFlippedView
- (BOOL)isFlipped {
    return YES;
}
@end

@interface SMBilibiliPageView : SMFlippedView
@property(copy) void (^layoutHandler)(SMBilibiliPageView* view);
@end

@implementation SMBilibiliPageView
- (void)layout {
    [super layout];
    if (self.layoutHandler != nil) {
        self.layoutHandler(self);
    }
}
@end

namespace {

constexpr CGFloat kSidebarWidth = 156.0;
constexpr CGFloat kOuterPadding = 14.0;
constexpr CGFloat kCardRadius = 14.0;
constexpr CGFloat kPanelRadius = 20.0;

NSColor* SMColor(CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha = 1.0) {
    return [NSColor colorWithSRGBRed:red green:green blue:blue alpha:alpha];
}

NSColor* SMInk() {
    return SMColor(0.94, 0.97, 1.0, 1.0);
}

NSColor* SMMuted() {
    return SMColor(0.70, 0.76, 0.84, 1.0);
}

NSString* SMFormatValue(double value, NSString* suffix, NSInteger precision) {
    if ([suffix isEqualToString:@"p"] || [suffix isEqualToString:@"fps"]) {
        return [NSString stringWithFormat:@"%.0f%@", value, suffix];
    }
    if ([suffix isEqualToString:@"x"]) {
        return [NSString stringWithFormat:@"%.1f%@", value, suffix];
    }
    return [NSString stringWithFormat:@"%.*f%@", static_cast<int>(precision), value, suffix];
}

NSString* SMFormatPlaybackTime(double seconds) {
    if (!std::isfinite(seconds) || seconds < 0.0) {
        return @"--:--";
    }
    const NSInteger total = static_cast<NSInteger>(llround(seconds));
    const NSInteger hours = total / 3600;
    const NSInteger minutes = (total / 60) % 60;
    const NSInteger secs = total % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", static_cast<long>(hours), static_cast<long>(minutes), static_cast<long>(secs)];
    }
    return [NSString stringWithFormat:@"%02ld:%02ld", static_cast<long>(minutes), static_cast<long>(secs)];
}

NSFont* SMFont(CGFloat size, NSFontWeight weight, BOOL rounded) {
    NSFont* base = [NSFont systemFontOfSize:size weight:weight];
    if (!rounded) {
        return base;
    }

    NSFontDescriptor* descriptor = [[base fontDescriptor] fontDescriptorWithDesign:NSFontDescriptorSystemDesignRounded];
    return descriptor != nil ? [NSFont fontWithDescriptor:descriptor size:size] : base;
}

NSTextField* SMLabel(NSString* text, CGFloat size, NSFontWeight weight, NSColor* color) {
    NSTextField* label = [NSTextField labelWithString:text];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = SMFont(size, weight, YES);
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.maximumNumberOfLines = 0;
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [label setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

NSTextField* SMCapsLabel(NSString* text) {
    NSTextField* label = SMLabel([text uppercaseString], 10, NSFontWeightSemibold, SMColor(0.58, 0.70, 0.84, 1.0));
    label.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightSemibold];
    return label;
}

NSButton* SMButton(NSString* title, NSButtonType type = NSButtonTypeMomentaryPushIn) {
    NSButton* button = [NSButton buttonWithTitle:title target:nil action:nil];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.buttonType = type;
    button.font = SMFont(12, NSFontWeightSemibold, YES);
    button.controlSize = NSControlSizeRegular;
    if (@available(macOS 26.0, *)) {
        button.bezelStyle = NSBezelStyleGlass;
    } else {
        button.bezelStyle = NSBezelStyleRounded;
    }
    return button;
}

NSStackView* SMVStack(CGFloat spacing) {
    NSStackView* stack = [NSStackView new];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.distribution = NSStackViewDistributionGravityAreas;
    stack.spacing = spacing;
    return stack;
}

NSStackView* SMHStack(CGFloat spacing) {
    NSStackView* stack = [NSStackView new];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = NSLayoutAttributeCenterY;
    stack.distribution = NSStackViewDistributionGravityAreas;
    stack.spacing = spacing;
    return stack;
}

void SMFill(NSView* child, NSView* parent, CGFloat inset = 0.0) {
    [NSLayoutConstraint activateConstraints:@[
        [child.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor constant:inset],
        [child.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor constant:-inset],
        [child.topAnchor constraintEqualToAnchor:parent.topAnchor constant:inset],
        [child.bottomAnchor constraintEqualToAnchor:parent.bottomAnchor constant:-inset],
    ]];
}

void SMSetFixedHeight(NSView* view, CGFloat height) {
    [view.heightAnchor constraintEqualToConstant:height].active = YES;
}

void SMSetMinHeight(NSView* view, CGFloat height) {
    [view.heightAnchor constraintGreaterThanOrEqualToConstant:height].active = YES;
}

void SMApplyChromeLayer(NSView* view, CGFloat radius, NSColor* border, CGFloat fillAlpha) {
    view.wantsLayer = YES;
    view.layer.cornerRadius = radius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.masksToBounds = YES;
    view.layer.borderWidth = 1.0;
    view.layer.borderColor = border.CGColor;
    if (fillAlpha > 0.0) {
        view.layer.backgroundColor = SMColor(0.06, 0.08, 0.11, fillAlpha).CGColor;
    }
}

struct SMGlassCard {
    NSView* view = nil;
    NSView* content = nil;
};

SMGlassCard SMGlass(BOOL prominent, CGFloat radius, NSColor* tint) {
    NSColor* resolvedTint = tint ?: SMColor(0.10, 0.13, 0.17, prominent ? 0.62 : 0.50);
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView* glass = [NSGlassEffectView new];
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        glass.cornerRadius = radius;
        glass.tintColor = resolvedTint;
        glass.style = prominent ? NSGlassEffectViewStyleRegular : NSGlassEffectViewStyleClear;
        glass.wantsLayer = YES;
        glass.layer.cornerRadius = radius;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        glass.layer.borderWidth = 1.0;
        glass.layer.borderColor = SMColor(0.75, 0.86, 1.0, prominent ? 0.18 : 0.10).CGColor;

        NSView* content = [NSView new];
        content.translatesAutoresizingMaskIntoConstraints = NO;
        glass.contentView = content;
        return {glass, content};
    }

    NSVisualEffectView* fallback = [NSVisualEffectView new];
    fallback.translatesAutoresizingMaskIntoConstraints = NO;
    fallback.material = prominent ? NSVisualEffectMaterialHUDWindow : NSVisualEffectMaterialMenu;
    fallback.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    fallback.state = NSVisualEffectStateActive;
    SMApplyChromeLayer(fallback, radius, SMColor(1.0, 1.0, 1.0, prominent ? 0.18 : 0.10), prominent ? 0.10 : 0.06);

    NSView* content = [NSView new];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [fallback addSubview:content];
    SMFill(content, fallback);
    return {fallback, content};
}

void SMInstallInCard(NSView* content, NSView* child, CGFloat inset) {
    [content addSubview:child];
    SMFill(child, content, inset);
}

NSView* SMDivider() {
    NSView* line = [NSView new];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.wantsLayer = YES;
    line.layer.backgroundColor = SMColor(1.0, 1.0, 1.0, 0.10).CGColor;
    [line.heightAnchor constraintEqualToConstant:1.0].active = YES;
    return line;
}

NSString* SMExtractJSONString(NSString* json, NSString* key) {
    NSString* needle = [NSString stringWithFormat:@"\"%@\"", key];
    NSRange keyRange = [json rangeOfString:needle];
    if (keyRange.location == NSNotFound) {
        return nil;
    }
    NSRange colonRange = [json rangeOfString:@":" options:0 range:NSMakeRange(NSMaxRange(keyRange), json.length - NSMaxRange(keyRange))];
    if (colonRange.location == NSNotFound) {
        return nil;
    }
    NSRange firstQuote = [json rangeOfString:@"\"" options:0 range:NSMakeRange(NSMaxRange(colonRange), json.length - NSMaxRange(colonRange))];
    if (firstQuote.location == NSNotFound) {
        return nil;
    }
    NSRange secondQuote = [json rangeOfString:@"\"" options:0 range:NSMakeRange(NSMaxRange(firstQuote), json.length - NSMaxRange(firstQuote))];
    if (secondQuote.location == NSNotFound) {
        return nil;
    }
    return [json substringWithRange:NSMakeRange(NSMaxRange(firstQuote), secondQuote.location - NSMaxRange(firstQuote))];
}

double SMExtractJSONNumber(NSString* json, NSString* key, double fallback) {
    NSString* needle = [NSString stringWithFormat:@"\"%@\"", key];
    NSRange keyRange = [json rangeOfString:needle];
    if (keyRange.location == NSNotFound) {
        return fallback;
    }
    NSRange colonRange = [json rangeOfString:@":" options:0 range:NSMakeRange(NSMaxRange(keyRange), json.length - NSMaxRange(keyRange))];
    if (colonRange.location == NSNotFound) {
        return fallback;
    }
    NSUInteger start = NSMaxRange(colonRange);
    while (start < json.length && [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[json characterAtIndex:start]]) {
        start++;
    }
    NSUInteger end = start;
    NSCharacterSet* allowed = [NSCharacterSet characterSetWithCharactersInString:@"-+.0123456789"];
    while (end < json.length && [allowed characterIsMember:[json characterAtIndex:end]]) {
        end++;
    }
    if (end <= start) {
        return fallback;
    }
    return [[json substringWithRange:NSMakeRange(start, end - start)] doubleValue];
}

bool SMExtractJSONBool(NSString* json, NSString* key, bool fallback) {
    NSString* needle = [NSString stringWithFormat:@"\"%@\"", key];
    NSRange keyRange = [json rangeOfString:needle];
    if (keyRange.location == NSNotFound) {
        return fallback;
    }
    NSRange colonRange = [json rangeOfString:@":" options:0 range:NSMakeRange(NSMaxRange(keyRange), json.length - NSMaxRange(keyRange))];
    if (colonRange.location == NSNotFound) {
        return fallback;
    }
    NSUInteger start = NSMaxRange(colonRange);
    while (start < json.length && [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[json characterAtIndex:start]]) {
        start++;
    }
    if (start + 4 <= json.length && [[json substringWithRange:NSMakeRange(start, 4)] isEqualToString:@"true"]) {
        return true;
    }
    if (start + 5 <= json.length && [[json substringWithRange:NSMakeRange(start, 5)] isEqualToString:@"false"]) {
        return false;
    }
    return fallback;
}

CGRect SMOverlayFrameFromBrowserRect(CGRect browserRect) {
    if (browserRect.size.width < 2.0 || browserRect.size.height < 2.0) {
        return CGRectZero;
    }

    NSScreen* mainScreen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    if (mainScreen == nil) {
        return browserRect;
    }

    const CGFloat cocoaY = NSMaxY(mainScreen.frame) - browserRect.origin.y - browserRect.size.height;
    CGRect frame = CGRectMake(browserRect.origin.x, cocoaY, browserRect.size.width, browserRect.size.height);
    for (NSScreen* screen in NSScreen.screens) {
        if (NSIntersectsRect(frame, screen.frame)) {
            return frame;
        }
    }
    return frame;
}

} // namespace

@interface SMValueSlider : NSSlider
@property(weak) NSTextField* valueLabel;
@property(copy) NSString* labelTitle;
@property(copy) NSString* suffix;
@property(assign) NSInteger precision;
- (void)refreshLabel;
@end

@implementation SMValueSlider
- (void)refreshLabel {
    self.valueLabel.stringValue = [NSString stringWithFormat:@"%@  %@", self.labelTitle, SMFormatValue(self.doubleValue, self.suffix ?: @"", self.precision)];
}
@end

@interface MotionAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property(strong) NSWindow* window;
@property(strong) NSView* sidebarView;
@property(strong) NSView* contentHost;
@property(strong) NSLayoutConstraint* contentLeadingNormalConstraint;
@property(strong) NSLayoutConstraint* contentLeadingFullscreenConstraint;
@property(strong) NSMutableArray<NSButton*>* navButtons;
@property(strong) AVPlayerView* playerView;
@property(strong) NSView* localPreviewView;
@property(strong) CAMetalLayer* localPreviewLayer;
@property(strong) NSLayoutConstraint* localPreviewAspectConstraint;
@property(strong) NSArray<NSLayoutConstraint*>* localPreviewConstraints;
@property(assign) double currentVideoAspect;
@property(strong) NSButton* playerPlayPauseButton;
@property(strong) AVPlayer* activePlayer;
@property(strong) NSButton* playerFullscreenButton;
@property(strong) NSSlider* playerSeekSlider;
@property(strong) NSTextField* playerCurrentTimeLabel;
@property(strong) NSTextField* playerDurationLabel;
@property(strong) NSSlider* playerVolumeSlider;
@property(strong) NSPopUpButton* playerSpeedPopup;
@property(strong) NSControl* playerLoopSwitch;
@property(strong) NSTimer* playerControlTimer;
@property(strong) id playerFullscreenEventMonitor;
@property(strong) id playerKeyboardEventMonitor;
@property(strong) NSWindow* playerFullscreenWindow;
@property(strong) NSView* playerFullscreenHost;
@property(strong) NSView* playerFullscreenControlsView;
@property(strong) NSSlider* playerFullscreenSeekSlider;
@property(strong) NSTextField* playerFullscreenCurrentTimeLabel;
@property(strong) NSTextField* playerFullscreenDurationLabel;
@property(strong) NSButton* playerFullscreenPlayPauseButton;
@property(strong) NSTimer* playerFullscreenControlsHideTimer;
@property(strong) id playerFullscreenMouseMoveMonitor;
@property(assign) BOOL playerVideoFullscreen;
@property(strong) NSTableView* playlistTableView;
@property(strong) NSMutableArray<NSString*>* playlistPaths;
@property(strong) NSTextField* bilibiliURLField;
@property(strong) NSTextField* bilibiliSearchField;
@property(strong) NSTextField* bilibiliStatusLabel;
@property(strong) NSTextField* bilibiliCookieLabel;
@property(strong) NSPopUpButton* bilibiliQualityPopup;
@property(strong) NSSegmentedControl* bilibiliSectionControl;
@property(strong) NSPopUpButton* bilibiliOrderPopup;
@property(strong) NSTableView* bilibiliTableView;
@property(strong) NSStackView* bilibiliGridStack;
@property(strong) NSView* bilibiliFrameGridContent;
@property(strong) NSMutableArray<NSDictionary<NSString*, id>*>* bilibiliItems;
@property(strong) NSButton* bilibiliImportButton;
@property(strong) NSTask* bilibiliImportTask;
@property(strong) NSString* bilibiliCookiePath;
@property(assign) NSInteger bilibiliSelectedIndex;
@property(assign) CGFloat bilibiliLastGridWidth;
@property(assign) BOOL bilibiliCacheActive;
@property(strong) NSString* bilibiliCacheActiveTitle;
@property(strong) NSString* bilibiliCacheActiveURL;
@property(strong) NSMutableSet<NSPanel*>* bilibiliDetailPanels;
@property(strong) NSTextField* importedFileLabel;
@property(strong) NSTextField* previewStatusLabel;
@property(strong) NSProgressIndicator* exportProgress;
@property(strong) NSTextField* exportStatusLabel;
@property(strong) NSPopUpButton* upscalePopup;
@property(strong) SMValueSlider* offlineTargetFpsSlider;
@property(strong) NSTimer* exportTimer;
@property(strong) AVAssetExportSession* exportSession;
@property(strong) SMMotionOfflineProcessor* offlineProcessor;
@property(strong) SMMotionOfflineProcessor* previewProcessor;
@property(strong) SMMotionOnlineProcessor* onlineProcessor;
@property(strong) SMBrowserStreamBridge* browserStreamBridge;
@property(strong) NSURL* exportURL;
@property(strong) NSString* importedPath;
@property(strong) NSString* metalDeviceName;
@property(strong) NSString* metalFeatureSummary;
@property(strong) NSTextField* effectiveModeLabel;
@property(strong) NSSegmentedControl* interpolationModeControl;
@property(strong) NSPopUpButton* realtimeFpsPopup;
@property(strong) SMValueSlider* targetFpsSlider;
@property(strong) SMValueSlider* frameMultiplierSlider;
@property(strong) SMValueSlider* flowHeightSlider;
@property(strong) SMValueSlider* gpuBudgetSlider;
@property(strong) SMValueSlider* browserReturnBitrateSlider;
@property(strong) NSTextField* realtimeTierHintLabel;
@property(strong) NSTextField* browserReturnBitrateHintLabel;
@property(strong) SMValueSlider* refineStrengthSlider;
@property(strong) NSPopUpButton* presetPopup;
@property(strong) NSPopUpButton* powerTierPopup;
@property(strong) NSPopUpButton* modelPopup;
@property(strong) NSControl* lineArtSwitch;
@property(strong) NSControl* subtitleSwitch;
@property(strong) NSControl* edgeAwareSwitch;
@property(strong) NSControl* noReadbackSwitch;
@property(strong) NSControl* diagnosticOverlaySwitch;
@property(strong) NSControl* hevcMotionHintsSwitch;
@property(strong) NSControl* roiMotionBlocksSwitch;
@property(strong) NSControl* dynamicMultiFrameSwitch;
@property(assign) BOOL suppressSettingsSave;
@property(strong) NSTextField* diagStatusLabel;
@property(strong) NSTextField* diagFrameRateLabel;
@property(strong) NSTextField* diagOutputLabel;
@property(strong) NSTextField* diagKernelLabel;
@property(strong) NSTextField* diagQueueLabel;
@property(strong) NSTextField* diagFrameLabel;
@property(strong) NSTextField* browserAgentLabel;
@property(strong) NSTextField* browserSourceLabel;
@property(strong) NSTextField* browserRectLabel;
@property(strong) NSTextField* browserModeLabel;
@property(strong) NSTextField* browserStatusHintLabel;
@property(strong) NSTextField* browserReadyLabel;
@property(strong) NSTextField* browserVideoSizeLabel;
@property(strong) NSTextField* browserDriftLabel;
@property(strong) NSTextField* browserPipelineLabel;
@property(strong) NSTextField* browserQueueLabel;
@property(strong) NSTextField* browserProtectionLabel;
@property(strong) NSTextField* browserAgentStatusLabel;
@property(strong) NSTextField* browserCaptureStatusLabel;
@property(strong) NSTextField* browserPolicyStatusLabel;
@property(strong) NSControl* browserEnableSwitch;
@property(strong) NSButton* browserStartButton;
@property(strong) NSButton* browserStopButton;
@property(strong) NSButton* screenPermissionButton;
@property(strong) NSPanel* browserOverlayPanel;
@property(strong) NSView* browserOverlayView;
@property(strong) CAMetalLayer* browserOverlayLayer;
@property(strong) NSTimer* browserStateTimer;
@property(assign) BOOL browserOnlineRequested;
- (NSString*)currentRIFEBackendIdentifier;
- (uint32_t)effectiveRealtimeFlowHeight;
- (double)effectiveRealtimeGpuBudgetMs;
@end

@implementation MotionAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    (void)notification;

    auto runtime = Stellaria::Motion::Metal::Runtime();
    self.metalDeviceName = [NSString stringWithFormat:@"%s", runtime.DeviceName().c_str()];
    self.metalFeatureSummary = [NSString stringWithFormat:@"%s", runtime.FeatureSummary().c_str()];
    self.navButtons = [NSMutableArray array];
    self.currentVideoAspect = 16.0 / 9.0;
    self.bilibiliSelectedIndex = -1;
    [self registerDefaultSettings];
    [self loadPlaylistFromDefaults];
    [self writeRuntimeSettingsSnapshot];
    NSURL* iconURL = [NSBundle.mainBundle URLForResource:@"StellariaMotion" withExtension:@"icns"];
    NSImage* appIcon = iconURL != nil ? [[NSImage alloc] initWithContentsOfURL:iconURL] : nil;
    if (appIcon != nil) {
        [NSApp setApplicationIconImage:appIcon];
    }

    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 860, 620)
                                              styleMask:NSWindowStyleMaskTitled |
                                                        NSWindowStyleMaskClosable |
                                                        NSWindowStyleMaskMiniaturizable |
                                                        NSWindowStyleMaskResizable |
                                                        NSWindowStyleMaskFullSizeContentView
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"Stellaria Motion";
    self.window.titlebarAppearsTransparent = YES;
    self.window.toolbarStyle = NSWindowToolbarStyleUnifiedCompact;
    self.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    self.window.delegate = self;
    self.window.minSize = NSMakeSize(600, 460);
    [self.window center];

    NSView* root = [NSView new];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    root.wantsLayer = YES;
    root.layer.backgroundColor = SMColor(0.095, 0.105, 0.125, 0.96).CGColor;
    [self.window setContentView:root];

    [self installAtmosphereInRoot:root];

    NSView* sidebar = [self buildSidebar];
    self.sidebarView = sidebar;
    self.contentHost = [NSView new];
    self.contentHost.translatesAutoresizingMaskIntoConstraints = NO;

    [root addSubview:sidebar];
    [root addSubview:self.contentHost];

    self.contentLeadingNormalConstraint = [self.contentHost.leadingAnchor constraintEqualToAnchor:sidebar.trailingAnchor constant:kOuterPadding];
    self.contentLeadingFullscreenConstraint = [self.contentHost.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:kOuterPadding];
    self.contentLeadingFullscreenConstraint.active = NO;
    [NSLayoutConstraint activateConstraints:@[
        [sidebar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:kOuterPadding],
        [sidebar.topAnchor constraintEqualToAnchor:root.topAnchor constant:42],
        [sidebar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-kOuterPadding],
        [sidebar.widthAnchor constraintEqualToConstant:kSidebarWidth],

        self.contentLeadingNormalConstraint,
        [self.contentHost.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-kOuterPadding],
        [self.contentHost.topAnchor constraintEqualToAnchor:root.topAnchor constant:42],
        [self.contentHost.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-kOuterPadding],
    ]];

    [self selectSection:0];
    self.browserStateTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                              target:self
                                                            selector:@selector(refreshBrowserState:)
                                                            userInfo:nil
                                                             repeats:YES];
    [self installPlayerKeyboardMonitor];
    [self startBrowserStreamBridge];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)installAtmosphereInRoot:(NSView*)root {
    (void)root;
}

- (NSView*)buildSidebar {
    SMGlassCard card = SMGlass(YES, kPanelRadius, nil);

    NSStackView* stack = SMVStack(14);
    SMInstallInCard(card.content, stack, 14);

    NSTextField* appTitle = SMLabel(@"Stellaria Motion", 18, NSFontWeightSemibold, SMInk());
    NSTextField* subtitle = SMCapsLabel(@"Video Interpolation Runtime");
    [stack addArrangedSubview:appTitle];
    [stack addArrangedSubview:subtitle];

    NSStackView* statusMini = SMHStack(8);
    [stack addArrangedSubview:statusMini];
    [statusMini addArrangedSubview:[self smallDot:SMColor(0.25, 0.95, 0.78, 1.0)]];
    [statusMini addArrangedSubview:SMLabel(@"增强可用", 12, NSFontWeightMedium, SMMuted())];

    [stack addArrangedSubview:SMDivider()];

    [stack addArrangedSubview:[self navButton:@"播放器" subtitle:@"Local realtime VFI" index:0]];
    [stack addArrangedSubview:[self navButton:@"B站" subtitle:@"Browse / cache" index:1]];
    [stack addArrangedSubview:[self navButton:@"离线导出" subtitle:@"Export / batch" index:2]];
    [stack addArrangedSubview:[self navButton:@"设置" subtitle:@"Runtime / browser" index:3]];

    NSView* flexible = [NSView new];
    flexible.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:flexible];
    [flexible.heightAnchor constraintGreaterThanOrEqualToConstant:96].active = YES;

    SMGlassCard status = SMGlass(NO, 16, nil);
    [stack addArrangedSubview:status.view];
    [status.view.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    SMSetFixedHeight(status.view, 112);

    NSStackView* statusStack = SMVStack(7);
    SMInstallInCard(status.content, statusStack, 12);
    [statusStack addArrangedSubview:SMCapsLabel(@"Runtime")];
    [statusStack addArrangedSubview:SMLabel([NSString stringWithFormat:@"本机加速 · %@", self.metalDeviceName], 12, NSFontWeightSemibold, SMInk())];
    NSTextField* featureLine = SMLabel(self.metalFeatureSummary ?: @"Metal feature probe pending", 10, NSFontWeightRegular, SMMuted());
    featureLine.maximumNumberOfLines = 2;
    [statusStack addArrangedSubview:featureLine];

    return card.view;
}

- (NSView*)smallDot:(NSColor*)color {
    NSView* dot = [NSView new];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.wantsLayer = YES;
    dot.layer.backgroundColor = color.CGColor;
    dot.layer.cornerRadius = 4.5;
    [dot.widthAnchor constraintEqualToConstant:9].active = YES;
    [dot.heightAnchor constraintEqualToConstant:9].active = YES;
    return dot;
}

- (NSButton*)navButton:(NSString*)title subtitle:(NSString*)subtitle index:(NSInteger)index {
    NSButton* button = [NSButton buttonWithTitle:[NSString stringWithFormat:@"%@\n%@", title, subtitle] target:self action:@selector(handleNav:)];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.tag = index;
    button.bordered = NO;
    button.alignment = NSTextAlignmentLeft;
    button.font = SMFont(12, NSFontWeightSemibold, YES);
    button.contentTintColor = SMInk();
    button.wantsLayer = YES;
    button.layer.cornerRadius = 12.0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    [button.heightAnchor constraintEqualToConstant:38].active = YES;
    [button.widthAnchor constraintEqualToConstant:kSidebarWidth - 28].active = YES;
    [self.navButtons addObject:button];
    return button;
}

- (void)handleNav:(NSButton*)sender {
    [self selectSection:sender.tag];
}

- (void)selectSection:(NSInteger)section {
    for (NSButton* button in self.navButtons) {
        const BOOL selected = button.tag == section;
        button.layer.backgroundColor = selected ? SMColor(0.18, 0.30, 0.46, 0.44).CGColor : NSColor.clearColor.CGColor;
        button.layer.borderColor = selected ? SMColor(0.60, 0.74, 0.90, 0.26).CGColor : NSColor.clearColor.CGColor;
        button.layer.borderWidth = selected ? 1.0 : 0.0;
        button.layer.shadowOpacity = selected ? 0.05 : 0.0;
        button.layer.shadowColor = SMColor(0.22, 0.70, 1.0, 1.0).CGColor;
        button.layer.shadowRadius = 10.0;
    }

    for (NSView* subview in self.contentHost.subviews.copy) {
        [subview removeFromSuperview];
    }

    NSView* page = nil;
    if (section == 0) {
        page = [self buildPlayerPage];
    } else if (section == 1) {
        page = [self buildBilibiliPage];
    } else if (section == 2) {
        page = [self buildExportPage];
    } else {
        page = [self buildSettingsPage];
    }
    [self.contentHost addSubview:page];
    SMFill(page, self.contentHost, 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSView* first = page.subviews.firstObject;
        if ([first isKindOfClass:NSScrollView.class]) {
            NSScrollView* scroll = (NSScrollView*)first;
            [scroll.contentView scrollToPoint:NSMakePoint(0.0, 0.0)];
            [scroll reflectScrolledClipView:scroll.contentView];
        }
    });
}

- (NSStackView*)pageStackInPage:(NSView*)page {
    NSView* first = page.subviews.firstObject;
    if ([first isKindOfClass:NSScrollView.class]) {
        NSView* document = ((NSScrollView*)first).documentView;
        return (NSStackView*)document.subviews.firstObject;
    }
    return (NSStackView*)first;
}

- (NSView*)pageShellWithTitle:(NSString*)title subtitle:(NSString*)subtitle telemetry:(NSArray<NSString*>*)telemetry {
    NSView* page = [NSView new];
    page.translatesAutoresizingMaskIntoConstraints = NO;

    NSScrollView* scroll = [NSScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    [page addSubview:scroll];
    SMFill(scroll, page, 0);

    NSView* document = [SMFlippedView new];
    document.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = document;

    NSStackView* stack = SMVStack(14);
    [document addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:document.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:document.trailingAnchor constant:-10.0],
        [stack.topAnchor constraintEqualToAnchor:document.topAnchor constant:14.0],
        [stack.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-18.0],
    ]];
    [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor].active = YES;

    NSStackView* hero = SMVStack(10);
    [stack addArrangedSubview:hero];
    [hero.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;

    NSStackView* text = SMVStack(6);
    [hero addArrangedSubview:text];
    [text setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [text addArrangedSubview:SMCapsLabel(@"Stellaria Motion")];
    [text addArrangedSubview:SMLabel(title, 25, NSFontWeightSemibold, SMInk())];
    NSTextField* subtitleLabel = SMLabel(subtitle, 12, NSFontWeightRegular, SMMuted());
    subtitleLabel.maximumNumberOfLines = 2;
    [text addArrangedSubview:subtitleLabel];

    if (telemetry.count > 0) {
        NSStackView* metrics = SMVStack(8);
        [hero addArrangedSubview:metrics];
        [metrics setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [metrics setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        for (NSString* item in telemetry) {
            NSArray<NSString*>* parts = [item componentsSeparatedByString:@"|"];
            NSView* pill = [self metricPill:parts.firstObject ?: @"" value:parts.count > 1 ? parts[1] : @""];
            [metrics addArrangedSubview:pill];
            [pill.widthAnchor constraintEqualToAnchor:metrics.widthAnchor].active = YES;
        }
    }

    return page;
}

- (NSView*)metricPill:(NSString*)label value:(NSString*)value {
    SMGlassCard pill = SMGlass(NO, 12, nil);
    NSStackView* stack = SMVStack(2);
    SMInstallInCard(pill.content, stack, 9);
    [stack addArrangedSubview:SMCapsLabel(label)];
    [stack addArrangedSubview:SMLabel(value, 12, NSFontWeightSemibold, SMInk())];
    SMSetFixedHeight(pill.view, 44);
    return pill.view;
}

- (NSView*)buildPlayerPage {
    NSView* page = [self pageShellWithTitle:@"Stellaria Player"
                                   subtitle:@"本地视频与 B 站缓存播放共用同一条低延迟实时插帧链路；播放阶段不经过浏览器回推。"
                                  telemetry:@[]];
    NSStackView* stack = [self pageStackInPage:page];
    if (stack.arrangedSubviews.count > 0) {
        NSView* hero = stack.arrangedSubviews.firstObject;
        [stack removeArrangedSubview:hero];
        [hero removeFromSuperview];
    }

    NSStackView* playerLayout = SMHStack(14);
    playerLayout.alignment = NSLayoutAttributeTop;
    [stack addArrangedSubview:playerLayout];
    [playerLayout.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;

    SMGlassCard previewCard = SMGlass(YES, kPanelRadius, nil);
    [playerLayout addArrangedSubview:previewCard.view];
    [previewCard.view.widthAnchor constraintGreaterThanOrEqualToConstant:520].active = YES;
    SMSetMinHeight(previewCard.view, 560);

    NSStackView* previewStack = SMVStack(10);
    SMInstallInCard(previewCard.content, previewStack, 14);

    NSStackView* header = SMHStack(12);
    [previewStack addArrangedSubview:header];
    [header.widthAnchor constraintEqualToAnchor:previewStack.widthAnchor].active = YES;
    [header addArrangedSubview:SMLabel(@"正在播放", 16, NSFontWeightSemibold, SMInk())];
    NSView* spacer = [NSView new];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [header addArrangedSubview:spacer];
    self.previewStatusLabel = SMLabel(@"等待导入视频", 12, NSFontWeightMedium, SMMuted());
    [header addArrangedSubview:self.previewStatusLabel];
    NSButton* importButton = SMButton(@"打开文件");
    importButton.target = self;
    importButton.action = @selector(importVideo:);
    [header addArrangedSubview:importButton];
    self.playerFullscreenButton = SMButton(@"全屏");
    self.playerFullscreenButton.target = self;
    self.playerFullscreenButton.action = @selector(togglePlayerFullscreen:);
    [header addArrangedSubview:self.playerFullscreenButton];

    NSStackView* previewBody = SMVStack(12);
    [previewStack addArrangedSubview:previewBody];
    [previewBody.widthAnchor constraintEqualToAnchor:previewStack.widthAnchor].active = YES;

    self.playerView = [AVPlayerView new];
    self.playerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.playerView.controlsStyle = AVPlayerViewControlsStyleNone;
    SMApplyChromeLayer(self.playerView, 10, SMColor(0.7, 0.9, 1.0, 0.12), 0.92);
    [previewBody addArrangedSubview:self.playerView];
    [self.playerView.heightAnchor constraintEqualToAnchor:self.playerView.widthAnchor multiplier:9.0 / 16.0].active = YES;
    [self.playerView.heightAnchor constraintGreaterThanOrEqualToConstant:320].active = YES;
    [self installLocalPreviewLayerInPlayerView];
    if (self.activePlayer != nil) {
        self.playerView.player = self.activePlayer;
    }

    NSView* controls = [self buildPlayerControlsCard];
    [previewBody addArrangedSubview:controls];
    [controls.widthAnchor constraintEqualToAnchor:previewBody.widthAnchor].active = YES;
    SMSetMinHeight(controls, 96);

    SMGlassCard diagnostics = SMGlass(NO, 16, nil);
    [previewBody addArrangedSubview:diagnostics.view];
    [diagnostics.view.widthAnchor constraintEqualToAnchor:previewBody.widthAnchor].active = YES;
    SMSetMinHeight(diagnostics.view, 116);
    [self.playerView.widthAnchor constraintEqualToAnchor:previewBody.widthAnchor].active = YES;

    NSStackView* diagStack = SMVStack(9);
    SMInstallInCard(diagnostics.content, diagStack, 14);
    [diagStack addArrangedSubview:SMCapsLabel(@"Status")];
    [diagStack addArrangedSubview:SMLabel(@"播放信息", 15, NSFontWeightSemibold, SMInk())];
    self.diagStatusLabel = [self diagnosticLine:@"状态" value:@"Idle"];
    self.diagFrameRateLabel = [self diagnosticLine:@"模式" value:@"增强播放"];
    self.diagOutputLabel = [self diagnosticLine:@"输出" value:@"--"];
    self.diagKernelLabel = [self diagnosticLine:@"音量" value:@"100%"];
    self.diagQueueLabel = [self diagnosticLine:@"倍速" value:@"1.00x"];
    self.diagFrameLabel = [self diagnosticLine:@"循环" value:@"关闭"];
    [diagStack addArrangedSubview:self.diagStatusLabel];
    [diagStack addArrangedSubview:self.diagFrameRateLabel];
    [diagStack addArrangedSubview:self.diagOutputLabel];
    [diagStack addArrangedSubview:self.diagKernelLabel];
    [diagStack addArrangedSubview:self.diagQueueLabel];
    [diagStack addArrangedSubview:self.diagFrameLabel];

    NSView* playlistCard = [self buildPlaylistCard];
    [playerLayout addArrangedSubview:playlistCard];
    [playlistCard.widthAnchor constraintEqualToConstant:320].active = YES;
    [playlistCard.heightAnchor constraintEqualToAnchor:previewCard.view.heightAnchor].active = YES;

    return page;
}

- (void)installLocalPreviewLayerInPlayerView {
    if (self.playerView == nil) {
        return;
    }

    NSView* host = self.playerView.contentOverlayView ?: self.playerView;
    [self attachLocalPreviewViewToHost:host hidden:self.localPreviewView != nil ? self.localPreviewView.hidden : YES];
}

- (void)ensureLocalPreviewView {
    if (self.localPreviewView == nil) {
        self.localPreviewView = [NSView new];
        self.localPreviewView.translatesAutoresizingMaskIntoConstraints = NO;
        self.localPreviewView.wantsLayer = YES;
        self.localPreviewLayer = [CAMetalLayer layer];
        self.localPreviewLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        self.localPreviewLayer.framebufferOnly = NO;
        self.localPreviewLayer.opaque = YES;
        self.localPreviewLayer.backgroundColor = NSColor.blackColor.CGColor;
        self.localPreviewLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        self.localPreviewView.layer = self.localPreviewLayer;
    }
}

- (void)attachLocalPreviewViewToHost:(NSView*)host hidden:(BOOL)hidden {
    if (host == nil) {
        return;
    }
    [self ensureLocalPreviewView];
    [NSLayoutConstraint deactivateConstraints:self.localPreviewConstraints ?: @[]];
    self.localPreviewConstraints = @[];
    if (self.localPreviewView.superview != nil) {
        [self.localPreviewView removeFromSuperview];
    }
    self.localPreviewView.hidden = hidden;

    [host addSubview:self.localPreviewView positioned:NSWindowAbove relativeTo:nil];
    const double aspect = self.currentVideoAspect > 0.01 ? self.currentVideoAspect : 16.0 / 9.0;
    self.localPreviewAspectConstraint = [self.localPreviewView.widthAnchor constraintEqualToAnchor:self.localPreviewView.heightAnchor multiplier:aspect];
    self.localPreviewAspectConstraint.priority = NSLayoutPriorityRequired;
    NSLayoutConstraint* fillWidth = [self.localPreviewView.widthAnchor constraintEqualToAnchor:host.widthAnchor];
    fillWidth.priority = NSLayoutPriorityDefaultHigh;
    NSLayoutConstraint* fillHeight = [self.localPreviewView.heightAnchor constraintEqualToAnchor:host.heightAnchor];
    fillHeight.priority = NSLayoutPriorityDefaultHigh - 1;
    self.localPreviewConstraints = @[
        [self.localPreviewView.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
        [self.localPreviewView.centerYAnchor constraintEqualToAnchor:host.centerYAnchor],
        [self.localPreviewView.widthAnchor constraintLessThanOrEqualToAnchor:host.widthAnchor],
        [self.localPreviewView.heightAnchor constraintLessThanOrEqualToAnchor:host.heightAnchor],
        self.localPreviewAspectConstraint,
        fillWidth,
        fillHeight,
    ];
    [NSLayoutConstraint activateConstraints:self.localPreviewConstraints];
    [host layoutSubtreeIfNeeded];
}

- (void)updateLocalPreviewAspectWidth:(CGFloat)width height:(CGFloat)height {
    if (width <= 0.0 || height <= 0.0) {
        return;
    }
    self.currentVideoAspect = width / height;
    NSView* host = self.localPreviewView.superview;
    if (host == nil) {
        return;
    }
    [self attachLocalPreviewViewToHost:host hidden:self.localPreviewView.hidden];
}

- (NSView*)buildPlayerControlsCard {
    SMGlassCard card = SMGlass(NO, 16, nil);
    NSStackView* stack = SMVStack(10);
    SMInstallInCard(card.content, stack, 14);

    NSStackView* seekRow = SMHStack(10);
    [stack addArrangedSubview:seekRow];
    [seekRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    self.playerCurrentTimeLabel = SMLabel(@"00:00", 11, NSFontWeightMedium, SMMuted());
    self.playerCurrentTimeLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
    [seekRow addArrangedSubview:self.playerCurrentTimeLabel];
    [self.playerCurrentTimeLabel.widthAnchor constraintEqualToConstant:46].active = YES;

    self.playerSeekSlider = [NSSlider sliderWithValue:0.0 minValue:0.0 maxValue:1.0 target:self action:@selector(playerSeekChanged:)];
    self.playerSeekSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.playerSeekSlider.continuous = YES;
    [seekRow addArrangedSubview:self.playerSeekSlider];
    [self.playerSeekSlider.widthAnchor constraintGreaterThanOrEqualToConstant:260].active = YES;

    self.playerDurationLabel = SMLabel(@"--:--", 11, NSFontWeightMedium, SMMuted());
    self.playerDurationLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
    [seekRow addArrangedSubview:self.playerDurationLabel];
    [self.playerDurationLabel.widthAnchor constraintEqualToConstant:46].active = YES;

    NSStackView* controlRow = SMHStack(10);
    [stack addArrangedSubview:controlRow];
    [controlRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;

    NSButton* backButton = SMButton(@"-10s");
    backButton.target = self;
    backButton.action = @selector(playerSkipBackward:);
    [controlRow addArrangedSubview:backButton];

    self.playerPlayPauseButton = SMButton(@"播放");
    self.playerPlayPauseButton.target = self;
    self.playerPlayPauseButton.action = @selector(playerTogglePlayPause:);
    [controlRow addArrangedSubview:self.playerPlayPauseButton];

    NSButton* forwardButton = SMButton(@"+10s");
    forwardButton.target = self;
    forwardButton.action = @selector(playerSkipForward:);
    [controlRow addArrangedSubview:forwardButton];

    NSView* spacer = [NSView new];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [controlRow addArrangedSubview:spacer];

    [controlRow addArrangedSubview:SMLabel(@"音量", 11, NSFontWeightMedium, SMMuted())];
    self.playerVolumeSlider = [NSSlider sliderWithValue:1.0 minValue:0.0 maxValue:1.0 target:self action:@selector(playerVolumeChanged:)];
    self.playerVolumeSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.playerVolumeSlider.continuous = YES;
    [controlRow addArrangedSubview:self.playerVolumeSlider];
    [self.playerVolumeSlider.widthAnchor constraintEqualToConstant:110].active = YES;

    self.playerSpeedPopup = [NSPopUpButton new];
    self.playerSpeedPopup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.playerSpeedPopup addItemsWithTitles:@[@"0.5x", @"0.75x", @"1.0x", @"1.25x", @"1.5x", @"2.0x"]];
    self.playerSpeedPopup.target = self;
    [self.playerSpeedPopup selectItemAtIndex:2];
    self.playerSpeedPopup.action = @selector(playerSpeedChanged:);
    [controlRow addArrangedSubview:self.playerSpeedPopup];
    [self.playerSpeedPopup.widthAnchor constraintEqualToConstant:84].active = YES;

    NSStackView* loopRow = SMHStack(6);
    [loopRow addArrangedSubview:SMLabel(@"循环", 11, NSFontWeightMedium, SMMuted())];
    if (@available(macOS 10.15, *)) {
        NSSwitch* loopSwitch = [NSSwitch new];
        loopSwitch.translatesAutoresizingMaskIntoConstraints = NO;
        loopSwitch.state = NSControlStateValueOff;
        [loopRow addArrangedSubview:loopSwitch];
        self.playerLoopSwitch = loopSwitch;
    } else {
        NSButton* loopSwitch = SMButton(@"", NSButtonTypeSwitch);
        loopSwitch.state = NSControlStateValueOff;
        [loopRow addArrangedSubview:loopSwitch];
        self.playerLoopSwitch = loopSwitch;
    }
    [controlRow addArrangedSubview:loopRow];
    self.playerLoopSwitch.target = self;
    self.playerLoopSwitch.action = @selector(playerLoopChanged:);
    [self startPlayerControlTimerIfNeeded];
    return card.view;
}

- (AVPlayer*)currentPlayer {
    return self.playerView.player ?: self.activePlayer;
}

- (double)selectedPlayerRate {
    NSString* title = self.playerSpeedPopup.titleOfSelectedItem ?: @"1.0x";
    return MAX(0.25, MIN(4.0, title.doubleValue));
}

- (double)currentPlayerDurationSeconds {
    AVPlayerItem* item = [self currentPlayer].currentItem;
    if (item == nil || !CMTIME_IS_NUMERIC(item.duration)) {
        return 0.0;
    }
    const double duration = CMTimeGetSeconds(item.duration);
    return std::isfinite(duration) && duration > 0.0 ? duration : 0.0;
}

- (void)startPlayerControlTimerIfNeeded {
    if (self.playerControlTimer != nil) {
        return;
    }
    self.playerControlTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                               target:self
                                                             selector:@selector(refreshPlayerControls:)
                                                             userInfo:nil
                                                              repeats:YES];
}

- (void)refreshPlayerControls:(NSTimer*)timer {
    (void)timer;
    AVPlayer* player = [self currentPlayer];
    const double duration = [self currentPlayerDurationSeconds];
    const double current = player != nil && CMTIME_IS_NUMERIC(player.currentTime)
        ? CMTimeGetSeconds(player.currentTime)
        : 0.0;
    const BOOL hasMedia = player.currentItem != nil && duration > 0.0;

    self.playerSeekSlider.enabled = hasMedia;
    self.playerSeekSlider.maxValue = hasMedia ? duration : 1.0;
    if (hasMedia) {
        self.playerSeekSlider.doubleValue = MIN(MAX(current, 0.0), duration);
    }
    self.playerCurrentTimeLabel.stringValue = SMFormatPlaybackTime(hasMedia ? current : 0.0);
    self.playerDurationLabel.stringValue = hasMedia ? SMFormatPlaybackTime(duration) : @"--:--";
    if (self.playerFullscreenCurrentTimeLabel != nil) {
        self.playerFullscreenCurrentTimeLabel.stringValue = self.playerCurrentTimeLabel.stringValue;
    }
    if (self.playerFullscreenDurationLabel != nil) {
        self.playerFullscreenDurationLabel.stringValue = self.playerDurationLabel.stringValue;
    }
    if (self.playerFullscreenSeekSlider != nil) {
        self.playerFullscreenSeekSlider.enabled = hasMedia;
        self.playerFullscreenSeekSlider.maxValue = hasMedia ? duration : 1.0;
        if (hasMedia) {
            self.playerFullscreenSeekSlider.doubleValue = MIN(MAX(current, 0.0), duration);
        }
    }

    const BOOL playing = player.rate > 0.001;
    self.playerPlayPauseButton.title = playing ? @"暂停" : @"播放";
    self.playerFullscreenPlayPauseButton.title = playing ? @"暂停" : @"播放";
    self.playerPlayPauseButton.enabled = hasMedia;
    self.playerSpeedPopup.enabled = hasMedia;
    self.playerVolumeSlider.enabled = player != nil;
    self.playerVolumeSlider.doubleValue = player != nil ? player.volume : self.playerVolumeSlider.doubleValue;

    if (hasMedia && current >= duration - 0.10 && [self stateOfControl:self.playerLoopSwitch fallback:NO]) {
        [player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
        player.rate = [self selectedPlayerRate];
    }
}

- (void)playerTogglePlayPause:(id)sender {
    (void)sender;
    AVPlayer* player = [self currentPlayer];
    if (self.importedPath.length > 0 && !self.onlineProcessor.isRunning) {
        [self playPreview:nil];
        return;
    }
    if (player == nil || player.currentItem == nil) {
        return;
    }
    if (player.rate > 0.001) {
        [player pause];
    } else {
        player.rate = [self selectedPlayerRate];
    }
    [self refreshPlayerControls:nil];
    [self showPlayerFullscreenControlsAndScheduleHide];
}

- (void)playerSeekChanged:(NSSlider*)sender {
    AVPlayer* player = [self currentPlayer];
    if (player == nil || player.currentItem == nil) {
        return;
    }
    CMTime target = CMTimeMakeWithSeconds(sender.doubleValue, 600);
    [player seekToTime:target toleranceBefore:CMTimeMakeWithSeconds(0.05, 600) toleranceAfter:CMTimeMakeWithSeconds(0.05, 600)];
}

- (void)playerFullscreenSeekChanged:(NSSlider*)sender {
    [self playerSeekChanged:sender];
}

- (void)playerSkipBySeconds:(double)seconds {
    AVPlayer* player = [self currentPlayer];
    const double duration = [self currentPlayerDurationSeconds];
    if (player == nil || player.currentItem == nil || duration <= 0.0) {
        return;
    }
    const double current = CMTIME_IS_NUMERIC(player.currentTime) ? CMTimeGetSeconds(player.currentTime) : 0.0;
    const double targetSeconds = MIN(MAX(current + seconds, 0.0), duration);
    [player seekToTime:CMTimeMakeWithSeconds(targetSeconds, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    [self showPlayerFullscreenControlsAndScheduleHide];
}

- (void)playerSkipBackward:(id)sender {
    (void)sender;
    [self playerSkipBySeconds:-10.0];
}

- (void)playerSkipForward:(id)sender {
    (void)sender;
    [self playerSkipBySeconds:10.0];
}

- (void)playerVolumeChanged:(NSSlider*)sender {
    [self currentPlayer].volume = static_cast<float>(sender.doubleValue);
    self.diagKernelLabel.stringValue = [NSString stringWithFormat:@"音量  %.0f%%", sender.doubleValue * 100.0];
}

- (void)playerSpeedChanged:(NSPopUpButton*)sender {
    (void)sender;
    AVPlayer* player = [self currentPlayer];
    if (player.rate > 0.001) {
        player.rate = [self selectedPlayerRate];
    }
    self.diagQueueLabel.stringValue = [NSString stringWithFormat:@"倍速  %@", self.playerSpeedPopup.titleOfSelectedItem ?: @"1.0x"];
}

- (void)playerLoopChanged:(id)sender {
    (void)sender;
    self.diagFrameLabel.stringValue = [NSString stringWithFormat:@"循环  %@", [self stateOfControl:self.playerLoopSwitch fallback:NO] ? @"开启" : @"关闭"];
}

- (void)installPlayerKeyboardMonitor {
    if (self.playerKeyboardEventMonitor != nil) {
        return;
    }
    MotionAppDelegate* __weak weakSelf = self;
    self.playerKeyboardEventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent* (NSEvent* event) {
        MotionAppDelegate* __strong self = weakSelf;
        if (self == nil) {
            return event;
        }
        NSWindow* keyWindow = NSApp.keyWindow ?: self.window;
        NSResponder* responder = keyWindow.firstResponder;
        if ([responder isKindOfClass:NSTextView.class] || [responder isKindOfClass:NSTextField.class]) {
            return event;
        }
        if (event.keyCode == 49) {
            [self playerTogglePlayPause:nil];
            [self showPlayerFullscreenControlsAndScheduleHide];
            return nil;
        }
        if (event.keyCode == 123) {
            [self playerSkipBySeconds:-5.0];
            [self showPlayerFullscreenControlsAndScheduleHide];
            return nil;
        }
        if (event.keyCode == 124) {
            [self playerSkipBySeconds:5.0];
            [self showPlayerFullscreenControlsAndScheduleHide];
            return nil;
        }
        if (event.keyCode == 53 && (self.playerVideoFullscreen || self.playerFullscreenWindow != nil)) {
            [self exitPlayerFullscreen];
            return nil;
        }
        return event;
    }];
}

- (NSView*)buildPlayerFullscreenControlsView {
    SMGlassCard card = SMGlass(YES, 22, SMColor(0.04, 0.05, 0.07, 0.58));
    NSView* controls = card.view;
    controls.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView* stack = SMVStack(10);
    SMInstallInCard(card.content, stack, 14);

    NSStackView* seekRow = SMHStack(10);
    [stack addArrangedSubview:seekRow];
    [seekRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;

    self.playerFullscreenCurrentTimeLabel = SMLabel(@"00:00", 11, NSFontWeightMedium, SMMuted());
    self.playerFullscreenCurrentTimeLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
    [seekRow addArrangedSubview:self.playerFullscreenCurrentTimeLabel];
    [self.playerFullscreenCurrentTimeLabel.widthAnchor constraintEqualToConstant:54].active = YES;

    self.playerFullscreenSeekSlider = [NSSlider sliderWithValue:0.0 minValue:0.0 maxValue:1.0 target:self action:@selector(playerFullscreenSeekChanged:)];
    self.playerFullscreenSeekSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.playerFullscreenSeekSlider.continuous = YES;
    [seekRow addArrangedSubview:self.playerFullscreenSeekSlider];
    [self.playerFullscreenSeekSlider.widthAnchor constraintGreaterThanOrEqualToConstant:280].active = YES;

    self.playerFullscreenDurationLabel = SMLabel(@"--:--", 11, NSFontWeightMedium, SMMuted());
    self.playerFullscreenDurationLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
    [seekRow addArrangedSubview:self.playerFullscreenDurationLabel];
    [self.playerFullscreenDurationLabel.widthAnchor constraintEqualToConstant:54].active = YES;

    NSStackView* commandRow = SMHStack(10);
    [stack addArrangedSubview:commandRow];
    [commandRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;

    NSButton* backButton = SMButton(@"-10s");
    backButton.target = self;
    backButton.action = @selector(playerSkipBackward:);
    [commandRow addArrangedSubview:backButton];

    self.playerFullscreenPlayPauseButton = SMButton(@"播放");
    self.playerFullscreenPlayPauseButton.target = self;
    self.playerFullscreenPlayPauseButton.action = @selector(playerTogglePlayPause:);
    [commandRow addArrangedSubview:self.playerFullscreenPlayPauseButton];

    NSButton* forwardButton = SMButton(@"+10s");
    forwardButton.target = self;
    forwardButton.action = @selector(playerSkipForward:);
    [commandRow addArrangedSubview:forwardButton];

    NSView* spacer = [NSView new];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [commandRow addArrangedSubview:spacer];

    NSTextField* hint = SMLabel(@"Space 播放/暂停 · ←/→ 跳转 5 秒", 11, NSFontWeightMedium, SMMuted());
    hint.lineBreakMode = NSLineBreakByTruncatingTail;
    hint.maximumNumberOfLines = 1;
    [commandRow addArrangedSubview:hint];

    NSButton* exitButton = SMButton(@"退出全屏");
    exitButton.target = self;
    exitButton.action = @selector(exitPlayerFullscreen);
    [commandRow addArrangedSubview:exitButton];

    return controls;
}

- (void)showPlayerFullscreenControlsAndScheduleHide {
    if (self.playerFullscreenControlsView == nil) {
        return;
    }
    [self.playerFullscreenControlsHideTimer invalidate];
    self.playerFullscreenControlsHideTimer = nil;
    self.playerFullscreenControlsView.hidden = NO;
    self.playerFullscreenControlsView.alphaValue = 1.0;
    self.playerFullscreenControlsHideTimer = [NSTimer scheduledTimerWithTimeInterval:2.4
                                                                               target:self
                                                                             selector:@selector(hidePlayerFullscreenControls:)
                                                                             userInfo:nil
                                                                              repeats:NO];
}

- (void)hidePlayerFullscreenControls:(NSTimer*)timer {
    (void)timer;
    if (self.playerFullscreenControlsView == nil) {
        return;
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
        context.duration = 0.22;
        self.playerFullscreenControlsView.animator.alphaValue = 0.0;
    } completionHandler:^{
        self.playerFullscreenControlsView.hidden = YES;
    }];
}

- (NSView*)buildExportPage {
    NSView* page = [self pageShellWithTitle:@"离线导出"
                                   subtitle:@"单独配置导出帧率、超分倍率和离线质量档位；导出时会保留稳定进度与错误保护。"
                                  telemetry:@[]];
    NSStackView* stack = [self pageStackInPage:page];

    NSView* sourceCard = [self buildExportSourceCard];
    NSView* exportCard = [self buildExportCard];
    [stack addArrangedSubview:sourceCard];
    [stack addArrangedSubview:exportCard];
    [sourceCard.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    [exportCard.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    SMSetMinHeight(sourceCard, 118);
    SMSetMinHeight(exportCard, 188);
    return page;
}

- (NSTextField*)diagnosticLine:(NSString*)name value:(NSString*)value {
    return SMLabel([NSString stringWithFormat:@"%@  %@", name, value], 11, NSFontWeightMedium, SMMuted());
}

- (void)setDiagnosticStatus:(NSString*)status output:(NSString*)output frame:(NSString*)frame queue:(NSString*)queue {
    self.diagStatusLabel.stringValue = [NSString stringWithFormat:@"状态  %@", status];
    if (output != nil) {
        self.diagOutputLabel.stringValue = [NSString stringWithFormat:@"输出  %@", output];
    }
    if (frame != nil) {
        self.diagFrameLabel.stringValue = [NSString stringWithFormat:@"帧  %@", frame];
    }
    if (queue != nil) {
        self.diagQueueLabel.stringValue = [NSString stringWithFormat:@"队列  %@", queue];
    }
    self.diagFrameRateLabel.stringValue = @"模式  增强播放";
    self.diagKernelLabel.stringValue = [NSString stringWithFormat:@"音量  %.0f%%", ([self currentPlayer] != nil ? [self currentPlayer].volume : 1.0f) * 100.0f];
}

- (NSView*)buildImportCard {
    SMGlassCard card = SMGlass(NO, kCardRadius, nil);
    NSStackView* stack = SMVStack(8);
    SMInstallInCard(card.content, stack, 14);

    [stack addArrangedSubview:SMCapsLabel(@"Source")];
    [stack addArrangedSubview:SMLabel(@"本地导入", 16, NSFontWeightSemibold, SMInk())];
    self.importedFileLabel = SMLabel(self.importedPath.length > 0 ? self.importedPath.lastPathComponent : @"尚未选择文件", 12, NSFontWeightRegular, SMMuted());
    [stack addArrangedSubview:self.importedFileLabel];

    NSStackView* actions = SMHStack(8);
    [stack addArrangedSubview:actions];
    NSButton* importButton = SMButton(@"导入视频");
    importButton.target = self;
    importButton.action = @selector(importVideo:);
    [actions addArrangedSubview:importButton];

    return card.view;
}

- (NSView*)buildBilibiliPage {
    SMBilibiliPageView* page = [SMBilibiliPageView new];
    page.translatesAutoresizingMaskIntoConstraints = NO;
    page.wantsLayer = YES;
    page.layer.backgroundColor = SMColor(0.07, 0.08, 0.10, 1.0).CGColor;

    NSTextField* logo = SMLabel(@"bilibili", 30, NSFontWeightBold, SMColor(0.98, 0.36, 0.62, 1.0));
    logo.translatesAutoresizingMaskIntoConstraints = YES;
    logo.frame = NSMakeRect(24, 22, 126, 36);
    [page addSubview:logo];

    self.bilibiliSectionControl = [NSSegmentedControl segmentedControlWithLabels:@[@"推荐", @"视频", @"UP主", @"番剧", @"影视"]
                                                                    trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                          target:self
                                                                          action:@selector(bilibiliSectionChanged:)];
    self.bilibiliSectionControl.translatesAutoresizingMaskIntoConstraints = YES;
    self.bilibiliSectionControl.selectedSegment = 0;
    self.bilibiliSectionControl.frame = NSMakeRect(164, 24, 330, 30);
    [page addSubview:self.bilibiliSectionControl];

    NSTextField* qualityTitle = SMLabel(@"清晰度", 12, NSFontWeightSemibold, SMMuted());
    qualityTitle.translatesAutoresizingMaskIntoConstraints = YES;
    qualityTitle.frame = NSMakeRect(902, 30, 48, 18);
    qualityTitle.alignment = NSTextAlignmentRight;
    [page addSubview:qualityTitle];

    self.bilibiliQualityPopup = [NSPopUpButton new];
    self.bilibiliQualityPopup.translatesAutoresizingMaskIntoConstraints = YES;
    [self.bilibiliQualityPopup addItemsWithTitles:@[@"最高可用", @"1080p", @"720p", @"480p", @"360p"]];
    [self.bilibiliQualityPopup selectItemAtIndex:0];
    self.bilibiliQualityPopup.frame = NSMakeRect(958, 24, 112, 30);
    self.bilibiliQualityPopup.autoresizingMask = NSViewMinXMargin;
    [page addSubview:self.bilibiliQualityPopup];

    self.bilibiliSearchField = [NSTextField new];
    self.bilibiliSearchField.translatesAutoresizingMaskIntoConstraints = YES;
    self.bilibiliSearchField.placeholderString = @"搜索视频、UP、番剧或影视";
    self.bilibiliSearchField.bezelStyle = NSTextFieldRoundedBezel;
    self.bilibiliSearchField.target = self;
    self.bilibiliSearchField.action = @selector(searchBilibili:);
    self.bilibiliSearchField.frame = NSMakeRect(24, 76, 492, 30);
    self.bilibiliSearchField.autoresizingMask = NSViewWidthSizable;
    [page addSubview:self.bilibiliSearchField];

    self.bilibiliOrderPopup = [NSPopUpButton new];
    self.bilibiliOrderPopup.translatesAutoresizingMaskIntoConstraints = YES;
    [self.bilibiliOrderPopup addItemsWithTitles:@[@"综合排序", @"最多播放", @"最新发布", @"最多弹幕", @"最多收藏"]];
    self.bilibiliOrderPopup.frame = NSMakeRect(528, 76, 120, 30);
    self.bilibiliOrderPopup.autoresizingMask = NSViewMinXMargin;
    [page addSubview:self.bilibiliOrderPopup];

    NSButton* searchButton = SMButton(@"搜索");
    searchButton.translatesAutoresizingMaskIntoConstraints = YES;
    searchButton.target = self;
    searchButton.action = @selector(searchBilibili:);
    searchButton.frame = NSMakeRect(660, 76, 84, 30);
    searchButton.autoresizingMask = NSViewMinXMargin;
    [page addSubview:searchButton];

    NSButton* homeButton = SMButton(@"刷新推荐");
    homeButton.translatesAutoresizingMaskIntoConstraints = YES;
    homeButton.target = self;
    homeButton.action = @selector(loadBilibiliHome:);
    homeButton.frame = NSMakeRect(756, 76, 104, 30);
    homeButton.autoresizingMask = NSViewMinXMargin;
    [page addSubview:homeButton];

    self.bilibiliURLField = [NSTextField new];
    self.bilibiliURLField.translatesAutoresizingMaskIntoConstraints = YES;
    self.bilibiliURLField.placeholderString = @"粘贴 BV 链接或番剧 ep/ss 链接";
    self.bilibiliURLField.bezelStyle = NSTextFieldRoundedBezel;
    self.bilibiliURLField.frame = NSMakeRect(24, 118, 492, 30);
    self.bilibiliURLField.autoresizingMask = NSViewWidthSizable;
    [page addSubview:self.bilibiliURLField];

    self.bilibiliImportButton = SMButton(@"缓存并播放");
    self.bilibiliImportButton.translatesAutoresizingMaskIntoConstraints = YES;
    self.bilibiliImportButton.target = self;
    self.bilibiliImportButton.action = @selector(importBilibiliURL:);
    self.bilibiliImportButton.frame = NSMakeRect(528, 118, 116, 30);
    self.bilibiliImportButton.autoresizingMask = NSViewMinXMargin;
    [page addSubview:self.bilibiliImportButton];

    NSButton* cookieButton = SMButton(@"登录态");
    cookieButton.translatesAutoresizingMaskIntoConstraints = YES;
    cookieButton.target = self;
    cookieButton.action = @selector(chooseBilibiliCookie:);
    cookieButton.frame = NSMakeRect(656, 118, 86, 30);
    cookieButton.autoresizingMask = NSViewMinXMargin;
    [page addSubview:cookieButton];

    NSButton* loginButton = SMButton(@"扫码登录");
    loginButton.translatesAutoresizingMaskIntoConstraints = YES;
    loginButton.target = self;
    loginButton.action = @selector(loginBilibili:);
    loginButton.frame = NSMakeRect(754, 118, 106, 30);
    loginButton.autoresizingMask = NSViewMinXMargin;
    [page addSubview:loginButton];

    NSButton* clearCacheButton = SMButton(@"清理缓存");
    clearCacheButton.translatesAutoresizingMaskIntoConstraints = YES;
    clearCacheButton.target = self;
    clearCacheButton.action = @selector(clearBilibiliCache:);
    clearCacheButton.frame = NSMakeRect(872, 118, 96, 30);
    clearCacheButton.autoresizingMask = NSViewMinXMargin;
    [page addSubview:clearCacheButton];

    NSButton* favoritesButton = SMButton(@"我的收藏");
    favoritesButton.translatesAutoresizingMaskIntoConstraints = YES;
    favoritesButton.target = self;
    favoritesButton.action = @selector(loadBilibiliFavorites:);
    favoritesButton.frame = NSMakeRect(980, 118, 96, 30);
    favoritesButton.autoresizingMask = NSViewMinXMargin;
    [page addSubview:favoritesButton];

    self.bilibiliStatusLabel = SMLabel(@"正在准备 B站推荐...", 12, NSFontWeightMedium, SMColor(0.72, 0.84, 1.0, 1.0));
    self.bilibiliStatusLabel.translatesAutoresizingMaskIntoConstraints = YES;
    self.bilibiliStatusLabel.frame = NSMakeRect(24, 164, 860, 20);
    self.bilibiliStatusLabel.autoresizingMask = NSViewWidthSizable;
    [page addSubview:self.bilibiliStatusLabel];

    self.bilibiliCookieLabel = SMLabel(@"登录态：未设置。大会员清晰度只使用你自己的账号权限；不绕过 B站 DRM/付费规则。", 11, NSFontWeightRegular, SMMuted());
    self.bilibiliCookieLabel.translatesAutoresizingMaskIntoConstraints = YES;
    self.bilibiliCookieLabel.maximumNumberOfLines = 2;
    self.bilibiliCookieLabel.frame = NSMakeRect(24, 188, 860, 36);
    self.bilibiliCookieLabel.autoresizingMask = NSViewWidthSizable;
    [page addSubview:self.bilibiliCookieLabel];
    if (self.bilibiliCookiePath.length > 0) {
        self.bilibiliCookieLabel.stringValue = [NSString stringWithFormat:@"登录态：%@", self.bilibiliCookiePath.lastPathComponent ?: self.bilibiliCookiePath];
    }

    NSScrollView* gridScroll = [NSScrollView new];
    gridScroll.translatesAutoresizingMaskIntoConstraints = YES;
    gridScroll.frame = NSMakeRect(24, 236, 1046, 480);
    gridScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    gridScroll.drawsBackground = YES;
    gridScroll.backgroundColor = SMColor(0.05, 0.06, 0.075, 1.0);
    gridScroll.hasVerticalScroller = YES;
    gridScroll.borderType = NSNoBorder;
    self.bilibiliGridStack = nil;
    self.bilibiliLastGridWidth = 0.0;
    self.bilibiliFrameGridContent = [SMFlippedView new];
    self.bilibiliFrameGridContent.wantsLayer = YES;
    self.bilibiliFrameGridContent.layer.backgroundColor = SMColor(0.05, 0.06, 0.075, 1.0).CGColor;
    self.bilibiliFrameGridContent.frame = NSMakeRect(0, 0, 1046, 480);
    gridScroll.documentView = self.bilibiliFrameGridContent;
    [page addSubview:gridScroll];

    MotionAppDelegate* __weak weakSelf = self;
    NSTextField* __weak weakLogo = logo;
    NSSegmentedControl* __weak weakSections = self.bilibiliSectionControl;
    NSTextField* __weak weakQualityTitle = qualityTitle;
    NSPopUpButton* __weak weakQuality = self.bilibiliQualityPopup;
    NSTextField* __weak weakSearch = self.bilibiliSearchField;
    NSPopUpButton* __weak weakOrder = self.bilibiliOrderPopup;
    NSButton* __weak weakSearchButton = searchButton;
    NSButton* __weak weakHomeButton = homeButton;
    NSTextField* __weak weakURL = self.bilibiliURLField;
    NSButton* __weak weakImport = self.bilibiliImportButton;
    NSButton* __weak weakCookie = cookieButton;
    NSButton* __weak weakLogin = loginButton;
    NSButton* __weak weakClearCache = clearCacheButton;
    NSButton* __weak weakFavorites = favoritesButton;
    NSTextField* __weak weakStatus = self.bilibiliStatusLabel;
    NSTextField* __weak weakCookieLabel = self.bilibiliCookieLabel;
    NSScrollView* __weak weakGridScroll = gridScroll;
    page.layoutHandler = ^(SMBilibiliPageView* host) {
        MotionAppDelegate* __strong self = weakSelf;
        NSScrollView* scroll = weakGridScroll;
        if (self == nil || scroll == nil) {
            return;
        }

        const CGFloat w = MAX(420.0, host.bounds.size.width);
        const CGFloat h = MAX(420.0, host.bounds.size.height);
        const CGFloat margin = 24.0;
        const CGFloat gap = 12.0;
        const BOOL compact = w < 760.0;

        weakLogo.frame = NSMakeRect(margin, 22.0, 126.0, 36.0);
        weakQuality.frame = NSMakeRect(MAX(margin, w - margin - 112.0), compact ? 22.0 : 24.0, 112.0, 30.0);
        weakQualityTitle.frame = NSMakeRect(MAX(margin, w - margin - 166.0), compact ? 28.0 : 30.0, 48.0, 18.0);

        CGFloat gridY = 0.0;
        if (compact) {
            weakSections.frame = NSMakeRect(margin, 66.0, MIN(360.0, w - margin * 2.0), 30.0);
            weakSearch.frame = NSMakeRect(margin, 112.0, w - margin * 2.0, 30.0);
            weakOrder.frame = NSMakeRect(margin, 154.0, 128.0, 30.0);
            weakSearchButton.frame = NSMakeRect(margin + 140.0, 154.0, 84.0, 30.0);
            weakHomeButton.frame = NSMakeRect(margin + 236.0, 154.0, MIN(110.0, w - margin * 2.0 - 236.0), 30.0);
            weakURL.frame = NSMakeRect(margin, 196.0, w - margin * 2.0, 30.0);
            weakImport.frame = NSMakeRect(margin, 238.0, 116.0, 30.0);
            weakCookie.frame = NSMakeRect(margin + 128.0, 238.0, 86.0, 30.0);
            weakLogin.frame = NSMakeRect(margin + 226.0, 238.0, 106.0, 30.0);
            weakClearCache.frame = NSMakeRect(margin, 280.0, 96.0, 30.0);
            weakFavorites.frame = NSMakeRect(margin + 108.0, 280.0, 96.0, 30.0);
            weakStatus.frame = NSMakeRect(margin, 324.0, w - margin * 2.0, 20.0);
            weakCookieLabel.frame = NSMakeRect(margin, 348.0, w - margin * 2.0, 38.0);
            gridY = 398.0;
        } else {
            const CGFloat right = w - margin;
            const CGFloat qualityLeft = right - 172.0;
            const CGFloat segmentX = 164.0;
            weakSections.frame = NSMakeRect(segmentX, 24.0, MAX(260.0, MIN(390.0, qualityLeft - segmentX - gap)), 30.0);

            const CGFloat orderW = 122.0;
            const CGFloat searchButtonW = 84.0;
            const CGFloat homeW = 104.0;
            const CGFloat trailingControlsW = orderW + searchButtonW + homeW + gap * 3.0;
            const CGFloat fieldW = MAX(280.0, w - margin * 2.0 - trailingControlsW);
            CGFloat x = margin;
            weakSearch.frame = NSMakeRect(x, 76.0, fieldW, 30.0);
            x += fieldW + gap;
            weakOrder.frame = NSMakeRect(x, 76.0, orderW, 30.0);
            x += orderW + gap;
            weakSearchButton.frame = NSMakeRect(x, 76.0, searchButtonW, 30.0);
            x += searchButtonW + gap;
            weakHomeButton.frame = NSMakeRect(x, 76.0, homeW, 30.0);

            const CGFloat importW = 116.0;
            const CGFloat cookieW = 86.0;
            const CGFloat loginW = 106.0;
            const CGFloat clearW = 96.0;
            const CGFloat favoritesW = 96.0;
            const CGFloat urlButtonsW = importW + cookieW + loginW + clearW + favoritesW + gap * 5.0;
            const CGFloat urlFieldW = MAX(280.0, w - margin * 2.0 - urlButtonsW);
            x = margin;
            weakURL.frame = NSMakeRect(x, 118.0, urlFieldW, 30.0);
            x += urlFieldW + gap;
            weakImport.frame = NSMakeRect(x, 118.0, importW, 30.0);
            x += importW + gap;
            weakCookie.frame = NSMakeRect(x, 118.0, cookieW, 30.0);
            x += cookieW + gap;
            weakLogin.frame = NSMakeRect(x, 118.0, loginW, 30.0);
            x += loginW + gap;
            weakClearCache.frame = NSMakeRect(x, 118.0, clearW, 30.0);
            x += clearW + gap;
            weakFavorites.frame = NSMakeRect(x, 118.0, favoritesW, 30.0);

            weakStatus.frame = NSMakeRect(margin, 164.0, w - margin * 2.0, 20.0);
            weakCookieLabel.frame = NSMakeRect(margin, 188.0, w - margin * 2.0, 36.0);
            gridY = 236.0;
        }

        const CGFloat gridHeight = MAX(160.0, h - gridY - margin);
        scroll.frame = NSMakeRect(margin, gridY, w - margin * 2.0, gridHeight);
        const CGFloat gridWidth = scroll.contentView.bounds.size.width;
        if (fabs(self.bilibiliLastGridWidth - gridWidth) > 8.0) {
            self.bilibiliLastGridWidth = gridWidth;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self rebuildBilibiliGrid];
            });
        }
    };

    if (self.bilibiliItems == nil) {
        self.bilibiliItems = [NSMutableArray array];
    }
    [self rebuildBilibiliGrid];
    if (self.bilibiliItems.count == 0 && self.bilibiliImportTask == nil) {
        [self runBilibiliListMode:@"home" keyword:@""];
    }
    return page;
}

- (NSString*)bilibiliCategoryArgument {
    NSInteger segment = self.bilibiliSectionControl.selectedSegment;
    if (segment == 2) {
        return @"up";
    }
    if (segment == 3) {
        return @"bangumi";
    }
    if (segment == 4) {
        return @"film";
    }
    return @"video";
}

- (NSString*)bilibiliOrderArgument {
    NSString* title = self.bilibiliOrderPopup.titleOfSelectedItem ?: @"综合排序";
    if ([title containsString:@"播放"]) {
        return @"click";
    }
    if ([title containsString:@"最新"]) {
        return @"pubdate";
    }
    if ([title containsString:@"弹幕"]) {
        return @"dm";
    }
    if ([title containsString:@"收藏"]) {
        return @"stow";
    }
    return @"totalrank";
}

- (NSString*)bilibiliCountText:(NSNumber*)count {
    const double value = count != nil ? count.doubleValue : 0.0;
    if (value >= 10000.0) {
        return [NSString stringWithFormat:@"%.1f万", value / 10000.0];
    }
    return [NSString stringWithFormat:@"%.0f", value];
}

- (void)rebuildBilibiliGrid {
    if (self.bilibiliFrameGridContent != nil) {
        [self rebuildBilibiliFrameGrid];
        return;
    }
    if (self.bilibiliGridStack == nil) {
        return;
    }
    for (NSView* subview in self.bilibiliGridStack.arrangedSubviews.copy) {
        [self.bilibiliGridStack removeArrangedSubview:subview];
        [subview removeFromSuperview];
    }

    if (self.bilibiliItems.count == 0) {
        NSTextField* empty = SMLabel(@"暂无结果。可以刷新推荐，或者输入关键词搜索视频、番剧和影视。", 13, NSFontWeightMedium, SMMuted());
        [self.bilibiliGridStack addArrangedSubview:empty];
        return;
    }

    const NSInteger columns = 4;
    for (NSInteger start = 0; start < static_cast<NSInteger>(self.bilibiliItems.count); start += columns) {
        NSStackView* row = SMHStack(16);
        row.distribution = NSStackViewDistributionFillEqually;
        [self.bilibiliGridStack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.bilibiliGridStack.widthAnchor].active = YES;
        for (NSInteger offset = 0; offset < columns; ++offset) {
            NSInteger index = start + offset;
            NSView* card = nil;
            if (index < static_cast<NSInteger>(self.bilibiliItems.count)) {
                card = [self bilibiliCardForItem:self.bilibiliItems[static_cast<NSUInteger>(index)] index:index];
            } else {
                card = [NSView new];
                card.translatesAutoresizingMaskIntoConstraints = NO;
            }
            [row addArrangedSubview:card];
            [card.heightAnchor constraintEqualToConstant:224.0].active = YES;
        }
    }
}

- (void)rebuildBilibiliFrameGrid {
    NSView* grid = self.bilibiliFrameGridContent;
    if (grid == nil) {
        return;
    }
    for (NSView* subview in grid.subviews.copy) {
        [subview removeFromSuperview];
    }

    const CGFloat availableWidth = MAX(720.0, grid.enclosingScrollView.contentView.bounds.size.width);
    const CGFloat gap = 16.0;
    const CGFloat minCardWidth = 220.0;
    NSInteger columns = MAX(2, static_cast<NSInteger>(floor((availableWidth + gap) / (minCardWidth + gap))));
    const CGFloat cardWidth = floor((availableWidth - gap * (columns + 1)) / columns);
    const CGFloat inset = 10.0;
    const CGFloat coverHeight = floor((cardWidth - inset * 2.0) * 9.0 / 16.0);
    const CGFloat cardHeight = inset * 2.0 + coverHeight + 8.0 + 38.0 + 4.0 + 16.0 + 34.0;

    if (self.bilibiliItems.count == 0) {
        grid.frame = NSMakeRect(0, 0, availableWidth, MAX(480.0, grid.enclosingScrollView.contentView.bounds.size.height));
        NSTextField* empty = SMLabel(@"暂无结果。可以刷新推荐，或者输入关键词搜索视频、番剧和影视。", 14, NSFontWeightMedium, SMMuted());
        empty.translatesAutoresizingMaskIntoConstraints = YES;
        empty.frame = NSMakeRect(18, 18, availableWidth - 36.0, 26);
        [grid addSubview:empty];
        return;
    }

    const NSInteger rows = static_cast<NSInteger>(ceil(static_cast<double>(self.bilibiliItems.count) / static_cast<double>(columns)));
    const CGFloat contentHeight = MAX(grid.enclosingScrollView.contentView.bounds.size.height, gap + rows * (cardHeight + gap));
    grid.frame = NSMakeRect(0, 0, availableWidth, contentHeight);

    for (NSInteger index = 0; index < static_cast<NSInteger>(self.bilibiliItems.count); ++index) {
        const NSInteger row = index / columns;
        const NSInteger column = index % columns;
        const CGFloat x = gap + column * (cardWidth + gap);
        const CGFloat y = gap + row * (cardHeight + gap);
        NSDictionary<NSString*, id>* item = self.bilibiliItems[static_cast<NSUInteger>(index)];
        NSString* kind = [item[@"kind"] isKindOfClass:NSString.class] ? item[@"kind"] : @"video";

        NSView* card = [SMFlippedView new];
        card.frame = NSMakeRect(x, y, cardWidth, cardHeight);
        card.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
        SMApplyChromeLayer(card, 12, index == self.bilibiliSelectedIndex ? SMColor(0.98, 0.36, 0.62, 0.72) : SMColor(1.0, 1.0, 1.0, 0.10), 0.14);
        card.layer.borderWidth = index == self.bilibiliSelectedIndex ? 2.0 : 1.0;
        [grid addSubview:card];

        NSImageView* cover = [NSImageView new];
        cover.frame = NSMakeRect(inset, inset, cardWidth - inset * 2.0, coverHeight);
        cover.imageScaling = NSImageScaleProportionallyUpOrDown;
        cover.wantsLayer = YES;
        cover.layer.cornerRadius = 8.0;
        cover.layer.cornerCurve = kCACornerCurveContinuous;
        cover.layer.masksToBounds = YES;
        cover.layer.backgroundColor = SMColor(0.04, 0.05, 0.06, 1.0).CGColor;
        [card addSubview:cover];
        NSString* pic = [item[@"pic"] isKindOfClass:NSString.class] ? item[@"pic"] : @"";
        [self loadBilibiliCoverURL:pic intoImageView:cover];

        NSTextField* title = SMLabel([item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"未命名视频",
                                     12,
                                     NSFontWeightSemibold,
                                     SMInk());
        title.translatesAutoresizingMaskIntoConstraints = YES;
        title.maximumNumberOfLines = 2;
        title.lineBreakMode = NSLineBreakByTruncatingTail;
        title.frame = NSMakeRect(inset, inset + coverHeight + 8.0, cardWidth - inset * 2.0, 38.0);
        [card addSubview:title];

        NSString* author = [item[@"author"] isKindOfClass:NSString.class] ? item[@"author"] : @"";
        NSString* duration = [item[@"duration"] isKindOfClass:NSString.class] ? item[@"duration"] : @"";
        NSNumber* play = [item[@"play"] isKindOfClass:NSNumber.class] ? item[@"play"] : @0;
        NSString* meta = [NSString stringWithFormat:@"%@ · %@播放%@", author.length > 0 ? author : @"Bilibili", [self bilibiliCountText:play], duration.length > 0 ? [NSString stringWithFormat:@" · %@", duration] : @""];
        NSTextField* metaLabel = SMLabel(meta, 10, NSFontWeightMedium, SMMuted());
        metaLabel.translatesAutoresizingMaskIntoConstraints = YES;
        metaLabel.maximumNumberOfLines = 1;
        metaLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        metaLabel.frame = NSMakeRect(inset, inset + coverHeight + 50.0, cardWidth - inset * 2.0, 16.0);
        [card addSubview:metaLabel];

        NSPopUpButton* qualityPopup = [NSPopUpButton new];
        qualityPopup.translatesAutoresizingMaskIntoConstraints = YES;
        [qualityPopup addItemsWithTitles:@[@"最高可用", @"1080p", @"720p", @"480p", @"360p"]];
        [qualityPopup selectItemWithTitle:self.bilibiliQualityPopup.titleOfSelectedItem ?: @"最高可用"];
        qualityPopup.frame = NSMakeRect(inset, cardHeight - inset - 26.0, MIN(112.0, cardWidth * 0.48), 26.0);
        qualityPopup.tag = index;
        qualityPopup.enabled = ![kind isEqualToString:@"up"];
        [card addSubview:qualityPopup];

        NSButton* detailButton = SMButton(@"详情");
        detailButton.translatesAutoresizingMaskIntoConstraints = YES;
        detailButton.frame = NSMakeRect(cardWidth - inset - 140.0, cardHeight - inset - 26.0, 44.0, 26.0);
        detailButton.tag = index;
        detailButton.target = self;
        detailButton.action = @selector(openBilibiliDetailButton:);
        [card addSubview:detailButton];

        NSButton* actionButton = SMButton([kind isEqualToString:@"up"] ? @"打开空间" : @"缓存");
        actionButton.translatesAutoresizingMaskIntoConstraints = YES;
        actionButton.frame = NSMakeRect(cardWidth - inset - 92.0, cardHeight - inset - 26.0, 92.0, 26.0);
        actionButton.tag = index;
        actionButton.target = self;
        actionButton.action = [kind isEqualToString:@"up"] ? @selector(openBilibiliCard:) : @selector(importBilibiliCard:);
        [card addSubview:actionButton];

        NSButton* coverButton = [NSButton buttonWithTitle:@"" target:self action:@selector(selectBilibiliCard:)];
        coverButton.translatesAutoresizingMaskIntoConstraints = YES;
        coverButton.frame = NSMakeRect(inset, inset, cardWidth - inset * 2.0, coverHeight + 66.0);
        coverButton.tag = index;
        coverButton.bordered = NO;
        coverButton.wantsLayer = YES;
        coverButton.layer.backgroundColor = NSColor.clearColor.CGColor;
        [card addSubview:coverButton positioned:NSWindowBelow relativeTo:qualityPopup];
    }
}

- (NSView*)bilibiliCardForItem:(NSDictionary<NSString*, id>*)item index:(NSInteger)index {
    NSView* card = [NSView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    SMApplyChromeLayer(card, 12, index == self.bilibiliSelectedIndex ? SMColor(0.98, 0.36, 0.62, 0.72) : SMColor(1.0, 1.0, 1.0, 0.10), 0.14);
    card.layer.borderWidth = index == self.bilibiliSelectedIndex ? 2.0 : 1.0;

    NSStackView* stack = SMVStack(8);
    [card addSubview:stack];
    SMFill(stack, card, 9);

    NSImageView* cover = [NSImageView new];
    cover.translatesAutoresizingMaskIntoConstraints = NO;
    cover.imageScaling = NSImageScaleAxesIndependently;
    cover.wantsLayer = YES;
    cover.layer.cornerRadius = 8.0;
    cover.layer.cornerCurve = kCACornerCurveContinuous;
    cover.layer.masksToBounds = YES;
    cover.layer.backgroundColor = SMColor(0.04, 0.05, 0.06, 1.0).CGColor;
    [stack addArrangedSubview:cover];
    [cover.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    [cover.heightAnchor constraintEqualToAnchor:cover.widthAnchor multiplier:9.0 / 16.0].active = YES;

    NSString* pic = [item[@"pic"] isKindOfClass:NSString.class] ? item[@"pic"] : @"";
    [self loadBilibiliCoverURL:pic intoImageView:cover];

    NSTextField* title = SMLabel([item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"未命名视频",
                                 12,
                                 NSFontWeightSemibold,
                                 SMInk());
    title.maximumNumberOfLines = 2;
    [stack addArrangedSubview:title];

    NSString* author = [item[@"author"] isKindOfClass:NSString.class] ? item[@"author"] : @"";
    NSString* duration = [item[@"duration"] isKindOfClass:NSString.class] ? item[@"duration"] : @"";
    NSNumber* play = [item[@"play"] isKindOfClass:NSNumber.class] ? item[@"play"] : @0;
    NSString* meta = [NSString stringWithFormat:@"%@ · %@播放%@", author.length > 0 ? author : @"Bilibili", [self bilibiliCountText:play], duration.length > 0 ? [NSString stringWithFormat:@" · %@", duration] : @""];
    NSTextField* metaLabel = SMLabel(meta, 10, NSFontWeightMedium, SMMuted());
    metaLabel.maximumNumberOfLines = 1;
    metaLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [stack addArrangedSubview:metaLabel];

    NSButton* overlay = [NSButton buttonWithTitle:@"" target:self action:@selector(selectBilibiliCard:)];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.tag = index;
    overlay.bordered = NO;
    overlay.wantsLayer = YES;
    overlay.layer.backgroundColor = NSColor.clearColor.CGColor;
    [card addSubview:overlay];
    SMFill(overlay, card, 0);
    return card;
}

- (void)loadBilibiliCoverURL:(NSString*)url intoImageView:(NSImageView*)imageView {
    if (url.length == 0) {
        return;
    }
    NSString* normalized = [url copy];
    if ([normalized hasPrefix:@"//"]) {
        normalized = [@"https:" stringByAppendingString:normalized];
    } else if ([normalized hasPrefix:@"http://"]) {
        normalized = [@"https://" stringByAppendingString:[normalized substringFromIndex:7]];
    }
    NSURL* imageURL = [NSURL URLWithString:normalized];
    if (imageURL == nil) {
        return;
    }
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:imageURL];
    request.timeoutInterval = 12.0;
    [request setValue:@"https://www.bilibili.com/" forHTTPHeaderField:@"Referer"];
    [request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) StellariaMotion/0.5" forHTTPHeaderField:@"User-Agent"];
    NSURLSessionDataTask* task = [NSURLSession.sharedSession dataTaskWithRequest:request
                                                           completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        (void)response;
        if (error != nil || data.length == 0) {
            return;
        }
        NSImage* image = [[NSImage alloc] initWithData:data];
        if (image == nil) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            imageView.image = image;
        });
    }];
    [task resume];
}

- (void)selectBilibiliCard:(NSButton*)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= static_cast<NSInteger>(self.bilibiliItems.count)) {
        return;
    }
    self.bilibiliSelectedIndex = index;
    NSDictionary<NSString*, id>* item = self.bilibiliItems[static_cast<NSUInteger>(index)];
    NSString* url = [item[@"url"] isKindOfClass:NSString.class] ? item[@"url"] : @"";
    NSString* title = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"B 站视频";
    self.bilibiliURLField.stringValue = url ?: @"";
    self.bilibiliStatusLabel.stringValue = [NSString stringWithFormat:@"已选中：%@。确认清晰度后点“缓存并播放”。", title];
    if (NSApp.currentEvent.clickCount >= 2) {
        [self showBilibiliDetailForIndex:index];
        return;
    }
    [self rebuildBilibiliGrid];
}

- (void)openBilibiliDetailButton:(NSButton*)sender {
    [self showBilibiliDetailForIndex:sender.tag];
}

- (void)importBilibiliCard:(NSButton*)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= static_cast<NSInteger>(self.bilibiliItems.count)) {
        return;
    }
    NSDictionary<NSString*, id>* item = self.bilibiliItems[static_cast<NSUInteger>(index)];
    NSString* url = [item[@"url"] isKindOfClass:NSString.class] ? item[@"url"] : @"";
    if (url.length == 0) {
        self.bilibiliStatusLabel.stringValue = @"这个条目没有可缓存的视频链接";
        return;
    }
    self.bilibiliSelectedIndex = index;
    self.bilibiliURLField.stringValue = url;
    for (NSView* subview in sender.superview.subviews) {
        if ([subview isKindOfClass:NSPopUpButton.class]) {
            NSPopUpButton* popup = (NSPopUpButton*)subview;
            if (popup.tag == index && popup.titleOfSelectedItem.length > 0) {
                [self.bilibiliQualityPopup selectItemWithTitle:popup.titleOfSelectedItem];
            }
        }
    }
    [self importBilibiliURL:sender];
}

- (void)openBilibiliCard:(NSButton*)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= static_cast<NSInteger>(self.bilibiliItems.count)) {
        return;
    }
    NSDictionary<NSString*, id>* item = self.bilibiliItems[static_cast<NSUInteger>(index)];
    NSString* url = [item[@"url"] isKindOfClass:NSString.class] ? item[@"url"] : @"";
    if (url.length == 0) {
        return;
    }
    NSURL* nsURL = [NSURL URLWithString:url];
    if (nsURL != nil) {
        [NSWorkspace.sharedWorkspace openURL:nsURL];
    }
}

- (void)showBilibiliDetailForIndex:(NSInteger)index {
    if (index < 0 || index >= static_cast<NSInteger>(self.bilibiliItems.count)) {
        return;
    }
    NSDictionary<NSString*, id>* item = self.bilibiliItems[static_cast<NSUInteger>(index)];
    NSString* url = [item[@"url"] isKindOfClass:NSString.class] ? item[@"url"] : @"";
    NSString* title = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"B站详情";
    if (url.length == 0) {
        return;
    }

    NSPanel* panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 920, 700)
                                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    panel.title = title;
    panel.floatingPanel = NO;
    panel.releasedWhenClosed = NO;
    panel.hidesOnDeactivate = NO;
    panel.backgroundColor = SMColor(0.08, 0.09, 0.11, 1.0);
    if (self.bilibiliDetailPanels == nil) {
        self.bilibiliDetailPanels = [NSMutableSet set];
    }
    [self.bilibiliDetailPanels addObject:panel];
    MotionAppDelegate* __weak weakSelfForClose = self;
    NSPanel* __weak weakPanelForClose = panel;
    __block id closeObserver = nil;
    closeObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification
                                                                    object:panel
                                                                     queue:NSOperationQueue.mainQueue
                                                                usingBlock:^(NSNotification* note) {
        (void)note;
        MotionAppDelegate* __strong self = weakSelfForClose;
        NSPanel* closingPanel = weakPanelForClose;
        if (self != nil && closingPanel != nil) {
            [self.bilibiliDetailPanels removeObject:closingPanel];
        }
        if (closeObserver != nil) {
            [NSNotificationCenter.defaultCenter removeObserver:closeObserver];
            closeObserver = nil;
        }
    }];

    NSScrollView* scroll = [NSScrollView new];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSNoBorder;
    scroll.frame = panel.contentView.bounds;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSView* content = [SMFlippedView new];
    content.wantsLayer = YES;
    content.layer.backgroundColor = SMColor(0.08, 0.09, 0.11, 1.0).CGColor;
    content.frame = NSMakeRect(0, 0, 900, 680);
    scroll.documentView = content;
    panel.contentView = scroll;

    NSTextField* loading = SMLabel(@"正在加载详情...", 16, NSFontWeightSemibold, SMInk());
    loading.translatesAutoresizingMaskIntoConstraints = YES;
    loading.frame = NSMakeRect(24, 24, 520, 24);
    [content addSubview:loading];
    [panel center];
    [panel makeKeyAndOrderFront:nil];

    NSURL* script = [self bilibiliCacheScriptURL];
    if (script == nil) {
        loading.stringValue = @"未找到 B 站缓存脚本";
        return;
    }
    NSMutableArray<NSString*>* args = [@[
        @"python3", script.path,
        @"--mode", @"detail",
        @"--url", url,
        @"--output-dir", [self bilibiliCacheDirectoryURL].path,
        @"--json",
    ] mutableCopy];
    if (self.bilibiliCookiePath.length > 0) {
        [args addObjectsFromArray:@[@"--cookie-file", self.bilibiliCookiePath]];
    }
    NSPipe* pipe = [NSPipe pipe];
    NSTask* task = [NSTask new];
    task.launchPath = @"/usr/bin/env";
    task.arguments = args;
    task.standardOutput = pipe;
    task.standardError = pipe;
    MotionAppDelegate* __weak weakSelf = self;
    NSPanel* __weak weakPanel = panel;
    NSView* __weak weakContent = content;
    NSTextField* __weak weakLoading = loading;
    task.terminationHandler = ^(NSTask* finishedTask) {
        (void)finishedTask;
        NSData* data = [pipe.fileHandleForReading readDataToEndOfFile];
        dispatch_async(dispatch_get_main_queue(), ^{
            MotionAppDelegate* __strong self = weakSelf;
            NSPanel* panel = weakPanel;
            NSView* content = weakContent;
            NSTextField* loading = weakLoading;
            if (self == nil || panel == nil || content == nil || loading == nil ||
                !panel.visible || ![self.bilibiliDetailPanels containsObject:panel]) {
                return;
            }
            NSDictionary* result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![result isKindOfClass:NSDictionary.class] || ![result[@"ok"] boolValue]) {
                NSString* text = [result[@"error"] isKindOfClass:NSString.class] ? result[@"error"] : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                loading.stringValue = [NSString stringWithFormat:@"详情加载失败：%@", text.length > 0 ? text : @"未知错误"];
                return;
            }
            [self populateBilibiliDetailContent:content result:result fallbackURL:url];
        });
    };
    NSError* error = nil;
    if (![task launchAndReturnError:&error]) {
        loading.stringValue = [NSString stringWithFormat:@"详情启动失败：%@", error.localizedDescription ?: @"python3 unavailable"];
    }
}

- (void)populateBilibiliDetailContent:(NSView*)content result:(NSDictionary*)result fallbackURL:(NSString*)fallbackURL {
    for (NSView* subview in content.subviews.copy) {
        [subview removeFromSuperview];
    }
    const CGFloat width = MAX(760.0, content.enclosingScrollView.contentView.bounds.size.width);
    const CGFloat margin = 24.0;
    const CGFloat gap = 18.0;
    const CGFloat sideWidth = width >= 860.0 ? 300.0 : 260.0;
    const CGFloat leftWidth = MAX(360.0, width - margin * 2.0 - sideWidth - gap);
    CGFloat y = 24.0;

    NSView* hero = [SMFlippedView new];
    hero.translatesAutoresizingMaskIntoConstraints = YES;
    hero.frame = NSMakeRect(margin, y, width - margin * 2.0, 166.0);
    SMApplyChromeLayer(hero, 16, SMColor(1.0, 1.0, 1.0, 0.10), 0.12);
    [content addSubview:hero];

    NSImageView* cover = [NSImageView new];
    cover.translatesAutoresizingMaskIntoConstraints = YES;
    cover.frame = NSMakeRect(14, 14, 246.0, 138.0);
    cover.imageScaling = NSImageScaleProportionallyUpOrDown;
    cover.wantsLayer = YES;
    cover.layer.cornerRadius = 12.0;
    cover.layer.cornerCurve = kCACornerCurveContinuous;
    cover.layer.masksToBounds = YES;
    cover.layer.backgroundColor = SMColor(0.04, 0.05, 0.06, 1.0).CGColor;
    [hero addSubview:cover];
    NSString* coverURL = [result[@"cover"] isKindOfClass:NSString.class] ? result[@"cover"] : @"";
    [self loadBilibiliCoverURL:coverURL intoImageView:cover];

    NSTextField* title = SMLabel([result[@"title"] isKindOfClass:NSString.class] ? result[@"title"] : @"B站详情", 22, NSFontWeightBold, SMInk());
    title.translatesAutoresizingMaskIntoConstraints = YES;
    title.maximumNumberOfLines = 2;
    title.frame = NSMakeRect(280.0, 18.0, width - 360.0, 56.0);
    [hero addSubview:title];

    NSString* descText = [result[@"desc"] isKindOfClass:NSString.class] ? result[@"desc"] : @"暂无简介";
    NSTextField* desc = SMLabel(descText, 13, NSFontWeightRegular, SMMuted());
    desc.translatesAutoresizingMaskIntoConstraints = YES;
    desc.maximumNumberOfLines = 3;
    desc.frame = NSMakeRect(280.0, 80.0, width - 360.0, 52.0);
    [hero addSubview:desc];
    NSDictionary* stat = [result[@"stat"] isKindOfClass:NSDictionary.class] ? result[@"stat"] : @{};
    NSString* bvid = [result[@"bvid"] isKindOfClass:NSString.class] ? result[@"bvid"] : @"";
    NSString* statText = [NSString stringWithFormat:@"播放 %@ · 点赞 %@ · 收藏 %@ · 评论 %@",
                          [self bilibiliCountText:[stat[@"view"] isKindOfClass:NSNumber.class] ? stat[@"view"] : @0],
                          [self bilibiliCountText:[stat[@"like"] isKindOfClass:NSNumber.class] ? stat[@"like"] : @0],
                          [self bilibiliCountText:[stat[@"favorite"] isKindOfClass:NSNumber.class] ? stat[@"favorite"] : @0],
                          [self bilibiliCountText:[stat[@"reply"] isKindOfClass:NSNumber.class] ? stat[@"reply"] : @0]];
    NSTextField* statLabel = SMLabel(statText, 12, NSFontWeightSemibold, SMColor(0.80, 0.88, 1.0, 1.0));
    statLabel.translatesAutoresizingMaskIntoConstraints = YES;
    statLabel.maximumNumberOfLines = 1;
    statLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    statLabel.frame = NSMakeRect(280.0, 134.0, width - 360.0, 18.0);
    [hero addSubview:statLabel];
    y += 188.0;

    NSArray* episodes = [result[@"episodes"] isKindOfClass:NSArray.class] ? result[@"episodes"] : @[];
    CGFloat leftY = y;
    CGFloat rightY = y;
    NSTextField* commentsHeader = SMLabel(@"评论", 16, NSFontWeightSemibold, SMInk());
    commentsHeader.translatesAutoresizingMaskIntoConstraints = YES;
    commentsHeader.frame = NSMakeRect(margin, leftY, leftWidth, 22.0);
    [content addSubview:commentsHeader];
    leftY += 32.0;

    NSArray* comments = [result[@"comments"] isKindOfClass:NSArray.class] ? result[@"comments"] : @[];
    if (comments.count == 0) {
        NSTextField* empty = SMLabel(@"评论暂不可用。", 13, NSFontWeightMedium, SMMuted());
        empty.translatesAutoresizingMaskIntoConstraints = YES;
        empty.frame = NSMakeRect(margin, leftY, leftWidth, 22.0);
        [content addSubview:empty];
        leftY += 32.0;
    } else {
        for (NSDictionary* comment in comments) {
            NSString* user = [comment[@"user"] isKindOfClass:NSString.class] ? comment[@"user"] : @"B站用户";
            NSString* message = [comment[@"message"] isKindOfClass:NSString.class] ? comment[@"message"] : @"";
            NSView* card = [SMFlippedView new];
            card.translatesAutoresizingMaskIntoConstraints = YES;
            card.frame = NSMakeRect(margin, leftY, leftWidth, 72.0);
            SMApplyChromeLayer(card, 12, SMColor(1.0, 1.0, 1.0, 0.08), 0.06);
            [content addSubview:card];

            NSTextField* line = SMLabel([NSString stringWithFormat:@"%@：%@", user, message], 12, NSFontWeightRegular, SMMuted());
            line.translatesAutoresizingMaskIntoConstraints = YES;
            line.maximumNumberOfLines = 3;
            line.frame = NSMakeRect(14, 10, leftWidth - 28.0, 52.0);
            [card addSubview:line];
            leftY += 82.0;
        }
    }

    const CGFloat sideX = margin + leftWidth + gap;
    NSView* actionPanel = [SMFlippedView new];
    actionPanel.translatesAutoresizingMaskIntoConstraints = YES;
    actionPanel.frame = NSMakeRect(sideX, rightY, sideWidth, 174.0);
    SMApplyChromeLayer(actionPanel, 18, SMColor(0.76, 0.88, 1.0, 0.16), 0.16);
    [content addSubview:actionPanel];

    NSTextField* actionTitle = SMLabel(@"账号与缓存", 16, NSFontWeightSemibold, SMInk());
    actionTitle.translatesAutoresizingMaskIntoConstraints = YES;
    actionTitle.frame = NSMakeRect(16, 14, sideWidth - 32.0, 22.0);
    [actionPanel addSubview:actionTitle];

    NSTextField* actionHint = SMLabel(bvid.length > 0 ? @"点赞和收藏使用当前扫码登录态。" : @"账号点赞/收藏目前仅支持 BV 视频。", 11, NSFontWeightMedium, SMMuted());
    actionHint.translatesAutoresizingMaskIntoConstraints = YES;
    actionHint.maximumNumberOfLines = 2;
    actionHint.frame = NSMakeRect(16, 42, sideWidth - 32.0, 34.0);
    [actionPanel addSubview:actionHint];

    NSButton* likeButton = SMButton(@"点赞");
    likeButton.translatesAutoresizingMaskIntoConstraints = YES;
    likeButton.frame = NSMakeRect(16, 86, (sideWidth - 42.0) / 2.0, 30.0);
    likeButton.toolTip = fallbackURL;
    likeButton.identifier = @"like";
    likeButton.enabled = bvid.length > 0;
    likeButton.target = self;
    likeButton.action = @selector(bilibiliAccountActionButton:);
    [actionPanel addSubview:likeButton];

    NSButton* favoriteButton = SMButton(@"收藏");
    favoriteButton.translatesAutoresizingMaskIntoConstraints = YES;
    favoriteButton.frame = NSMakeRect(26 + (sideWidth - 42.0) / 2.0, 86, (sideWidth - 42.0) / 2.0, 30.0);
    favoriteButton.toolTip = fallbackURL;
    favoriteButton.identifier = @"favorite";
    favoriteButton.enabled = bvid.length > 0;
    favoriteButton.target = self;
    favoriteButton.action = @selector(bilibiliAccountActionButton:);
    [actionPanel addSubview:favoriteButton];

    NSButton* favoritesButton = SMButton(@"加载我的收藏");
    favoritesButton.translatesAutoresizingMaskIntoConstraints = YES;
    favoritesButton.frame = NSMakeRect(16, 126, sideWidth - 32.0, 30.0);
    favoritesButton.target = self;
    favoritesButton.action = @selector(loadBilibiliFavorites:);
    [actionPanel addSubview:favoritesButton];
    rightY += 194.0;

    NSTextField* epHeader = SMLabel(episodes.count > 1 ? @"选集缓存" : @"缓存", 16, NSFontWeightSemibold, SMInk());
    epHeader.translatesAutoresizingMaskIntoConstraints = YES;
    epHeader.frame = NSMakeRect(sideX, rightY, sideWidth, 22.0);
    [content addSubview:epHeader];
    rightY += 32.0;

    if (episodes.count == 0) {
        NSButton* cache = SMButton(@"缓存当前视频");
        cache.translatesAutoresizingMaskIntoConstraints = YES;
        cache.frame = NSMakeRect(sideX, rightY, sideWidth, 32);
        cache.toolTip = fallbackURL;
        cache.target = self;
        cache.action = @selector(importBilibiliEpisodeButton:);
        [content addSubview:cache];
        rightY += 44.0;
    } else {
        for (NSUInteger i = 0; i < episodes.count; ++i) {
            NSDictionary* episode = [episodes[i] isKindOfClass:NSDictionary.class] ? episodes[i] : @{};
            NSString* epTitle = [episode[@"title"] isKindOfClass:NSString.class] ? episode[@"title"] : [NSString stringWithFormat:@"第 %lu 集", static_cast<unsigned long>(i + 1)];
            NSString* epURL = [episode[@"url"] isKindOfClass:NSString.class] ? episode[@"url"] : fallbackURL;
            NSView* row = [SMFlippedView new];
            row.translatesAutoresizingMaskIntoConstraints = YES;
            row.frame = NSMakeRect(sideX, rightY, sideWidth, 58.0);
            SMApplyChromeLayer(row, 14, SMColor(1.0, 1.0, 1.0, 0.09), 0.08);
            [content addSubview:row];

            NSTextField* epLabel = SMLabel(epTitle, 12, NSFontWeightSemibold, SMInk());
            epLabel.translatesAutoresizingMaskIntoConstraints = YES;
            epLabel.lineBreakMode = NSLineBreakByTruncatingTail;
            epLabel.maximumNumberOfLines = 1;
            epLabel.frame = NSMakeRect(14, 10, sideWidth - 102.0, 20.0);
            [row addSubview:epLabel];

            NSButton* epButton = SMButton(@"缓存");
            epButton.translatesAutoresizingMaskIntoConstraints = YES;
            epButton.frame = NSMakeRect(sideWidth - 78.0, 16.0, 62.0, 26.0);
            epButton.identifier = epTitle;
            epButton.toolTip = epURL;
            epButton.target = self;
            epButton.action = @selector(importBilibiliEpisodeButton:);
            [row addSubview:epButton];
            rightY += 68.0;
        }
    }
    content.frame = NSMakeRect(0, 0, width, MAX(MAX(leftY, rightY) + 24.0, content.enclosingScrollView.contentView.bounds.size.height));
}

- (void)importBilibiliEpisodeButton:(NSButton*)sender {
    NSString* url = sender.toolTip ?: @"";
    if (url.length == 0) {
        return;
    }
    self.bilibiliURLField.stringValue = url;
    self.bilibiliSelectedIndex = -1;
    NSString* displayTitle = sender.identifier.length > 0 ? sender.identifier : sender.title;
    self.bilibiliCacheActiveTitle = displayTitle.length > 0 ? displayTitle : @"B 站选集";
    [self importBilibiliURL:sender];
}

- (void)bilibiliAccountActionButton:(NSButton*)sender {
    NSString* url = sender.toolTip ?: @"";
    NSString* action = sender.identifier.length > 0 ? sender.identifier : @"like";
    if (url.length == 0) {
        self.bilibiliStatusLabel.stringValue = @"没有可操作的视频链接";
        return;
    }
    if (self.bilibiliCookiePath.length == 0) {
        self.bilibiliStatusLabel.stringValue = @"请先扫码登录 B 站账号";
        return;
    }
    NSURL* script = [self bilibiliCacheScriptURL];
    if (script == nil) {
        self.bilibiliStatusLabel.stringValue = @"未找到 B 站缓存脚本";
        return;
    }
    sender.enabled = NO;
    NSString* oldTitle = sender.title ?: @"";
    sender.title = [action isEqualToString:@"favorite"] ? @"收藏中" : @"点赞中";
    NSMutableArray<NSString*>* args = [@[
        @"python3",
        script.path,
        @"--mode", @"action",
        @"--action", action,
        @"--url", url,
        @"--output-dir", [self bilibiliCacheDirectoryURL].path,
        @"--cookie-file", self.bilibiliCookiePath,
        @"--json",
    ] mutableCopy];
    NSPipe* pipe = [NSPipe pipe];
    NSTask* task = [NSTask new];
    task.launchPath = @"/usr/bin/env";
    task.arguments = args;
    task.standardOutput = pipe;
    task.standardError = pipe;
    MotionAppDelegate* __weak weakSelf = self;
    NSButton* __weak weakButton = sender;
    task.terminationHandler = ^(NSTask* finishedTask) {
        (void)finishedTask;
        NSData* data = [pipe.fileHandleForReading readDataToEndOfFile];
        dispatch_async(dispatch_get_main_queue(), ^{
            MotionAppDelegate* __strong self = weakSelf;
            NSButton* button = weakButton;
            if (self == nil || button == nil) {
                return;
            }
            button.enabled = YES;
            NSDictionary* result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![result isKindOfClass:NSDictionary.class] || ![result[@"ok"] boolValue]) {
                NSString* text = [result[@"error"] isKindOfClass:NSString.class] ? result[@"error"] : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                button.title = oldTitle;
                self.bilibiliStatusLabel.stringValue = [NSString stringWithFormat:@"%@失败：%@", [action isEqualToString:@"favorite"] ? @"收藏" : @"点赞", text.length > 0 ? text : @"未知错误"];
                return;
            }
            button.title = [action isEqualToString:@"favorite"] ? @"已收藏" : @"已点赞";
            self.bilibiliStatusLabel.stringValue = [NSString stringWithFormat:@"%@完成", [action isEqualToString:@"favorite"] ? @"收藏" : @"点赞"];
        });
    };
    NSError* launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        sender.enabled = YES;
        sender.title = oldTitle;
        self.bilibiliStatusLabel.stringValue = [NSString stringWithFormat:@"账号操作启动失败：%@", launchError.localizedDescription ?: @"python3 unavailable"];
    }
}

- (void)loadBilibiliFavorites:(id)sender {
    (void)sender;
    if (self.bilibiliCookiePath.length == 0) {
        self.bilibiliStatusLabel.stringValue = @"请先扫码登录 B 站账号，再加载收藏";
        return;
    }
    [self runBilibiliListMode:@"favorites" keyword:@""];
}

- (void)bilibiliSectionChanged:(id)sender {
    (void)sender;
    NSInteger segment = self.bilibiliSectionControl.selectedSegment;
    if (segment == 2) {
        self.bilibiliItems = [NSMutableArray array];
        self.bilibiliSelectedIndex = -1;
        [self rebuildBilibiliGrid];
        self.bilibiliStatusLabel.stringValue = @"UP主分区已选中，输入 UP 名称后按回车搜索。";
        return;
    }
    if (segment == 0 || segment == 1 || segment == 3 || segment == 4) {
        [self runBilibiliListMode:@"home" keyword:@""];
        return;
    }
    NSString* keyword = [self.bilibiliSearchField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (keyword.length == 0) {
        self.bilibiliStatusLabel.stringValue = @"请输入搜索关键词。";
        return;
    }
    [self runBilibiliListMode:@"search" keyword:keyword];
}

- (NSView*)buildPlaylistCard {
    SMGlassCard card = SMGlass(NO, kCardRadius, nil);
    NSStackView* stack = SMVStack(10);
    SMInstallInCard(card.content, stack, 14);

    NSStackView* header = SMHStack(10);
    [stack addArrangedSubview:header];
    [header.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    NSTextField* cap = SMCapsLabel(@"LIB");
    cap.maximumNumberOfLines = 1;
    cap.lineBreakMode = NSLineBreakByClipping;
    [header addArrangedSubview:cap];
    [cap.widthAnchor constraintEqualToConstant:28.0].active = YES;
    NSTextField* title = SMLabel(@"本地媒体库", 15, NSFontWeightSemibold, SMInk());
    title.maximumNumberOfLines = 1;
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    [header addArrangedSubview:title];
    NSView* spacer = [NSView new];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [header addArrangedSubview:spacer];
    NSButton* addButton = SMButton(@"添加");
    addButton.target = self;
    addButton.action = @selector(importVideo:);
    [header addArrangedSubview:addButton];
    NSButton* removeButton = SMButton(@"移除");
    removeButton.target = self;
    removeButton.action = @selector(removeSelectedPlaylistItem:);
    [header addArrangedSubview:removeButton];

    self.playlistTableView = [NSTableView new];
    self.playlistTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.playlistTableView.headerView = nil;
    self.playlistTableView.rowHeight = 76.0;
    self.playlistTableView.intercellSpacing = NSMakeSize(0.0, 10.0);
    self.playlistTableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    self.playlistTableView.delegate = self;
    self.playlistTableView.dataSource = self;
    self.playlistTableView.target = self;
    self.playlistTableView.doubleAction = @selector(playSelectedPlaylistItem:);
    NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"path"];
    column.title = @"视频";
    column.width = 292.0;
    column.minWidth = 220.0;
    column.resizingMask = NSTableColumnAutoresizingMask;
    [self.playlistTableView addTableColumn:column];

    NSScrollView* scroll = [NSScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSNoBorder;
    scroll.documentView = self.playlistTableView;
    [stack addArrangedSubview:scroll];
    [scroll.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    [scroll.heightAnchor constraintGreaterThanOrEqualToConstant:96].active = YES;
    [self.playlistTableView reloadData];
    return card.view;
}

- (NSView*)buildExportSourceCard {
    SMGlassCard card = SMGlass(NO, kCardRadius, nil);
    NSStackView* stack = SMVStack(8);
    SMInstallInCard(card.content, stack, 14);

    [stack addArrangedSubview:SMCapsLabel(@"Source")];
    [stack addArrangedSubview:SMLabel(@"导出源视频", 16, NSFontWeightSemibold, SMInk())];
    self.importedFileLabel = SMLabel(self.importedPath.length > 0 ? self.importedPath.lastPathComponent : @"尚未选择文件", 12, NSFontWeightRegular, SMMuted());
    [stack addArrangedSubview:self.importedFileLabel];

    NSButton* importButton = SMButton(@"导入视频");
    importButton.target = self;
    importButton.action = @selector(importVideo:);
    [stack addArrangedSubview:importButton];
    return card.view;
}

- (NSView*)buildExportCard {
    SMGlassCard card = SMGlass(NO, kCardRadius, nil);
    NSStackView* stack = SMVStack(8);
    SMInstallInCard(card.content, stack, 14);

    [stack addArrangedSubview:SMCapsLabel(@"Output")];
    [stack addArrangedSubview:SMLabel(@"预览与导出", 16, NSFontWeightSemibold, SMInk())];
    self.exportStatusLabel = SMLabel(@"离线最高质量 · 等待任务", 12, NSFontWeightRegular, SMMuted());
    [stack addArrangedSubview:self.exportStatusLabel];

    self.upscalePopup = [NSPopUpButton new];
    self.upscalePopup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.upscalePopup addItemsWithTitles:@[@"导出 1x", @"超分 2x"]];
    [self.upscalePopup selectItemAtIndex:1];
    self.upscalePopup.controlSize = NSControlSizeSmall;
    [stack addArrangedSubview:self.upscalePopup];
    [self.upscalePopup.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;

    self.exportProgress = [NSProgressIndicator new];
    self.exportProgress.translatesAutoresizingMaskIntoConstraints = NO;
    self.exportProgress.indeterminate = NO;
    self.exportProgress.minValue = 0.0;
    self.exportProgress.maxValue = 100.0;
    self.exportProgress.doubleValue = 0.0;
    [stack addArrangedSubview:self.exportProgress];
    [self.exportProgress.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;

    self.offlineTargetFpsSlider = [self addSliderToStack:stack
                                                   title:@"离线导出 FPS"
                                                     min:24
                                                     max:240
                                                   value:[NSUserDefaults.standardUserDefaults doubleForKey:@"motion.offlineTargetFps"]
                                                  suffix:@"fps"
                                               precision:0];

    NSButton* exportButton = SMButton(@"开始导出");
    exportButton.target = self;
    exportButton.action = @selector(startExport:);
    [stack addArrangedSubview:exportButton];
    return card.view;
}

- (NSView*)buildBrowserPage {
    NSView* page = [self pageShellWithTitle:@"浏览器视频捕获"
                                   subtitle:@"Google Chrome 扩展只捕获浏览器视频流；App 负责本地推理、控时序和网页原位回推。DRM 内容明确不绕过。"
                                  telemetry:@[@"AGENT|Chrome", @"MODE|Browser stream", @"DRM|Policy"]];
    NSStackView* stack = [self pageStackInPage:page];

    SMGlassCard statusCard = SMGlass(YES, kPanelRadius, nil);
    [stack addArrangedSubview:statusCard.view];
    [statusCard.view.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    SMSetMinHeight(statusCard.view, 320);

    NSStackView* inner = SMVStack(16);
    SMInstallInCard(statusCard.content, inner, 18);
    [inner addArrangedSubview:SMLabel(@"捕获控制台", 20, NSFontWeightSemibold, SMInk())];
    NSTextField* browserIntro = SMLabel(@"Native Messaging Host 已随 App 打包。加载 Google Chrome 扩展后，这里会接收 video rect、currentSrc、seek、pause、playbackRate 和 fullscreen 状态。", 13, NSFontWeightRegular, SMMuted());
    browserIntro.maximumNumberOfLines = 2;
    [inner addArrangedSubview:browserIntro];

    NSStackView* actionRow = SMVStack(10);
    [inner addArrangedSubview:actionRow];
    [actionRow.widthAnchor constraintEqualToAnchor:inner.widthAnchor].active = YES;
    NSStackView* buttonRow = SMHStack(10);
    [actionRow addArrangedSubview:buttonRow];
    self.browserStartButton = SMButton(@"启动在线插帧");
    self.browserStartButton.target = self;
    self.browserStartButton.action = @selector(startOnlineInterpolation:);
    [buttonRow addArrangedSubview:self.browserStartButton];
    self.browserStopButton = SMButton(@"停止");
    self.browserStopButton.target = self;
    self.browserStopButton.action = @selector(stopOnlineInterpolation:);
    [buttonRow addArrangedSubview:self.browserStopButton];
    self.screenPermissionButton = SMButton(@"屏幕录制权限");
    self.screenPermissionButton.target = self;
    self.screenPermissionButton.action = @selector(openScreenCaptureSettings:);
    [buttonRow addArrangedSubview:self.screenPermissionButton];
    NSTextField* actionHint = SMLabel(@"使用浏览器视频流做本地插帧，增强结果回推到网页原位置。", 12, NSFontWeightRegular, SMMuted());
    actionHint.maximumNumberOfLines = 2;
    [actionRow addArrangedSubview:actionHint];
    self.browserStatusHintLabel = SMLabel(@"浏览器插帧状态：等待扩展消息。视频右上角也会显示连接与回推状态。", 12, NSFontWeightMedium, SMColor(0.72, 0.84, 1.0, 1.0));
    self.browserStatusHintLabel.maximumNumberOfLines = 2;
    [actionRow addArrangedSubview:self.browserStatusHintLabel];

    NSStackView* rows = SMVStack(10);
    [inner addArrangedSubview:rows];
    [rows.widthAnchor constraintEqualToAnchor:inner.widthAnchor].active = YES;
    NSTextField* agentStatus = nil;
    NSTextField* captureStatus = nil;
    NSTextField* policyStatus = nil;
    NSView* agentPill = [self statusPill:@"Browser Agent" value:@"待连接" detail:@"Google Chrome" valueLabel:&agentStatus];
    NSView* capturePill = [self statusPill:@"捕获模式" value:@"自动选择" detail:@"Browser stream" valueLabel:&captureStatus];
    NSView* policyPill = [self statusPill:@"DRM Policy" value:@"拒绝绕过" detail:@"Protected media" valueLabel:&policyStatus];
    [rows addArrangedSubview:agentPill];
    [rows addArrangedSubview:capturePill];
    [rows addArrangedSubview:policyPill];
    [agentPill.widthAnchor constraintEqualToAnchor:rows.widthAnchor].active = YES;
    [capturePill.widthAnchor constraintEqualToAnchor:rows.widthAnchor].active = YES;
    [policyPill.widthAnchor constraintEqualToAnchor:rows.widthAnchor].active = YES;
    self.browserAgentStatusLabel = agentStatus;
    self.browserCaptureStatusLabel = captureStatus;
    self.browserPolicyStatusLabel = policyStatus;

    NSStackView* monitorColumn = SMVStack(12);
    [inner addArrangedSubview:monitorColumn];
    [monitorColumn.widthAnchor constraintEqualToAnchor:inner.widthAnchor].active = YES;

    SMGlassCard preview = SMGlass(NO, 18, nil);
    [monitorColumn addArrangedSubview:preview.view];
    [preview.view.widthAnchor constraintEqualToAnchor:monitorColumn.widthAnchor].active = YES;
    SMSetMinHeight(preview.view, 138);
    NSStackView* previewInner = SMVStack(9);
    SMInstallInCard(preview.content, previewInner, 14);
    [previewInner addArrangedSubview:SMLabel(@"浏览器视频", 16, NSFontWeightSemibold, SMInk())];
    self.browserAgentLabel = SMLabel(@"状态  等待浏览器扩展", 12, NSFontWeightMedium, SMMuted());
    self.browserSourceLabel = SMLabel(@"页面  --", 12, NSFontWeightRegular, SMMuted());
    self.browserRectLabel = SMLabel(@"区域  --", 12, NSFontWeightRegular, SMMuted());
    self.browserModeLabel = SMLabel(@"捕获  未启动", 12, NSFontWeightRegular, SMMuted());
    self.browserSourceLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.browserSourceLabel.maximumNumberOfLines = 1;
    self.browserModeLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.browserModeLabel.maximumNumberOfLines = 1;
    [previewInner addArrangedSubview:self.browserAgentLabel];
    [previewInner addArrangedSubview:self.browserSourceLabel];
    [previewInner addArrangedSubview:self.browserRectLabel];
    [previewInner addArrangedSubview:self.browserModeLabel];

    SMGlassCard diagnostics = SMGlass(NO, 18, nil);
    [monitorColumn addArrangedSubview:diagnostics.view];
    [diagnostics.view.widthAnchor constraintEqualToAnchor:monitorColumn.widthAnchor].active = YES;
    SMSetMinHeight(diagnostics.view, 138);
    NSStackView* diagInner = SMVStack(8);
    SMInstallInCard(diagnostics.content, diagInner, 14);
    [diagInner addArrangedSubview:SMLabel(@"浏览器回推诊断", 15, NSFontWeightSemibold, SMInk())];
    self.browserReadyLabel = SMLabel(@"播放  --", 11, NSFontWeightMedium, SMMuted());
    self.browserVideoSizeLabel = SMLabel(@"视频  --", 11, NSFontWeightMedium, SMMuted());
    self.browserDriftLabel = SMLabel(@"输入  --", 11, NSFontWeightMedium, SMMuted());
    self.browserPipelineLabel = SMLabel(@"输出  --", 11, NSFontWeightMedium, SMMuted());
    self.browserQueueLabel = SMLabel(@"队列  0", 11, NSFontWeightMedium, SMMuted());
    self.browserProtectionLabel = SMLabel(@"保护  --", 11, NSFontWeightMedium, SMMuted());
    for (NSTextField* label in @[self.browserReadyLabel, self.browserVideoSizeLabel, self.browserDriftLabel, self.browserPipelineLabel, self.browserQueueLabel, self.browserProtectionLabel]) {
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        label.maximumNumberOfLines = 1;
    }
    [diagInner addArrangedSubview:self.browserReadyLabel];
    [diagInner addArrangedSubview:self.browserVideoSizeLabel];
    [diagInner addArrangedSubview:self.browserDriftLabel];
    [diagInner addArrangedSubview:self.browserPipelineLabel];
    [diagInner addArrangedSubview:self.browserQueueLabel];
    [diagInner addArrangedSubview:self.browserProtectionLabel];
    [self refreshBrowserState:nil];

    return page;
}

- (NSView*)statusPill:(NSString*)title value:(NSString*)value detail:(NSString*)detail valueLabel:(NSTextField**)valueLabel {
    SMGlassCard pill = SMGlass(NO, 16, nil);
    NSStackView* stack = SMVStack(5);
    SMInstallInCard(pill.content, stack, 12);
    [stack addArrangedSubview:SMCapsLabel(title)];
    NSTextField* mainValue = SMLabel(value, 15, NSFontWeightSemibold, SMInk());
    [stack addArrangedSubview:mainValue];
    if (valueLabel != nullptr) {
        *valueLabel = mainValue;
    }
    [stack addArrangedSubview:SMLabel(detail, 11, NSFontWeightRegular, SMMuted())];
    [pill.view.widthAnchor constraintGreaterThanOrEqualToConstant:96].active = YES;
    SMSetFixedHeight(pill.view, 78);
    return pill.view;
}

- (NSView*)buildSettingsPage {
    NSView* page = [self pageShellWithTitle:@"专业设置"
                                   subtitle:@"实时播放器、离线导出和浏览器回推共享同一套运行配置；浏览器相关入口统一收在这里。"
                                  telemetry:@[]];
    NSStackView* stack = [self pageStackInPage:page];

    SMGlassCard panel = SMGlass(YES, kPanelRadius, nil);
    [stack addArrangedSubview:panel.view];
    [panel.view.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    SMSetMinHeight(panel.view, 570);

    NSStackView* columns = SMHStack(24);
    SMInstallInCard(panel.content, columns, 18);

    NSStackView* left = SMVStack(11);
    NSStackView* right = SMVStack(11);
    [columns addArrangedSubview:left];
    [columns addArrangedSubview:right];
    [left.widthAnchor constraintEqualToAnchor:right.widthAnchor].active = YES;

    [left addArrangedSubview:SMCapsLabel(@"Realtime")];
    [left addArrangedSubview:SMLabel(@"性能", 17, NSFontWeightSemibold, SMInk())];
    [left addArrangedSubview:SMLabel(@"实时输出帧率", 12, NSFontWeightMedium, SMMuted())];
    self.realtimeFpsPopup = [self popupWithItems:@[@"60 fps", @"120 fps"]];
    [left addArrangedSubview:self.realtimeFpsPopup];
    self.realtimeTierHintLabel = SMLabel(@"Flow 输入高度与性能预算由模型和档位自动决定。", 12, NSFontWeightMedium, SMColor(0.72, 0.84, 1.0, 1.0));
    self.realtimeTierHintLabel.maximumNumberOfLines = 3;
    [left addArrangedSubview:self.realtimeTierHintLabel];
    self.flowHeightSlider = [self addSliderToStack:left title:@"Flow 输入高度" min:128 max:1440 value:540 suffix:@"p" precision:0];
    self.gpuBudgetSlider = [self addSliderToStack:left title:@"性能预算" min:4 max:40 value:24 suffix:@"ms" precision:1];
    [left addArrangedSubview:SMDivider()];

    [left addArrangedSubview:SMCapsLabel(@"Content")];
    [left addArrangedSubview:SMLabel(@"运行模式", 17, NSFontWeightSemibold, SMInk())];
    self.presetPopup = [self popupWithItems:@[@"Adaptive", @"Ultimate"]];
    [left addArrangedSubview:self.presetPopup];
    [left addArrangedSubview:SMLabel(@"Adaptive 档位", 17, NSFontWeightSemibold, SMInk())];
    self.powerTierPopup = [self popupWithItems:@[@"静音", @"均衡", @"质量"]];
    [left addArrangedSubview:self.powerTierPopup];
    NSControl* lineArtSwitch = nil;
    [left addArrangedSubview:[self switchRow:@"线稿保护" on:YES control:&lineArtSwitch]];
    self.lineArtSwitch = lineArtSwitch;
    NSControl* subtitleSwitch = nil;
    [left addArrangedSubview:[self switchRow:@"字幕/弹幕保护" on:YES control:&subtitleSwitch]];
    self.subtitleSwitch = subtitleSwitch;
    NSControl* edgeAwareSwitch = nil;
    [left addArrangedSubview:[self switchRow:@"边缘感知 Flow 放大" on:YES control:&edgeAwareSwitch]];
    self.edgeAwareSwitch = edgeAwareSwitch;
    [left addArrangedSubview:SMDivider()];

    [right addArrangedSubview:SMCapsLabel(@"Motion Safety")];
    [right addArrangedSubview:SMLabel(@"画面保护", 17, NSFontWeightSemibold, SMInk())];
    self.refineStrengthSlider = [self addSliderToStack:right title:@"Refine 强度" min:0 max:1 value:0.55 suffix:@"" precision:2];
    [right addArrangedSubview:SMDivider()];

    [right addArrangedSubview:SMCapsLabel(@"Model")];
    [right addArrangedSubview:SMLabel(@"模型与回传", 17, NSFontWeightSemibold, SMInk())];
    NSStackView* selectors = SMHStack(10);
    [right addArrangedSubview:selectors];
    self.modelPopup = [self popupWithItems:@[@"基础插帧",
                                             @"RIFE兼容",
                                             @"RIFE加速",
                                             @"RIFE加速增强"]];
    [selectors addArrangedSubview:self.modelPopup];
    NSControl* noReadbackSwitch = nil;
    [right addArrangedSubview:[self switchRow:@"禁止 CPU texture readback" on:YES control:&noReadbackSwitch]];
    self.noReadbackSwitch = noReadbackSwitch;
    NSControl* diagnosticOverlaySwitch = nil;
    [right addArrangedSubview:[self switchRow:@"浏览器详细诊断浮层" on:NO control:&diagnosticOverlaySwitch]];
    self.diagnosticOverlaySwitch = diagnosticOverlaySwitch;
    NSControl* hevcMotionHintsSwitch = nil;
    [right addArrangedSubview:[self switchRow:@"HEVC 运动提示优化" on:YES control:&hevcMotionHintsSwitch]];
    self.hevcMotionHintsSwitch = hevcMotionHintsSwitch;
    NSControl* roiMotionBlocksSwitch = nil;
    [right addArrangedSubview:[self switchRow:@"实验性 ROI 运动块" on:NO control:&roiMotionBlocksSwitch]];
    self.roiMotionBlocksSwitch = roiMotionBlocksSwitch;

    [self loadSettingsIntoControls];

    NSView* browserPanel = [self buildBrowserSettingsPanel];
    [stack addArrangedSubview:browserPanel];
    [browserPanel.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    SMSetMinHeight(browserPanel, 490);
    [self refreshBrowserState:nil];

    return page;
}

- (NSView*)buildBrowserSettingsPanel {
    SMGlassCard panel = SMGlass(YES, kPanelRadius, nil);
    NSStackView* inner = SMVStack(14);
    SMInstallInCard(panel.content, inner, 18);

    [inner addArrangedSubview:SMCapsLabel(@"Browser")];
    [inner addArrangedSubview:SMLabel(@"浏览器回推与兼容入口", 18, NSFontWeightSemibold, SMInk())];
    NSTextField* intro = SMLabel(@"Google Chrome 扩展只提供视频事实与回推通道；本地播放器仍是首要实时插帧入口，DRM 内容不绕过。", 12, NSFontWeightRegular, SMMuted());
    intro.maximumNumberOfLines = 2;
    [inner addArrangedSubview:intro];

    self.browserStartButton = nil;
    self.browserStopButton = nil;
    self.screenPermissionButton = nil;
    NSControl* browserEnableSwitch = nil;
    NSView* browserSwitchRow = [self switchRow:@"浏览器在线插帧" on:self.browserOnlineRequested control:&browserEnableSwitch];
    self.browserEnableSwitch = browserEnableSwitch;
    [inner addArrangedSubview:browserSwitchRow];
    const double storedReturnBitrate = [NSUserDefaults.standardUserDefaults doubleForKey:@"motion.browserReturnBitrateMbps"];
    self.browserReturnBitrateSlider = [self addSliderToStack:inner title:@"回推码率" min:12 max:120 value:(storedReturnBitrate > 0.0 ? storedReturnBitrate : 60.0) suffix:@" Mbps" precision:0];
    self.browserReturnBitrateHintLabel = SMLabel(@"低码率更省浏览器解码与网络缓存压力，但高速运动会更容易糊和出块；高码率画质更稳，但会增加回推带宽、浏览器解码压力和功耗。", 12, NSFontWeightRegular, SMMuted());
    self.browserReturnBitrateHintLabel.maximumNumberOfLines = 3;
    [inner addArrangedSubview:self.browserReturnBitrateHintLabel];

    NSStackView* rows = SMVStack(10);
    [inner addArrangedSubview:rows];
    [rows.widthAnchor constraintEqualToAnchor:inner.widthAnchor].active = YES;
    NSTextField* agentStatus = nil;
    NSTextField* captureStatus = nil;
    NSTextField* policyStatus = nil;
    NSView* agentPill = [self statusPill:@"Browser Agent" value:@"待连接" detail:@"Google Chrome" valueLabel:&agentStatus];
    NSView* capturePill = [self statusPill:@"回推模式" value:@"自动选择" detail:@"Browser stream" valueLabel:&captureStatus];
    NSView* policyPill = [self statusPill:@"DRM Policy" value:@"拒绝绕过" detail:@"Protected media" valueLabel:&policyStatus];
    [rows addArrangedSubview:agentPill];
    [rows addArrangedSubview:capturePill];
    [rows addArrangedSubview:policyPill];
    [agentPill.widthAnchor constraintEqualToAnchor:rows.widthAnchor].active = YES;
    [capturePill.widthAnchor constraintEqualToAnchor:rows.widthAnchor].active = YES;
    [policyPill.widthAnchor constraintEqualToAnchor:rows.widthAnchor].active = YES;
    self.browserAgentStatusLabel = agentStatus;
    self.browserCaptureStatusLabel = captureStatus;
    self.browserPolicyStatusLabel = policyStatus;

    SMGlassCard diagnostics = SMGlass(NO, 18, nil);
    [inner addArrangedSubview:diagnostics.view];
    [diagnostics.view.widthAnchor constraintEqualToAnchor:inner.widthAnchor].active = YES;
    SMSetMinHeight(diagnostics.view, 158);
    NSStackView* diagInner = SMVStack(8);
    SMInstallInCard(diagnostics.content, diagInner, 14);
    [diagInner addArrangedSubview:SMLabel(@"浏览器回推诊断", 15, NSFontWeightSemibold, SMInk())];
    self.browserAgentLabel = SMLabel(@"状态  等待浏览器扩展", 12, NSFontWeightMedium, SMMuted());
    self.browserSourceLabel = SMLabel(@"页面  --", 12, NSFontWeightRegular, SMMuted());
    self.browserRectLabel = SMLabel(@"区域  --", 12, NSFontWeightRegular, SMMuted());
    self.browserModeLabel = SMLabel(@"捕获  未启动", 12, NSFontWeightRegular, SMMuted());
    self.browserReadyLabel = SMLabel(@"播放  --", 11, NSFontWeightMedium, SMMuted());
    self.browserVideoSizeLabel = SMLabel(@"视频  --", 11, NSFontWeightMedium, SMMuted());
    self.browserDriftLabel = SMLabel(@"输入  --", 11, NSFontWeightMedium, SMMuted());
    self.browserPipelineLabel = SMLabel(@"输出  --", 11, NSFontWeightMedium, SMMuted());
    self.browserQueueLabel = SMLabel(@"队列  0", 11, NSFontWeightMedium, SMMuted());
    self.browserProtectionLabel = SMLabel(@"保护  --", 11, NSFontWeightMedium, SMMuted());
    self.browserStatusHintLabel = SMLabel(@"浏览器插帧状态：等待扩展消息。", 12, NSFontWeightMedium, SMColor(0.72, 0.84, 1.0, 1.0));
    for (NSTextField* label in @[self.browserAgentLabel, self.browserSourceLabel, self.browserRectLabel, self.browserModeLabel, self.browserReadyLabel, self.browserVideoSizeLabel, self.browserDriftLabel, self.browserPipelineLabel, self.browserQueueLabel, self.browserProtectionLabel, self.browserStatusHintLabel]) {
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        label.maximumNumberOfLines = 1;
        [diagInner addArrangedSubview:label];
    }
    return panel.view;
}

- (NSView*)buildPerformanceSettingsCard {
    SMGlassCard card = SMGlass(YES, kCardRadius, nil);
    NSStackView* stack = SMVStack(13);
    SMInstallInCard(card.content, stack, 16);
    [stack addArrangedSubview:SMCapsLabel(@"Realtime")];
    [stack addArrangedSubview:SMLabel(@"性能", 19, NSFontWeightSemibold, SMInk())];
    [stack addArrangedSubview:SMLabel(@"实时输出帧率由播放器档位控制；SP4 增强后端可选 60/120fps。", 12, NSFontWeightRegular, SMMuted())];
    [stack addArrangedSubview:SMLabel(@"Flow 输入高度与性能预算由档位自动决定；仅 RIFE加速增强 + Ultimate 展开手动项。", 12, NSFontWeightMedium, SMColor(0.72, 0.84, 1.0, 1.0))];
    SMSetFixedHeight(card.view, 212);
    return card.view;
}

- (NSView*)buildPresetSettingsCard {
    SMGlassCard card = SMGlass(YES, kCardRadius, nil);
    NSStackView* stack = SMVStack(13);
    SMInstallInCard(card.content, stack, 16);
    [stack addArrangedSubview:SMCapsLabel(@"Content")];
    [stack addArrangedSubview:SMLabel(@"预设", 19, NSFontWeightSemibold, SMInk())];

    NSPopUpButton* profile = [NSPopUpButton new];
    profile.translatesAutoresizingMaskIntoConstraints = NO;
    [profile addItemsWithTitles:@[@"Adaptive", @"Ultimate"]];
    [stack addArrangedSubview:profile];
    [profile.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;

    [stack addArrangedSubview:[self switchRow:@"线稿保护" on:YES]];
    [stack addArrangedSubview:[self switchRow:@"字幕/弹幕保护" on:YES]];
    [stack addArrangedSubview:[self switchRow:@"边缘感知 Flow 放大" on:YES]];
    [stack addArrangedSubview:[self switchRow:@"切镜强制不插帧" on:YES]];
    SMSetFixedHeight(card.view, 204);
    return card.view;
}

- (NSView*)buildAdvancedSettingsCard {
    SMGlassCard card = SMGlass(YES, kCardRadius, nil);
    NSStackView* stack = SMVStack(13);
    SMInstallInCard(card.content, stack, 16);
    [stack addArrangedSubview:SMCapsLabel(@"Motion Safety")];
    [stack addArrangedSubview:SMLabel(@"画面保护", 19, NSFontWeightSemibold, SMInk())];
    [self addSliderToStack:stack title:@"Refine 强度" min:0 max:1 value:0.55 suffix:@"" precision:2];
    SMSetFixedHeight(card.view, 120);
    return card.view;
}

- (NSView*)buildGeekModelCard {
    SMGlassCard card = SMGlass(NO, kCardRadius, nil);
    NSStackView* stack = SMVStack(12);
    SMInstallInCard(card.content, stack, 16);
    [stack addArrangedSubview:SMCapsLabel(@"Model")];
    [stack addArrangedSubview:SMLabel(@"模型与回传", 19, NSFontWeightSemibold, SMInk())];

    NSStackView* selectors = SMHStack(10);
    [stack addArrangedSubview:selectors];
    [selectors addArrangedSubview:[self popupWithItems:@[@"RIFE加速增强"]]];
    [stack addArrangedSubview:[self switchRow:@"禁止 CPU texture readback" on:YES]];
    SMSetFixedHeight(card.view, 150);
    return card.view;
}

- (NSView*)buildDiagnosticsCard {
    SMGlassCard card = SMGlass(NO, kCardRadius, nil);
    NSStackView* stack = SMVStack(12);
    SMInstallInCard(card.content, stack, 16);
    [stack addArrangedSubview:SMCapsLabel(@"Diagnostics")];
    [stack addArrangedSubview:SMLabel(@"实时状态在浏览器面板显示", 19, NSFontWeightSemibold, SMInk())];
    SMSetFixedHeight(card.view, 92);
    return card.view;
}

- (NSPopUpButton*)popupWithItems:(NSArray<NSString*>*)items {
    NSPopUpButton* popup = [NSPopUpButton new];
    popup.translatesAutoresizingMaskIntoConstraints = NO;
    [popup addItemsWithTitles:items];
    popup.target = self;
    popup.action = @selector(settingControlChanged:);
    [popup.widthAnchor constraintGreaterThanOrEqualToConstant:180].active = YES;
    return popup;
}

- (SMValueSlider*)addSliderToStack:(NSStackView*)stack title:(NSString*)title min:(double)min max:(double)max value:(double)value suffix:(NSString*)suffix precision:(NSInteger)precision {
    NSTextField* label = SMLabel(@"", 12, NSFontWeightMedium, SMMuted());
    SMValueSlider* slider = [[SMValueSlider alloc] init];
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    slider.minValue = min;
    slider.maxValue = max;
    slider.doubleValue = value;
    slider.labelTitle = title;
    slider.suffix = suffix;
    slider.precision = precision;
    slider.valueLabel = label;
    slider.target = self;
    slider.action = @selector(sliderChanged:);
    slider.continuous = YES;
    [slider refreshLabel];

    [stack addArrangedSubview:label];
    [stack addArrangedSubview:slider];
    [slider.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    return slider;
}

- (void)sliderChanged:(SMValueSlider*)slider {
    [slider refreshLabel];
    if (slider == self.targetFpsSlider || slider == self.frameMultiplierSlider) {
        [self refreshInterpolationModeControls];
    }
    if (slider == self.flowHeightSlider || slider == self.gpuBudgetSlider) {
        [self refreshRealtimeTierControls];
    }
    [self saveSettingsFromControls];
}

- (void)interpolationModeChanged:(NSSegmentedControl*)sender {
    (void)sender;
    [self refreshInterpolationModeControls];
    [self saveSettingsFromControls];
}

- (double)currentSourceFPS {
    if (self.importedPath.length == 0) {
        return 30.0;
    }
    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:self.importedPath] options:nil];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVAssetTrack* track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
#pragma clang diagnostic pop
    if (track != nil && track.nominalFrameRate > 1.0f) {
        return track.nominalFrameRate;
    }
    return 30.0;
}

- (void)refreshInterpolationModeControls {
    if (self.realtimeFpsPopup != nil) {
        [self refreshRuntimeModeControlsForModel];
    }
}

- (NSView*)switchRow:(NSString*)title on:(BOOL)on {
    return [self switchRow:title on:on control:nullptr];
}

- (NSView*)switchRow:(NSString*)title on:(BOOL)on control:(NSControl* __strong *)control {
    NSStackView* row = SMHStack(8);
    [row.widthAnchor constraintGreaterThanOrEqualToConstant:220].active = YES;
    NSTextField* label = SMLabel(title, 12, NSFontWeightMedium, SMInk());
    [row addArrangedSubview:label];
    NSView* spacer = [NSView new];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [row addArrangedSubview:spacer];
    if (@available(macOS 10.15, *)) {
        NSSwitch* toggle = [NSSwitch new];
        toggle.translatesAutoresizingMaskIntoConstraints = NO;
        toggle.state = on ? NSControlStateValueOn : NSControlStateValueOff;
        toggle.target = self;
        toggle.action = @selector(settingControlChanged:);
        if (control != nullptr) {
            *control = toggle;
        }
        [row addArrangedSubview:toggle];
    } else {
        NSButton* toggle = SMButton(@"", NSButtonTypeSwitch);
        toggle.state = on ? NSControlStateValueOn : NSControlStateValueOff;
        toggle.target = self;
        toggle.action = @selector(settingControlChanged:);
        if (control != nullptr) {
            *control = toggle;
        }
        [row addArrangedSubview:toggle];
    }
    return row;
}

- (void)settingControlChanged:(id)sender {
    if (sender == self.browserEnableSwitch) {
        if ([self stateOfControl:self.browserEnableSwitch fallback:NO]) {
            [self startOnlineInterpolation:sender];
        } else {
            [self stopOnlineInterpolation:sender];
        }
        return;
    }
    if (sender == self.modelPopup) {
        [self refreshRuntimeModeControlsForModel];
    }
    if (sender == self.presetPopup || sender == self.powerTierPopup || sender == self.modelPopup || sender == self.realtimeFpsPopup) {
        [self applyPresetToControls];
    }
    [self saveSettingsFromControls];
}

- (BOOL)enhancedEfficiencyModelSelected {
    return NO;
}

- (void)replacePopup:(NSPopUpButton*)popup
           withItems:(NSArray<NSString*>*)items
        selectedHint:(NSString*)selectedHint
       fallbackIndex:(NSInteger)fallbackIndex {
    if (popup == nil) {
        return;
    }
    NSString* prior = selectedHint ?: popup.titleOfSelectedItem ?: @"";
    [popup removeAllItems];
    [popup addItemsWithTitles:items];
    NSInteger selected = MAX(0, MIN(static_cast<NSInteger>(items.count) - 1, fallbackIndex));
    for (NSInteger i = 0; i < static_cast<NSInteger>(items.count); ++i) {
        NSString* item = items[static_cast<NSUInteger>(i)];
        if ((prior.length > 0 && [item localizedCaseInsensitiveContainsString:prior]) ||
            ([prior localizedCaseInsensitiveContainsString:@"质量"] && [item localizedCaseInsensitiveContainsString:@"质量"]) ||
            ([prior localizedCaseInsensitiveContainsString:@"效率"] && [item localizedCaseInsensitiveContainsString:@"效率"]) ||
            ([prior localizedCaseInsensitiveContainsString:@"均衡"] && [item localizedCaseInsensitiveContainsString:@"均衡"]) ||
            ([prior localizedCaseInsensitiveContainsString:@"静音"] && [item localizedCaseInsensitiveContainsString:@"静音"])) {
            selected = i;
            break;
        }
    }
    [popup selectItemAtIndex:selected];
}

- (void)refreshRuntimeModeControlsForModel {
    if (self.presetPopup == nil || self.powerTierPopup == nil) {
        return;
    }
    NSString* priorPreset = self.presetPopup.titleOfSelectedItem ?: @"Adaptive";
    NSString* priorTier = self.powerTierPopup.titleOfSelectedItem ?: @"均衡";
    const BOOL browserActive = [self browserRealtimeRestrictionsActive];
    [self replacePopup:self.presetPopup
             withItems:(browserActive ? @[@"Adaptive"] : @[@"Adaptive", @"Ultimate"])
          selectedHint:priorPreset
         fallbackIndex:0];
    self.presetPopup.enabled = !browserActive;
    NSInteger tierFallback = [priorTier localizedCaseInsensitiveContainsString:@"静音"] ? 0 : 1;
    if (!browserActive && [priorTier localizedCaseInsensitiveContainsString:@"质量"]) {
        tierFallback = 2;
    }
    [self replacePopup:self.powerTierPopup
             withItems:(browserActive ? @[@"静音", @"均衡"] : @[@"静音", @"均衡", @"质量"])
          selectedHint:priorTier
         fallbackIndex:tierFallback];
    if (self.realtimeFpsPopup != nil) {
        const BOOL sp4 = [[self currentRIFEBackendIdentifier] isEqualToString:@"stellaria_sp4_a1p"];
        self.realtimeFpsPopup.enabled = sp4 && !browserActive;
        if (!sp4 || browserActive) {
            [self.realtimeFpsPopup selectItemAtIndex:0];
        }
    }
    [self refreshRealtimeTierControls];
}

- (void)applyPresetToControls {
    if (self.presetPopup == nil || self.suppressSettingsSave) {
        return;
    }

    [self refreshRuntimeModeControlsForModel];
    const BOOL ultimate = self.presetPopup.indexOfSelectedItem == 1;
    const NSInteger tier = self.powerTierPopup != nil ? self.powerTierPopup.indexOfSelectedItem : 1;
    const BOOL browserActive = [self browserRealtimeRestrictionsActive];

    self.suppressSettingsSave = YES;
    self.presetPopup.enabled = !browserActive;
    self.powerTierPopup.enabled = !ultimate;
    if (ultimate) {
        self.flowHeightSlider.doubleValue = [[self currentRIFEBackendIdentifier] isEqualToString:@"stellaria_sp4_a1p"] ? 720.0 : 1440.0;
        self.gpuBudgetSlider.doubleValue = 40.0;
        self.refineStrengthSlider.doubleValue = 0.90;
        [self setControl:self.lineArtSwitch boolValue:NO];
        [self setControl:self.subtitleSwitch boolValue:YES];
        [self setControl:self.edgeAwareSwitch boolValue:YES];
    } else if (tier == 0) {
        self.flowHeightSlider.doubleValue = [[self currentRIFEBackendIdentifier] isEqualToString:@"stellaria_sp4_a1p"]
            ? ([self effectiveOnlineTargetFPS] >= 120.0 ? 288.0 : 360.0)
            : 360.0;
        self.gpuBudgetSlider.doubleValue = [self effectiveOnlineTargetFPS] >= 120.0 ? 10.0 : 12.0;
        self.refineStrengthSlider.doubleValue = 0.20;
        [self setControl:self.lineArtSwitch boolValue:YES];
        [self setControl:self.subtitleSwitch boolValue:YES];
        [self setControl:self.edgeAwareSwitch boolValue:NO];
    } else if (tier == 2) {
        self.flowHeightSlider.doubleValue = [[self currentRIFEBackendIdentifier] isEqualToString:@"stellaria_sp4_a1p"]
            ? ([self effectiveOnlineTargetFPS] >= 120.0 ? 432.0 : 540.0)
            : 540.0;
        self.gpuBudgetSlider.doubleValue = [self effectiveOnlineTargetFPS] >= 120.0 ? 16.67 : 20.0;
        self.refineStrengthSlider.doubleValue = 0.75;
        [self setControl:self.lineArtSwitch boolValue:YES];
        [self setControl:self.subtitleSwitch boolValue:YES];
        [self setControl:self.edgeAwareSwitch boolValue:YES];
    } else {
        self.flowHeightSlider.doubleValue = [[self currentRIFEBackendIdentifier] isEqualToString:@"stellaria_sp4_a1p"]
            ? ([self effectiveOnlineTargetFPS] >= 120.0 ? 360.0 : 432.0)
            : 432.0;
        self.gpuBudgetSlider.doubleValue = [self effectiveOnlineTargetFPS] >= 120.0 ? 12.0 : 16.67;
        self.refineStrengthSlider.doubleValue = 0.55;
        [self setControl:self.lineArtSwitch boolValue:YES];
        [self setControl:self.subtitleSwitch boolValue:YES];
        [self setControl:self.edgeAwareSwitch boolValue:YES];
    }
    NSArray<SMValueSlider*>* sliders = @[self.flowHeightSlider, self.gpuBudgetSlider, self.refineStrengthSlider];
    for (SMValueSlider* slider in sliders) {
        [slider refreshLabel];
    }
    [self refreshRealtimeTierControls];
    self.suppressSettingsSave = NO;
}

- (BOOL)manualRealtimeFlowControlsAllowed {
    if ([self browserRealtimeRestrictionsActive]) {
        return NO;
    }
    return [[self currentRIFEBackendIdentifier] isEqualToString:@"stellaria_sp4_a1p"] &&
        [self.presetPopup.titleOfSelectedItem localizedCaseInsensitiveContainsString:@"Ultimate"];
}

- (void)refreshRealtimeTierControls {
    if (self.flowHeightSlider == nil || self.gpuBudgetSlider == nil) {
        return;
    }
    const BOOL manual = [self manualRealtimeFlowControlsAllowed];
    self.flowHeightSlider.hidden = !manual;
    self.gpuBudgetSlider.hidden = !manual;
    self.flowHeightSlider.valueLabel.hidden = !manual;
    self.gpuBudgetSlider.valueLabel.hidden = !manual;
    self.flowHeightSlider.enabled = manual;
    self.gpuBudgetSlider.enabled = manual;
    if (manual) {
        self.realtimeTierHintLabel.stringValue = @"Ultimate 手动 flow/预算已开放；过高设置可能无法满足在线插帧实时需求。";
        self.realtimeTierHintLabel.textColor = SMColor(1.0, 0.78, 0.42, 1.0);
    } else if ([self browserRealtimeRestrictionsActive]) {
        self.realtimeTierHintLabel.stringValue = [NSString stringWithFormat:@"浏览器在线插帧固定 60fps；已隐藏质量档和 Ultimate，当前 flow %up / 预算 %.1fms。",
                                                  [self effectiveRealtimeFlowHeight],
                                                  [self effectiveRealtimeGpuBudgetMs]];
        self.realtimeTierHintLabel.textColor = SMColor(0.72, 0.84, 1.0, 1.0);
    } else {
        self.realtimeTierHintLabel.stringValue = [NSString stringWithFormat:@"当前实时参数由档位自动决定：flow %up / 预算 %.1fms。",
                                                  [self effectiveRealtimeFlowHeight],
                                                  [self effectiveRealtimeGpuBudgetMs]];
        self.realtimeTierHintLabel.textColor = SMColor(0.72, 0.84, 1.0, 1.0);
    }
}

- (void)registerDefaultSettings {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary<NSString*, id>* persisted = [defaults persistentDomainForName:NSBundle.mainBundle.bundleIdentifier ?: NSGlobalDomain];
    const BOOL needsModelDefaultMigration = persisted[@"motion.modelDefaultVersion"] == nil ||
        [persisted[@"motion.modelDefaultVersion"] integerValue] < 2;
    [defaults registerDefaults:@{
        @"motion.interpolationMode": @0,
        @"motion.targetFps": @60.0,
        @"motion.realtimeFps": @60.0,
        @"motion.frameMultiplier": @2.0,
        @"motion.offlineTargetFps": @60.0,
        @"motion.flowHeight": @540.0,
        @"motion.gpuBudgetMs": @16.67,
        @"motion.preset": @0,
        @"motion.powerTier": @1,
        @"motion.lineArtProtect": @YES,
        @"motion.subtitleProtect": @YES,
        @"motion.edgeAwareFlow": @YES,
        @"motion.sceneCutGuard": @YES,
        @"motion.profilerInterval": @1.0,
        @"motion.offlineTileHeight": @360.0,
        @"motion.exportQueueDepth": @3.0,
        @"motion.sceneCutThreshold": @0.62,
        @"motion.duplicateThreshold": @0.92,
        @"motion.motionConfidence": @0.74,
        @"motion.refineStrength": @0.55,
        @"motion.model": @3,
        @"motion.backend": @3,
        @"motion.modelDefaultVersion": @2,
        @"motion.occlusionBias": @0.10,
        @"motion.lineMaskGain": @1.65,
        @"motion.subtitleRadius": @4.0,
        @"motion.flowSharpness": @0.38,
        @"motion.gpuProfiler": @YES,
        @"motion.thermalDowngrade": @YES,
        @"motion.savePassJson": @YES,
        @"motion.noCpuReadback": @YES,
        @"motion.diagnosticOverlay": @NO,
        @"motion.hevcMotionHints": @YES,
        @"motion.roiMotionBlocks": @NO,
        @"motion.dynamicMultiFrame": @NO,
        @"motion.browserReturnBitrateMbps": @60.0,
        @"motion.playlistPaths": @[],
        @"motion.importedPath": @"",
        @"motion.bilibiliCookiePath": @"",
    }];
    if (needsModelDefaultMigration) {
        [defaults setInteger:3 forKey:@"motion.model"];
        [defaults setInteger:3 forKey:@"motion.backend"];
        [defaults setInteger:2 forKey:@"motion.modelDefaultVersion"];
        [defaults synchronize];
    }
}

- (BOOL)stateOfControl:(NSControl*)control fallback:(BOOL)fallback {
    return control != nil ? control.integerValue == NSControlStateValueOn : fallback;
}

- (void)setControl:(NSControl*)control boolValue:(BOOL)value {
    control.integerValue = value ? NSControlStateValueOn : NSControlStateValueOff;
}

- (BOOL)browserRealtimeRestrictionsActive {
    return self.browserOnlineRequested || [self stateOfControl:self.browserEnableSwitch fallback:NO];
}

- (void)loadSettingsIntoControls {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    self.suppressSettingsSave = YES;
    self.interpolationModeControl.selectedSegment = [defaults integerForKey:@"motion.interpolationMode"];
    const double storedRealtimeFPS = [defaults doubleForKey:@"motion.realtimeFps"] > 0.0
        ? [defaults doubleForKey:@"motion.realtimeFps"]
        : [defaults doubleForKey:@"motion.targetFps"];
    if (self.realtimeFpsPopup != nil) {
        [self.realtimeFpsPopup selectItemAtIndex:storedRealtimeFPS >= 119.0 ? 1 : 0];
    }
    self.targetFpsSlider.doubleValue = [defaults doubleForKey:@"motion.targetFps"];
    self.frameMultiplierSlider.doubleValue = [defaults doubleForKey:@"motion.frameMultiplier"];
    self.flowHeightSlider.doubleValue = [defaults doubleForKey:@"motion.flowHeight"];
    self.gpuBudgetSlider.doubleValue = [defaults doubleForKey:@"motion.gpuBudgetMs"];
    NSInteger storedPreset = [defaults integerForKey:@"motion.preset"];
    NSInteger preset = storedPreset == 4 ? 1 : 0;
    [self.presetPopup selectItemAtIndex:preset];
    [self.modelPopup selectItemAtIndex:MAX(0, MIN(3, [defaults integerForKey:@"motion.model"]))];
    [self refreshRuntimeModeControlsForModel];
    NSInteger tier = MAX(0, MIN(static_cast<NSInteger>(self.powerTierPopup.numberOfItems) - 1, [defaults integerForKey:@"motion.powerTier"]));
    [self.powerTierPopup selectItemAtIndex:tier];
    [self setControl:self.lineArtSwitch boolValue:[defaults boolForKey:@"motion.lineArtProtect"]];
    [self setControl:self.subtitleSwitch boolValue:[defaults boolForKey:@"motion.subtitleProtect"]];
    [self setControl:self.edgeAwareSwitch boolValue:[defaults boolForKey:@"motion.edgeAwareFlow"]];
    self.refineStrengthSlider.doubleValue = [defaults doubleForKey:@"motion.refineStrength"];
    [self setControl:self.noReadbackSwitch boolValue:[defaults boolForKey:@"motion.noCpuReadback"]];
    [self setControl:self.diagnosticOverlaySwitch boolValue:[defaults boolForKey:@"motion.diagnosticOverlay"]];
    [self setControl:self.hevcMotionHintsSwitch boolValue:[defaults boolForKey:@"motion.hevcMotionHints"]];
    [self setControl:self.roiMotionBlocksSwitch boolValue:[defaults boolForKey:@"motion.roiMotionBlocks"]];
    [self setControl:self.dynamicMultiFrameSwitch boolValue:[defaults boolForKey:@"motion.dynamicMultiFrame"]];
    if (self.browserReturnBitrateSlider != nil) {
        self.browserReturnBitrateSlider.doubleValue = [defaults doubleForKey:@"motion.browserReturnBitrateMbps"];
    }
    if (self.offlineTargetFpsSlider != nil) {
        self.offlineTargetFpsSlider.doubleValue = [defaults doubleForKey:@"motion.offlineTargetFps"];
    }

    NSMutableArray<SMValueSlider*>* sliders = [NSMutableArray array];
    for (SMValueSlider* slider in @[self.flowHeightSlider, self.gpuBudgetSlider, self.refineStrengthSlider]) {
        if (slider != nil) {
            [sliders addObject:slider];
        }
    }
    if (self.browserReturnBitrateSlider != nil) {
        [sliders addObject:self.browserReturnBitrateSlider];
    }
    for (SMValueSlider* slider in sliders) {
        [slider refreshLabel];
    }
    [self.offlineTargetFpsSlider refreshLabel];
    self.suppressSettingsSave = NO;
    [self applyPresetToControls];
    [self saveSettingsFromControls];
}

- (void)saveSettingsFromControls {
    if (self.suppressSettingsSave) {
        return;
    }

    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    if (self.offlineTargetFpsSlider != nil) {
        [defaults setDouble:self.offlineTargetFpsSlider.doubleValue forKey:@"motion.offlineTargetFps"];
    }
    if (self.realtimeFpsPopup != nil) {
        [defaults setDouble:(self.realtimeFpsPopup.indexOfSelectedItem == 1 ? 120.0 : 60.0) forKey:@"motion.realtimeFps"];
    }
    if (self.targetFpsSlider != nil) {
        [defaults setInteger:self.interpolationModeControl.selectedSegment forKey:@"motion.interpolationMode"];
        [defaults setDouble:self.targetFpsSlider.doubleValue forKey:@"motion.targetFps"];
        [defaults setDouble:self.frameMultiplierSlider.doubleValue forKey:@"motion.frameMultiplier"];
    }
    if (self.flowHeightSlider != nil) {
        [defaults setDouble:self.flowHeightSlider.doubleValue forKey:@"motion.flowHeight"];
        [defaults setDouble:self.gpuBudgetSlider.doubleValue forKey:@"motion.gpuBudgetMs"];
        [defaults setInteger:self.presetPopup.indexOfSelectedItem forKey:@"motion.preset"];
        [defaults setInteger:self.powerTierPopup.indexOfSelectedItem forKey:@"motion.powerTier"];
        [defaults setBool:[self stateOfControl:self.lineArtSwitch fallback:YES] forKey:@"motion.lineArtProtect"];
        [defaults setBool:[self stateOfControl:self.subtitleSwitch fallback:YES] forKey:@"motion.subtitleProtect"];
        [defaults setBool:[self stateOfControl:self.edgeAwareSwitch fallback:YES] forKey:@"motion.edgeAwareFlow"];
        [defaults setDouble:self.refineStrengthSlider.doubleValue forKey:@"motion.refineStrength"];
        [defaults setInteger:self.modelPopup.indexOfSelectedItem forKey:@"motion.model"];
        [defaults setBool:[self stateOfControl:self.noReadbackSwitch fallback:YES] forKey:@"motion.noCpuReadback"];
        [defaults setBool:[self stateOfControl:self.diagnosticOverlaySwitch fallback:NO] forKey:@"motion.diagnosticOverlay"];
        [defaults setBool:[self stateOfControl:self.hevcMotionHintsSwitch fallback:YES] forKey:@"motion.hevcMotionHints"];
        [defaults setBool:[self stateOfControl:self.roiMotionBlocksSwitch fallback:NO] forKey:@"motion.roiMotionBlocks"];
        [defaults setBool:NO forKey:@"motion.dynamicMultiFrame"];
        if (self.browserReturnBitrateSlider != nil) {
            [defaults setDouble:self.browserReturnBitrateSlider.doubleValue forKey:@"motion.browserReturnBitrateMbps"];
        }
    }
    [defaults synchronize];
    [self writeRuntimeSettingsSnapshot];
}

- (double)effectiveTargetFPS {
    if (self.realtimeFpsPopup != nil) {
        return self.realtimeFpsPopup.indexOfSelectedItem == 1 ? 120.0 : 60.0;
    }
    const double value = [NSUserDefaults.standardUserDefaults doubleForKey:@"motion.realtimeFps"];
    return value >= 119.0 ? 120.0 : 60.0;
}

- (double)effectiveFrameMultiplier {
    return self.frameMultiplierSlider != nil ? self.frameMultiplierSlider.doubleValue : [NSUserDefaults.standardUserDefaults doubleForKey:@"motion.frameMultiplier"];
}

- (BOOL)dynamicMultiFrameEnabled {
    return NO;
}

- (double)stableOnlineTargetFPSForSourceFPS:(double)sourceFPS {
    const double safeSourceFPS = sourceFPS > 1.0 ? sourceFPS : 30.0;
    const double stableTarget = safeSourceFPS <= 36.0 ? 60.0 : (safeSourceFPS <= 72.0 ? 120.0 : safeSourceFPS * 2.0);
    return MIN(MAX(stableTarget, 24.0), 240.0);
}

- (double)effectiveOnlineTargetFPS {
    if ([self browserRealtimeRestrictionsActive]) {
        return 60.0;
    }
    if (![[self currentRIFEBackendIdentifier] isEqualToString:@"stellaria_sp4_a1p"]) {
        return 60.0;
    }
    return [self effectiveTargetFPS];
}

- (double)effectiveOnlineFrameMultiplier {
    const double sourceFPS = MAX(1.0, [self currentSourceFPS]);
    return MIN(MAX([self effectiveOnlineTargetFPS] / sourceFPS, 1.0), 8.0);
}

- (double)effectiveOfflineTargetFPS {
    const double value = self.offlineTargetFpsSlider != nil
        ? self.offlineTargetFpsSlider.doubleValue
        : [NSUserDefaults.standardUserDefaults doubleForKey:@"motion.offlineTargetFps"];
    return MIN(MAX(value > 0.0 ? value : 60.0, 24.0), 240.0);
}

- (ContentProfile)effectiveContentProfile {
    return ContentProfile::Anime;
}

- (QualityMode)effectiveQualityModeForHeight:(uint32_t)height offline:(BOOL)offline {
    NSInteger preset = self.presetPopup != nil ? self.presetPopup.indexOfSelectedItem : [NSUserDefaults.standardUserDefaults integerForKey:@"motion.preset"];
    if (offline || preset == 1) {
        return QualityMode::Q4_OfflineHQ;
    }
    NSInteger tier = self.powerTierPopup != nil ? self.powerTierPopup.indexOfSelectedItem : [NSUserDefaults.standardUserDefaults integerForKey:@"motion.powerTier"];
    if (tier == 0) {
        return QualityMode::Q1_540Flow;
    }
    if (tier == 2) {
        return QualityMode::Q2_720Flow;
    }
    return height >= 2160 ? QualityMode::Q2_720Flow : QualityMode::Q3_1080Flow;
}

- (MotionQualitySettings)effectiveQualitySettingsForWidth:(uint32_t)width height:(uint32_t)height offline:(BOOL)offline {
    QualityInput input;
    input.entryMode = offline ? MotionEntryMode::OfflineExport : MotionEntryMode::LocalPlayback;
    input.profile = [self effectiveContentProfile];
    input.sourceWidth = width;
    input.sourceHeight = height;
    input.targetFps = offline ? [self effectiveOfflineTargetFPS] : [self effectiveOnlineTargetFPS];
    input.requestedMultiplier = offline ? 2.0 : [self effectiveOnlineFrameMultiplier];
    input.offlineExport = static_cast<bool>(offline);
    MotionQualitySettings settings = QualityController().ResolveSettings(input);
    settings.flowInputHeight = static_cast<uint32_t>(offline
        ? (self.flowHeightSlider != nil ? self.flowHeightSlider.doubleValue : [[NSUserDefaults standardUserDefaults] doubleForKey:@"motion.flowHeight"])
        : [self effectiveRealtimeFlowHeight]);
    settings.edgeAwareFlowUpscale = [self stateOfControl:self.edgeAwareSwitch fallback:YES];
    settings.lineArtProtect = [self stateOfControl:self.lineArtSwitch fallback:YES];
    settings.subtitleProtect = [self stateOfControl:self.subtitleSwitch fallback:YES];
    settings.refineEnabled = (self.refineStrengthSlider != nil ? self.refineStrengthSlider.doubleValue : [[NSUserDefaults standardUserDefaults] doubleForKey:@"motion.refineStrength"]) > 0.01;
    settings.offlineHighestQuality = offline;
    (void)width;
    return settings;
}

- (NSString*)runtimeSettingsSummary {
    NSString* preset = self.presetPopup.titleOfSelectedItem ?: @"Adaptive";
    NSString* tier = self.powerTierPopup.titleOfSelectedItem ?: @"均衡";
    return [NSString stringWithFormat:@"%@/%@ · flow %up · %.1fms",
            preset,
            tier,
            [self effectiveRealtimeFlowHeight],
            [self effectiveRealtimeGpuBudgetMs]];
}

- (NSString*)currentRIFEBackendIdentifier {
    const NSInteger modelIndex = self.modelPopup != nil ? self.modelPopup.indexOfSelectedItem : [NSUserDefaults.standardUserDefaults integerForKey:@"motion.model"];
    if (modelIndex == 3) {
        return @"stellaria_sp4_a1p";
    }
    if (modelIndex == 2) {
        return @"metal_int4_experimental";
    }
    if (modelIndex == 1) {
        return @"mpsgraph_fp16_target";
    }
    return @"mpsgraph_fp16_target";
}

- (uint32_t)effectiveRealtimeFlowHeight {
    NSString* backend = [self currentRIFEBackendIdentifier];
    const BOOL sp4 = [backend isEqualToString:@"stellaria_sp4_a1p"];
    const BOOL ultimate = [self.presetPopup.titleOfSelectedItem localizedCaseInsensitiveContainsString:@"Ultimate"];
    if ([self browserRealtimeRestrictionsActive]) {
        NSString* tier = self.powerTierPopup.titleOfSelectedItem ?: @"均衡";
        return [tier localizedCaseInsensitiveContainsString:@"静音"] ? 288U : 360U;
    }
    if (sp4 && ultimate) {
        const double requested = self.flowHeightSlider != nil
            ? self.flowHeightSlider.doubleValue
            : [NSUserDefaults.standardUserDefaults doubleForKey:@"motion.flowHeight"];
        return static_cast<uint32_t>(MAX(128.0, MIN(1440.0, requested)));
    }

    NSString* tier = self.powerTierPopup.titleOfSelectedItem ?: @"均衡";
    const BOOL ultraHighFpsRealtime = [self effectiveOnlineTargetFPS] >= 119.0;
    if ([backend isEqualToString:@"metal_int4_experimental"]) {
        if ([tier localizedCaseInsensitiveContainsString:@"静音"]) {
            return ultraHighFpsRealtime ? 288U : 360U;
        }
        if ([tier localizedCaseInsensitiveContainsString:@"质量"] || ultimate) {
            return ultraHighFpsRealtime ? 432U : 540U;
        }
        return ultraHighFpsRealtime ? 360U : 432U;
    }
    if ([tier localizedCaseInsensitiveContainsString:@"静音"]) {
        return sp4 ? (ultraHighFpsRealtime ? 288U : 360U) : 360U;
    }
    if ([tier localizedCaseInsensitiveContainsString:@"质量"] || ultimate) {
        return sp4 ? (ultraHighFpsRealtime ? 432U : 540U) : 540U;
    }
    return sp4 ? (ultraHighFpsRealtime ? 360U : 432U) : 432U;
}

- (double)effectiveRealtimeGpuBudgetMs {
    if ([self manualRealtimeFlowControlsAllowed]) {
        const double requested = self.gpuBudgetSlider != nil
            ? self.gpuBudgetSlider.doubleValue
            : [NSUserDefaults.standardUserDefaults doubleForKey:@"motion.gpuBudgetMs"];
        return MAX(4.0, MIN(40.0, requested > 0.0 ? requested : 16.67));
    }

    NSString* tier = self.powerTierPopup.titleOfSelectedItem ?: @"均衡";
    const BOOL ultimate = [self.presetPopup.titleOfSelectedItem localizedCaseInsensitiveContainsString:@"Ultimate"];
    const BOOL ultraHighFpsRealtime = [self effectiveOnlineTargetFPS] >= 119.0;
    if ([tier localizedCaseInsensitiveContainsString:@"静音"]) {
        return ultraHighFpsRealtime ? 10.0 : 12.0;
    }
    if ([tier localizedCaseInsensitiveContainsString:@"质量"] || ultimate) {
        return ultraHighFpsRealtime ? 16.67 : 20.0;
    }
    return ultraHighFpsRealtime ? 12.0 : 16.67;
}

- (double)effectiveBrowserReturnBitrateMbps {
    const double requested = self.browserReturnBitrateSlider != nil
        ? self.browserReturnBitrateSlider.doubleValue
        : [NSUserDefaults.standardUserDefaults doubleForKey:@"motion.browserReturnBitrateMbps"];
    return MAX(12.0, MIN(120.0, requested > 0.0 ? requested : 60.0));
}

- (NSURL*)runtimeSettingsURL {
    NSURL* appSupport = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
    return [[appSupport URLByAppendingPathComponent:@"Stellaria Motion" isDirectory:YES] URLByAppendingPathComponent:@"runtime_settings.json"];
}

- (NSDictionary<NSString*, id>*)currentRuntimeSettingsPayload {
    NSString* tier = self.powerTierPopup.titleOfSelectedItem ?: @"均衡";
    const BOOL forceHEVCMotionHints = [tier localizedCaseInsensitiveContainsString:@"均衡"] ||
        [tier localizedCaseInsensitiveContainsString:@"静音"];
    const NSInteger modelIndex = self.modelPopup != nil ? self.modelPopup.indexOfSelectedItem : [NSUserDefaults.standardUserDefaults integerForKey:@"motion.model"];
    NSString* rifeBackend = [self currentRIFEBackendIdentifier];
    return @{
        @"targetFps": @([self effectiveOnlineTargetFPS]),
        @"frameMultiplier": @([self effectiveOnlineFrameMultiplier]),
        @"onlineTargetPolicy": [self effectiveOnlineTargetFPS] >= 119.0 ? @"sp4_fixed_120" : @"fixed_60",
        @"offlineTargetFps": @([self effectiveOfflineTargetFPS]),
        @"flowInputHeight": @([self effectiveRealtimeFlowHeight]),
        @"gpuBudgetMs": @([self effectiveRealtimeGpuBudgetMs]),
        @"returnBitrateMbps": @([self effectiveBrowserReturnBitrateMbps]),
        @"manualFlowBudgetAllowed": @([self manualRealtimeFlowControlsAllowed]),
        @"powerMode": [self.presetPopup.titleOfSelectedItem localizedCaseInsensitiveContainsString:@"Ultimate"] ? @"unlimited" : @"adaptive",
        @"model": self.modelPopup.titleOfSelectedItem ?: @"RIFE加速增强",
        @"modelIndex": @(modelIndex),
        @"rifeBackend": rifeBackend,
        @"preset": self.presetPopup.titleOfSelectedItem ?: @"Adaptive",
        @"powerTier": tier,
        @"lineArtProtect": @([self stateOfControl:self.lineArtSwitch fallback:YES]),
        @"subtitleProtect": @([self stateOfControl:self.subtitleSwitch fallback:YES]),
        @"edgeAwareFlow": @([self stateOfControl:self.edgeAwareSwitch fallback:YES]),
        @"refineStrength": @(self.refineStrengthSlider != nil ? self.refineStrengthSlider.doubleValue : 0.55),
        @"noCpuReadback": @([self stateOfControl:self.noReadbackSwitch fallback:YES]),
        @"diagnosticOverlay": @([self stateOfControl:self.diagnosticOverlaySwitch fallback:NO]),
        @"hevcMotionHints": @(forceHEVCMotionHints || [self stateOfControl:self.hevcMotionHintsSwitch fallback:YES]),
        @"roiMotionBlocks": @([self stateOfControl:self.roiMotionBlocksSwitch fallback:NO]),
        @"dynamicMultiFrame": @([self browserRealtimeRestrictionsActive] ? YES : [self dynamicMultiFrameEnabled]),
        @"browserDirectTrackProcessor": @NO,
        @"preferredReturnCodec": @"auto"
    };
}

- (void)writeRuntimeSettingsSnapshot {
    NSURL* url = [self runtimeSettingsURL];
    [[NSFileManager defaultManager] createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary* payload = [self currentRuntimeSettingsPayload];
    NSData* data = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToURL:url atomically:YES];
}

- (NSURL*)browserStateURL {
    NSURL* appSupport = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
    return [[appSupport URLByAppendingPathComponent:@"Stellaria Motion" isDirectory:YES] URLByAppendingPathComponent:@"browser_state.json"];
}

- (NSURL*)onlineStatusURL {
    NSURL* appSupport = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
    return [[appSupport URLByAppendingPathComponent:@"Stellaria Motion" isDirectory:YES] URLByAppendingPathComponent:@"online_status.json"];
}

- (void)writeOnlineStatus:(NSDictionary<NSString*, id>*)status {
    NSURL* url = [self onlineStatusURL];
    [[NSFileManager defaultManager] createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary<NSString*, id>* payload = [status mutableCopy];
    NSDictionary<NSString*, id>* bridge = [self browserStreamBridgeSnapshot];
    payload[@"streamBridge"] = bridge;
    payload[@"streamBridgePort"] = bridge[@"port"] ?: @38577;
    payload[@"runtimeSettings"] = [self currentRuntimeSettingsPayload];
    NSData* data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    [data writeToURL:url atomically:YES];
}

- (void)publishIdleOnlineStatusIfNeeded {
    if (self.browserOnlineRequested || self.onlineProcessor.isRunning) {
        return;
    }
    NSDictionary<NSString*, id>* bridge = [self browserStreamBridgeSnapshot];
    if ([bridge[@"running"] boolValue]) {
        [self writeOnlineStatus:@{
            @"running": @NO,
            @"state": [bridge[@"connected"] boolValue] ? @"browser_bridge_connected" : @"browser_bridge_listening",
            @"message": [bridge[@"connected"] boolValue] ? @"Browser bridge available" : @"Browser bridge idle",
            @"browserDirect": @NO,
            @"appOverlay": @NO,
            @"generatedFPS": @0,
            @"gpuMs": bridge[@"gpuMs"] ?: @0,
            @"targetFPS": @([self effectiveOnlineTargetFPS])
        }];
        return;
    }
    [self writeOnlineStatus:@{
        @"running": @NO,
        @"state": @"idle",
        @"message": @"App online · waiting start",
        @"browserDirect": @NO,
        @"generatedFPS": @0,
        @"gpuMs": @0,
        @"targetFPS": @([self effectiveOnlineTargetFPS])
    }];
}

- (NSDictionary<NSString*, id>*)browserStreamBridgeSnapshot {
    if (self.browserStreamBridge == nil) {
        return @{
            @"running": @NO,
            @"connected": @NO,
            @"port": @38577,
            @"receivedFrames": @0,
            @"receivedBytes": @0,
            @"textMessages": @0,
            @"message": @"not started"
        };
    }
    return [self.browserStreamBridge snapshot];
}

- (void)startBrowserStreamBridge {
    if (self.browserStreamBridge == nil) {
        self.browserStreamBridge = [SMBrowserStreamBridge new];
    }
    MotionAppDelegate* __weak weakSelf = self;
    BOOL ok = [self.browserStreamBridge startWithPort:38577 progress:^(NSDictionary<NSString*, id>* status) {
        MotionAppDelegate* __strong self = weakSelf;
        if (self == nil || self.browserQueueLabel == nil) {
            return;
        }
        BOOL connected = [status[@"connected"] boolValue];
        unsigned long long frames = [status[@"receivedFrames"] respondsToSelector:@selector(unsignedLongLongValue)] ? [status[@"receivedFrames"] unsignedLongLongValue] : 0;
        unsigned long long bytes = [status[@"receivedBytes"] respondsToSelector:@selector(unsignedLongLongValue)] ? [status[@"receivedBytes"] unsignedLongLongValue] : 0;
        const double realtimeFPS = [status[@"realtimeOutputFPS"] respondsToSelector:@selector(doubleValue)] ? [status[@"realtimeOutputFPS"] doubleValue] : 0.0;
        const double realtimeGap = [status[@"realtimeMaxGapMs"] respondsToSelector:@selector(doubleValue)] ? [status[@"realtimeMaxGapMs"] doubleValue] : 0.0;
        self.browserQueueLabel.stringValue = [NSString stringWithFormat:@"Bridge  %@ · frames %llu · %.1f MB · out %.1ffps · gap %.1fms",
                                              connected ? @"connected" : @"listening",
                                              frames,
                                              static_cast<double>(bytes) / (1024.0 * 1024.0),
                                              realtimeFPS,
                                              realtimeGap];
        if (self.browserOnlineRequested || connected || frames > 0) {
            [self writeOnlineStatus:@{
                @"running": @(self.browserOnlineRequested),
                @"state": self.browserOnlineRequested ? @"html_overlay_running" : (connected ? @"browser_bridge_connected" : @"browser_bridge_listening"),
                @"message": self.browserOnlineRequested ? @"HTML overlay owns video output" : (connected ? @"Browser bridge available" : @"Browser bridge idle"),
                @"browserDirect": @(self.browserOnlineRequested),
                @"appOverlay": @NO,
                @"bridgeFrames": @(frames),
                @"generatedFPS": @0,
                @"gpuMs": status[@"gpuMs"] ?: @0,
                @"targetFPS": @([self effectiveOnlineTargetFPS])
            }];
        }
    }];
    if (!ok) {
        NSLog(@"Stellaria Motion stream bridge failed: %@", [self.browserStreamBridge snapshot][@"message"]);
    }
    [self publishIdleOnlineStatusIfNeeded];
}

- (void)refreshBrowserState:(id)sender {
    (void)sender;
    if (self.browserAgentLabel == nil) {
        return;
    }
    [self publishIdleOnlineStatusIfNeeded];
    if (self.onlineProcessor.isRunning) {
        [self syncBrowserOverlayToRect:[self currentBrowserCaptureRect]];
        NSDictionary<NSString*, id>* bridge = [self browserStreamBridgeSnapshot];
        unsigned long long frames = [bridge[@"receivedFrames"] respondsToSelector:@selector(unsignedLongLongValue)] ? [bridge[@"receivedFrames"] unsignedLongLongValue] : 0;
        unsigned long long bytes = [bridge[@"receivedBytes"] respondsToSelector:@selector(unsignedLongLongValue)] ? [bridge[@"receivedBytes"] unsignedLongLongValue] : 0;
        self.browserQueueLabel.stringValue = [NSString stringWithFormat:@"Browser stream · bridge %@ · frames %llu · %.1f MB",
                                              [bridge[@"connected"] boolValue] ? @"connected" : @"listening",
                                              frames,
                                              static_cast<double>(bytes) / (1024.0 * 1024.0)];
        self.browserStatusHintLabel.stringValue = @"浏览器插帧状态：浏览器视频流进入 App，本地推理后回推网页原位置。";
        return;
    }
    if (self.browserOnlineRequested) {
        NSDictionary<NSString*, id>* bridge = [self browserStreamBridgeSnapshot];
        BOOL connected = [bridge[@"connected"] boolValue];
        unsigned long long frames = [bridge[@"receivedFrames"] respondsToSelector:@selector(unsignedLongLongValue)] ? [bridge[@"receivedFrames"] unsignedLongLongValue] : 0;
        unsigned long long processed = [bridge[@"processedFrames"] respondsToSelector:@selector(unsignedLongLongValue)] ? [bridge[@"processedFrames"] unsignedLongLongValue] : 0;
        self.browserCaptureStatusLabel.stringValue = @"视频流捕获";
        self.browserReadyLabel.stringValue = @"播放  等待网页视频送帧";
        self.browserDriftLabel.stringValue = [NSString stringWithFormat:@"输入  已收 %llu帧", frames];
        self.browserPipelineLabel.stringValue = [NSString stringWithFormat:@"输出  已处理 %llu帧", processed];
        self.browserQueueLabel.stringValue = [NSString stringWithFormat:@"队列  %@", connected ? @"Bridge 已连接" : @"Bridge 监听中"];
        self.browserStatusHintLabel.stringValue = frames == 0
            ? @"下一步：如果这里停住，请确认网页视频正在播放；暂停态不会持续送帧。"
            : @"状态：浏览器帧已进入 App，等待/输出 RIFE 回推。";
        return;
    }
    NSURL* url = [self browserStateURL];
    NSString* json = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    if (json.length == 0) {
        self.browserAgentStatusLabel.stringValue = @"待连接";
        self.browserCaptureStatusLabel.stringValue = @"自动选择";
        self.browserPolicyStatusLabel.stringValue = @"拒绝绕过";
        self.browserAgentLabel.stringValue = @"状态  等待浏览器扩展";
        self.browserSourceLabel.stringValue = @"页面  --";
        self.browserRectLabel.stringValue = @"区域  --";
        self.browserModeLabel.stringValue = @"捕获  未启动";
        self.browserReadyLabel.stringValue = @"播放  --";
        self.browserVideoSizeLabel.stringValue = @"视频  --";
        self.browserDriftLabel.stringValue = @"输入  --";
        self.browserPipelineLabel.stringValue = [NSString stringWithFormat:@"输出  %@", [self runtimeSettingsSummary]];
        self.browserQueueLabel.stringValue = @"队列  0";
        self.browserProtectionLabel.stringValue = @"保护  --";
        self.browserStatusHintLabel.stringValue = @"下一步：打开网页视频并保持可见，然后点启动浏览器回推。";
        return;
    }

    NSString* src = SMExtractJSONString(json, @"src") ?: @"";
    NSString* pageURL = SMExtractJSONString(json, @"url") ?: @"";
    NSString* agentVersion = SMExtractJSONString(json, @"agentVersion") ?: @"";
    NSString* frameSource = SMExtractJSONString(json, @"overlayFrameSource") ?: @"video_frame_callback";
    NSString* lastDrawError = SMExtractJSONString(json, @"overlayLastDrawError") ?: @"";
    double currentTime = SMExtractJSONNumber(json, @"currentTime", 0.0);
    double readyState = SMExtractJSONNumber(json, @"readyState", 0.0);
    double videoWidth = SMExtractJSONNumber(json, @"videoWidth", 0.0);
    double videoHeight = SMExtractJSONNumber(json, @"videoHeight", 0.0);
    double overlayInputFPS = SMExtractJSONNumber(json, @"overlayInputFPS", 0.0);
    double overlayOutputFPS = SMExtractJSONNumber(json, @"overlayOutputFPS", 0.0);
    double overlayUnderflows = SMExtractJSONNumber(json, @"overlayPresentationUnderflows", 0.0);
    double overlayLastGapMs = SMExtractJSONNumber(json, @"overlayLastPresentGapMs", 0.0);
    double overlayQueueDepth = SMExtractJSONNumber(json, @"overlayOutputQueueDepth", 0.0);
    double x = SMExtractJSONNumber(json, @"x", 0.0);
    double y = SMExtractJSONNumber(json, @"y", 0.0);
    double width = SMExtractJSONNumber(json, @"width", 0.0);
    double height = SMExtractJSONNumber(json, @"height", 0.0);
    const bool paused = SMExtractJSONBool(json, @"paused", false);
    const bool fullscreen = SMExtractJSONBool(json, @"fullscreen", false);
    const bool encryptedContent = SMExtractJSONBool(json, @"encrypted", false);
    const bool protectedContent = SMExtractJSONBool(json, @"protectedContent", false) ||
                                  encryptedContent ||
                                  SMExtractJSONBool(json, @"webkitKeys", false);
    const char* pageCString = [pageURL UTF8String];
    const char* srcCString = [src UTF8String];
    auto probe = Video::ProbeBrowserSource(pageCString != nullptr ? pageCString : "",
                                           srcCString != nullptr ? srcCString : "",
                                           protectedContent);
    NSString* runtimeSummary = [self runtimeSettingsSummary];
    self.browserAgentStatusLabel.stringValue = @"已连接";
    self.browserCaptureStatusLabel.stringValue = @"视频流捕获";
    self.browserPolicyStatusLabel.stringValue = probe.protectedContent ? @"不支持" : @"合规";
    self.browserAgentLabel.stringValue = agentVersion.length > 0
        ? [NSString stringWithFormat:@"状态  扩展 v%@ 已连接", agentVersion]
        : @"状态  浏览器扩展已连接";
    self.browserSourceLabel.stringValue = [NSString stringWithFormat:@"页面  %@", src.length > 0 ? src : pageURL];
    self.browserRectLabel.stringValue = [NSString stringWithFormat:@"区域  %.0f, %.0f · %.0f x %.0f", x, y, width, height];
    self.browserModeLabel.stringValue = [NSString stringWithFormat:@"捕获  %@ · %@", [frameSource isEqualToString:@"track_processor"] ? @"视频流直读" : @"视频帧回调", runtimeSummary];

    NSString* playState = paused ? @"paused" : @"playing";
    NSString* fullState = fullscreen ? @"fullscreen" : @"windowed";
    NSString* protection = protectedContent ? @"DRM / protected blocked" : (encryptedContent ? @"encrypted signaled" : @"clear");
    self.browserReadyLabel.stringValue = [NSString stringWithFormat:@"播放  %@ · ready %.0f/4 · %.2fs · %@", playState, readyState, currentTime, fullState];
    self.browserVideoSizeLabel.stringValue = [NSString stringWithFormat:@"视频  %.0fx%.0f -> %.0fx%.0f", videoWidth, videoHeight, width, height];
    NSDictionary<NSString*, id>* bridge = [self browserStreamBridgeSnapshot];
    const double modelHeight = [bridge[@"rifeModelHeight"] respondsToSelector:@selector(doubleValue)] ? [bridge[@"rifeModelHeight"] doubleValue] : [self effectiveRealtimeFlowHeight];
    const double gpuMs = [bridge[@"gpuMs"] respondsToSelector:@selector(doubleValue)] ? [bridge[@"gpuMs"] doubleValue] : 0.0;
    unsigned long long bridgeFrames = [bridge[@"receivedFrames"] respondsToSelector:@selector(unsignedLongLongValue)] ? [bridge[@"receivedFrames"] unsignedLongLongValue] : 0;
    unsigned long long processedNativeFrames = [bridge[@"processedFrames"] respondsToSelector:@selector(unsignedLongLongValue)] ? [bridge[@"processedFrames"] unsignedLongLongValue] : 0;
    const double realtimeFPS = [bridge[@"realtimeOutputFPS"] respondsToSelector:@selector(doubleValue)] ? [bridge[@"realtimeOutputFPS"] doubleValue] : 0.0;
    const double queuedSeconds = [bridge[@"outputQueuedSeconds"] respondsToSelector:@selector(doubleValue)] ? [bridge[@"outputQueuedSeconds"] doubleValue] : 0.0;
    self.browserDriftLabel.stringValue = [NSString stringWithFormat:@"输入  %.1ffps · 已收 %llu帧", overlayInputFPS, bridgeFrames];
    self.browserPipelineLabel.stringValue = [NSString stringWithFormat:@"输出  %.1ffps · 已处理 %llu帧 · RIFE %.0fp %.1fms",
                                             MAX(overlayOutputFPS, realtimeFPS),
                                             processedNativeFrames,
                                             modelHeight,
                                             gpuMs];
    self.browserQueueLabel.stringValue = [NSString stringWithFormat:@"队列  %.2fs · buf %.0f · uf %.0f · gap %.1fms · %@",
                                          queuedSeconds,
                                          overlayQueueDepth,
                                          overlayUnderflows,
                                          overlayLastGapMs,
                                          [bridge[@"connected"] boolValue] ? @"Bridge 已连接" : @"Bridge 监听中"];
    self.browserProtectionLabel.stringValue = [NSString stringWithFormat:@"保护  %@", protection];
    NSString* drawHint = lastDrawError.length > 0 ? [NSString stringWithFormat:@" · %@", lastDrawError] : @"";
    if (paused) {
        self.browserStatusHintLabel.stringValue = @"下一步：网页视频当前暂停，点击网页播放后才会持续送帧并启用插帧。";
    } else if (bridgeFrames == 0) {
        self.browserStatusHintLabel.stringValue = [NSString stringWithFormat:@"下一步：Bridge 已连接，等待浏览器首帧；%@%@",
                                                   [frameSource isEqualToString:@"track_processor"] ? @"视频流直读可用" : @"正在使用视频帧回调",
                                                   drawHint];
    } else if (processedNativeFrames == 0) {
        self.browserStatusHintLabel.stringValue = @"下一步：浏览器帧已进入 App，等待 RIFE 输出首帧。";
    } else {
        self.browserStatusHintLabel.stringValue = @"状态：浏览器视频流捕获、RIFE 插帧和网页原位置回推正在运行。";
    }
}

- (CGRect)currentBrowserCaptureRect {
    NSURL* url = [self browserStateURL];
    NSString* json = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    if (json.length == 0) {
        return CGRectZero;
    }

    const double x = SMExtractJSONNumber(json, @"x", 0.0);
    const double y = SMExtractJSONNumber(json, @"y", 0.0);
    const double width = SMExtractJSONNumber(json, @"width", 0.0);
    const double height = SMExtractJSONNumber(json, @"height", 0.0);
    if (width < 2.0 || height < 2.0) {
        return CGRectZero;
    }
    return CGRectMake(x, y, width, height);
}

- (CAMetalLayer*)showBrowserOverlayForRect:(CGRect)browserRect {
    CGRect frame = SMOverlayFrameFromBrowserRect(browserRect);
    if (CGRectIsEmpty(frame)) {
        return nil;
    }

    if (self.browserOverlayPanel == nil) {
        self.browserOverlayPanel = [[NSPanel alloc] initWithContentRect:frame
                                                               styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                                 backing:NSBackingStoreBuffered
                                                                   defer:NO];
        self.browserOverlayPanel.opaque = NO;
        self.browserOverlayPanel.backgroundColor = NSColor.clearColor;
        self.browserOverlayPanel.hasShadow = NO;
        self.browserOverlayPanel.ignoresMouseEvents = YES;
        self.browserOverlayPanel.hidesOnDeactivate = NO;
        self.browserOverlayPanel.releasedWhenClosed = NO;
        self.browserOverlayPanel.level = NSStatusWindowLevel;
        self.browserOverlayPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                                      NSWindowCollectionBehaviorFullScreenAuxiliary |
                                                      NSWindowCollectionBehaviorStationary |
                                                      NSWindowCollectionBehaviorIgnoresCycle;

        self.browserOverlayView = [NSView new];
        self.browserOverlayView.wantsLayer = YES;
        self.browserOverlayLayer = [CAMetalLayer layer];
        self.browserOverlayLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        self.browserOverlayLayer.framebufferOnly = NO;
        self.browserOverlayLayer.opaque = YES;
        self.browserOverlayLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        self.browserOverlayView.layer = self.browserOverlayLayer;
        self.browserOverlayPanel.contentView = self.browserOverlayView;
    }

    [self syncBrowserOverlayToRect:browserRect];
    [self.browserOverlayPanel orderFrontRegardless];
    return self.browserOverlayLayer;
}

- (void)syncBrowserOverlayToRect:(CGRect)browserRect {
    if (self.browserOverlayPanel == nil || CGRectIsEmpty(browserRect)) {
        return;
    }

    CGRect frame = SMOverlayFrameFromBrowserRect(browserRect);
    [self.browserOverlayPanel setFrame:frame display:YES animate:NO];
    self.browserOverlayView.frame = NSMakeRect(0.0, 0.0, frame.size.width, frame.size.height);
    self.browserOverlayLayer.frame = self.browserOverlayView.bounds;
    self.browserOverlayLayer.drawableSize = CGSizeMake(MAX(2.0, round(browserRect.size.width)),
                                                       MAX(2.0, round(browserRect.size.height)));
}

- (void)hideBrowserOverlay {
    [self.browserOverlayPanel orderOut:nil];
}

- (void)openScreenCaptureSettings:(id)sender {
    (void)sender;
    NSArray<NSString*>* candidates = @[
        @"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        @"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenRecording",
        @"x-apple.systempreferences:com.apple.preference.security"
    ];
    for (NSString* candidate in candidates) {
        NSURL* url = [NSURL URLWithString:candidate];
        if (url != nil && [NSWorkspace.sharedWorkspace openURL:url]) {
            return;
        }
    }
}

- (void)startOnlineInterpolation:(id)sender {
    (void)sender;
    [self.onlineProcessor stop];
    [self hideBrowserOverlay];
    CGRect rect = [self currentBrowserCaptureRect];
    if (CGRectIsEmpty(rect)) {
        [self setControl:self.browserEnableSwitch boolValue:NO];
        [self refreshRuntimeModeControlsForModel];
        self.browserAgentStatusLabel.stringValue = @"等待视频";
        self.browserCaptureStatusLabel.stringValue = @"未启动";
        self.browserModeLabel.stringValue = @"捕获  未发现可见视频区域";
        self.browserPipelineLabel.stringValue = [NSString stringWithFormat:@"输出  %@", [self runtimeSettingsSummary]];
        self.browserReadyLabel.stringValue = @"播放  等待可见视频";
        self.browserVideoSizeLabel.stringValue = @"视频  rect 0x0";
        self.browserQueueLabel.stringValue = @"队列  0 · 未捕获";
        return;
    }

    NSURL* url = [self browserStateURL];
    NSString* json = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    const bool protectedContent = SMExtractJSONBool(json, @"protectedContent", false) ||
                                  SMExtractJSONBool(json, @"encrypted", false) ||
                                  SMExtractJSONBool(json, @"webkitKeys", false);
    if (protectedContent) {
        [self setControl:self.browserEnableSwitch boolValue:NO];
        [self refreshRuntimeModeControlsForModel];
        self.browserAgentStatusLabel.stringValue = @"已连接";
        self.browserCaptureStatusLabel.stringValue = @"不支持";
        self.browserPolicyStatusLabel.stringValue = @"DRM blocked";
        self.browserModeLabel.stringValue = @"捕获  protected media 不支持";
        self.browserProtectionLabel.stringValue = @"保护  DRM / protected blocked";
        return;
    }

    [self startBrowserStreamBridge];

    self.browserOnlineRequested = YES;
    [self setControl:self.browserEnableSwitch boolValue:YES];
    [self refreshRuntimeModeControlsForModel];
    [self applyPresetToControls];
    NSString* summary = [self runtimeSettingsSummary];
    self.browserStartButton.enabled = NO;
    self.browserStopButton.enabled = YES;
    [self writeOnlineStatus:@{
        @"running": @YES,
        @"state": @"browser_cache_pool",
        @"message": @"浏览器输出缓存池稳定读取：本地插帧后回推供网页按节拍播放",
        @"browserDirect": @YES,
        @"appOverlay": @NO,
        @"generatedFPS": @0,
        @"gpuMs": @0,
        @"targetFPS": @([self effectiveOnlineTargetFPS])
    }];
    self.browserAgentStatusLabel.stringValue = @"已连接";
    self.browserCaptureStatusLabel.stringValue = @"缓存池回推";
    self.browserPolicyStatusLabel.stringValue = @"合规";
    self.browserModeLabel.stringValue = [NSString stringWithFormat:@"捕获  browser stream · %@", summary];
    self.browserPipelineLabel.stringValue = [NSString stringWithFormat:@"播放  浏览器缓存池读取 · %@", summary];
    self.browserQueueLabel.stringValue = @"Queue  browser output cache";
    self.browserStatusHintLabel.stringValue = @"浏览器插帧状态：不使用屏幕录制和 App 浮层；网页从输出缓存池按目标节拍稳定读取。";
}

- (void)stopOnlineInterpolation:(id)sender {
    (void)sender;
    [self.onlineProcessor stop];
    [self hideBrowserOverlay];
    self.browserOnlineRequested = NO;
    [self setControl:self.browserEnableSwitch boolValue:NO];
    [self refreshRuntimeModeControlsForModel];
    [self writeOnlineStatus:@{@"running": @NO,
                              @"state": @"stopped",
                              @"message": @"在线插帧已停止",
                              @"browserDirect": @NO,
                              @"appOverlay": @NO}];
    self.browserStartButton.enabled = YES;
    self.browserStopButton.enabled = YES;
    self.browserCaptureStatusLabel.stringValue = @"已停止";
    self.browserModeLabel.stringValue = @"捕获  在线插帧已停止";
    self.browserPipelineLabel.stringValue = [NSString stringWithFormat:@"回推  %@", [self runtimeSettingsSummary]];
    self.browserQueueLabel.stringValue = @"队列  0";
    self.browserStatusHintLabel.stringValue = @"浏览器插帧状态：已停止。";
}

- (void)handleOnlineProgress:(NSDictionary<NSString*, id>*)status {
    NSString* state = [status[@"state"] isKindOfClass:NSString.class] ? status[@"state"] : @"capturing";
    NSString* message = [status[@"message"] isKindOfClass:NSString.class] ? status[@"message"] : @"";
    if ([state isEqualToString:@"error"]) {
        self.browserStartButton.enabled = YES;
        self.browserStopButton.enabled = YES;
        self.browserOnlineRequested = NO;
        [self setControl:self.browserEnableSwitch boolValue:NO];
        [self refreshRuntimeModeControlsForModel];
        [self writeOnlineStatus:@{
            @"running": @NO,
            @"state": @"error",
            @"message": message.length > 0 ? [NSString stringWithFormat:@"浏览器流不可用：%@", message] : @"浏览器流不可用",
            @"browserDirect": @NO,
            @"appOverlay": @NO,
            @"generatedFPS": @0,
            @"gpuMs": @0,
            @"targetFPS": @([self effectiveOnlineTargetFPS])
        }];
        self.browserAgentStatusLabel.stringValue = @"已连接";
        self.browserCaptureStatusLabel.stringValue = @"视频流错误";
        [self hideBrowserOverlay];
        self.browserModeLabel.stringValue = [NSString stringWithFormat:@"捕获  App 捕获不可用 · %@", [self runtimeSettingsSummary]];
        self.browserPipelineLabel.stringValue = @"回推  当前不可用";
        self.browserQueueLabel.stringValue = @"Queue  stopped";
        self.browserStatusHintLabel.stringValue = @"浏览器插帧状态：浏览器流回推已停止，请重新播放网页视频或重启浏览器回推。";
        return;
    }

    self.browserAgentStatusLabel.stringValue = @"在线";
    self.browserOnlineRequested = YES;
    [self setControl:self.browserEnableSwitch boolValue:YES];
    [self refreshRuntimeModeControlsForModel];
    self.browserCaptureStatusLabel.stringValue = @"视频流增强";
    self.browserPolicyStatusLabel.stringValue = @"合规";
    self.browserModeLabel.stringValue = [NSString stringWithFormat:@"捕获  %@ · %@", message.length > 0 ? message : @"在线插帧", [self runtimeSettingsSummary]];
    self.browserPipelineLabel.stringValue = [NSString stringWithFormat:@"回推  %@", message.length > 0 ? message : @"增强中"];

    const double inputFPS = [status[@"inputFPS"] respondsToSelector:@selector(doubleValue)] ? [status[@"inputFPS"] doubleValue] : 0.0;
    const double generatedFPS = [status[@"generatedFPS"] respondsToSelector:@selector(doubleValue)] ? [status[@"generatedFPS"] doubleValue] : 0.0;
    const double gpuMs = [status[@"gpuMs"] respondsToSelector:@selector(doubleValue)] ? [status[@"gpuMs"] doubleValue] : 0.0;
    const unsigned long long inputFrames = [status[@"inputFrames"] respondsToSelector:@selector(unsignedLongLongValue)] ? [status[@"inputFrames"] unsignedLongLongValue] : 0;
    const unsigned long long generatedFrames = [status[@"generatedFrames"] respondsToSelector:@selector(unsignedLongLongValue)] ? [status[@"generatedFrames"] unsignedLongLongValue] : 0;
    const unsigned long long droppedFrames = [status[@"droppedFrames"] respondsToSelector:@selector(unsignedLongLongValue)] ? [status[@"droppedFrames"] unsignedLongLongValue] : 0;
    const unsigned long long repeatedFrames = [status[@"repeatedFrames"] respondsToSelector:@selector(unsignedLongLongValue)] ? [status[@"repeatedFrames"] unsignedLongLongValue] : 0;
    const double width = [status[@"width"] respondsToSelector:@selector(doubleValue)] ? [status[@"width"] doubleValue] : 0.0;
    const double height = [status[@"height"] respondsToSelector:@selector(doubleValue)] ? [status[@"height"] doubleValue] : 0.0;
    if (self.browserOnlineRequested) {
        NSDictionary<NSString*, id>* bridge = [self browserStreamBridgeSnapshot];
        unsigned long long bridgeFrames = [bridge[@"receivedFrames"] respondsToSelector:@selector(unsignedLongLongValue)] ? [bridge[@"receivedFrames"] unsignedLongLongValue] : 0;
        const double realtimeFPS = [bridge[@"realtimeOutputFPS"] respondsToSelector:@selector(doubleValue)] ? [bridge[@"realtimeOutputFPS"] doubleValue] : 0.0;
        const double realtimeGap = [bridge[@"realtimeMaxGapMs"] respondsToSelector:@selector(doubleValue)] ? [bridge[@"realtimeMaxGapMs"] doubleValue] : 0.0;
        const double realtimeQueue = [bridge[@"realtimeQueueSeconds"] respondsToSelector:@selector(doubleValue)] ? [bridge[@"realtimeQueueSeconds"] doubleValue] : 0.0;
        [self writeOnlineStatus:@{
            @"running": @YES,
            @"state": @"html_overlay_running",
            @"message": @"网页内回推插帧中",
            @"browserDirect": @YES,
            @"appOverlay": @NO,
            @"bridgeFrames": @(bridgeFrames),
            @"inputFPS": @(inputFPS),
            @"generatedFPS": @(generatedFPS),
            @"gpuMs": @(gpuMs),
            @"inputFrames": @(inputFrames),
            @"generatedFrames": @(generatedFrames),
            @"droppedFrames": @(droppedFrames),
            @"repeatedFrames": @(repeatedFrames),
            @"width": @(width),
            @"height": @(height),
            @"targetFPS": @([self effectiveOnlineTargetFPS]),
            @"realtimeOutputFPS": @(realtimeFPS),
            @"realtimeMaxGapMs": @(realtimeGap),
            @"realtimeQueueSeconds": @(realtimeQueue)
        }];
        self.browserCaptureStatusLabel.stringValue = @"视频流捕获";
        self.browserPipelineLabel.stringValue = [NSString stringWithFormat:@"回推  浏览器视频增强 · %@", [self runtimeSettingsSummary]];
        self.browserQueueLabel.stringValue = [NSString stringWithFormat:@"Bridge  %@ · frames %llu · out %.1ffps · gap %.1fms · q %.2fs",
                                              [bridge[@"connected"] boolValue] ? @"connected" : @"listening",
                                              bridgeFrames,
                                              realtimeFPS,
                                              realtimeGap,
                                              realtimeQueue];
        self.browserStatusHintLabel.stringValue = @"浏览器插帧状态：浏览器流捕获回推运行中；屏幕捕获仅作为手动兜底。";
        return;
    }
    [self writeOnlineStatus:@{
        @"running": @YES,
        @"state": state,
        @"message": message.length > 0 ? message : @"在线插帧",
        @"browserDirect": @NO,
        @"appOverlay": @YES,
        @"inputFPS": @(inputFPS),
        @"generatedFPS": @(generatedFPS),
        @"gpuMs": @(gpuMs),
        @"inputFrames": @(inputFrames),
        @"generatedFrames": @(generatedFrames),
        @"droppedFrames": @(droppedFrames),
        @"repeatedFrames": @(repeatedFrames),
        @"width": @(width),
        @"height": @(height),
        @"targetFPS": @([self effectiveOnlineTargetFPS])
    }];

    self.browserReadyLabel.stringValue = [NSString stringWithFormat:@"播放  在线 · in %.1ffps · gen %.1ffps", inputFPS, generatedFPS];
    self.browserVideoSizeLabel.stringValue = [NSString stringWithFormat:@"视频  %.0fx%.0f · 输入 %llu / 输出 %llu", width, height, inputFrames, generatedFrames];
    self.browserDriftLabel.stringValue = [NSString stringWithFormat:@"输入  RIFE %.2fms", gpuMs];
    self.browserQueueLabel.stringValue = [NSString stringWithFormat:@"队列  drop %llu · repeat %llu", droppedFrames, repeatedFrames];
    self.browserProtectionLabel.stringValue = @"保护  clear · no DRM bypass";
    NSDictionary<NSString*, id>* bridge = [self browserStreamBridgeSnapshot];
    unsigned long long bridgeFrames = [bridge[@"receivedFrames"] respondsToSelector:@selector(unsignedLongLongValue)] ? [bridge[@"receivedFrames"] unsignedLongLongValue] : 0;
    self.browserStatusHintLabel.stringValue = [NSString stringWithFormat:@"浏览器插帧状态：回推在线 · Bridge %@ · 收到 %llu 帧",
                                               [bridge[@"connected"] boolValue] ? @"已连接" : @"监听中",
                                               bridgeFrames];
    [self syncBrowserOverlayToRect:[self currentBrowserCaptureRect]];
}

- (void)loadPlaylistFromDefaults {
    NSArray<NSString*>* saved = [NSUserDefaults.standardUserDefaults arrayForKey:@"motion.playlistPaths"];
    self.playlistPaths = [NSMutableArray array];
    for (NSString* path in saved) {
        if (![path isKindOfClass:NSString.class] || path.length == 0) {
            continue;
        }
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [self.playlistPaths addObject:path];
        }
    }
    NSString* current = [NSUserDefaults.standardUserDefaults stringForKey:@"motion.importedPath"];
    if (current.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:current]) {
        self.importedPath = current;
        if (![self.playlistPaths containsObject:current]) {
            [self.playlistPaths insertObject:current atIndex:0];
        }
    } else if (self.playlistPaths.count > 0) {
        self.importedPath = self.playlistPaths.firstObject;
    }
    self.bilibiliCookiePath = [NSUserDefaults.standardUserDefaults stringForKey:@"motion.bilibiliCookiePath"];
    if (self.bilibiliCookiePath.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:self.bilibiliCookiePath]) {
        NSString* defaultCookiePath = [[self bilibiliCacheDirectoryURL] URLByAppendingPathComponent:@"bilibili_login_cookie.txt"].path;
        if (defaultCookiePath.length > 0 && [NSFileManager.defaultManager fileExistsAtPath:defaultCookiePath]) {
            self.bilibiliCookiePath = defaultCookiePath;
            [NSUserDefaults.standardUserDefaults setObject:defaultCookiePath forKey:@"motion.bilibiliCookiePath"];
            [NSUserDefaults.standardUserDefaults synchronize];
        } else {
            self.bilibiliCookiePath = @"";
        }
    }
    self.bilibiliItems = [NSMutableArray array];
}

- (void)savePlaylistToDefaults {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:self.playlistPaths ?: @[] forKey:@"motion.playlistPaths"];
    if (self.importedPath.length > 0) {
        [defaults setObject:self.importedPath forKey:@"motion.importedPath"];
    }
    [defaults synchronize];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView {
    if (tableView == self.playlistTableView) {
        return static_cast<NSInteger>(self.playlistPaths.count + (self.bilibiliCacheActive ? 1 : 0));
    }
    if (tableView == self.bilibiliTableView) {
        return static_cast<NSInteger>(self.bilibiliItems.count);
    }
    return 0;
}

- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)tableColumn row:(NSInteger)row {
    (void)tableColumn;
    if (tableView == self.bilibiliTableView) {
        if (row < 0 || row >= static_cast<NSInteger>(self.bilibiliItems.count)) {
            return nil;
        }
        NSTextField* label = [tableView makeViewWithIdentifier:@"bilibiliCell" owner:self];
        if (label == nil) {
            label = SMLabel(@"", 12, NSFontWeightMedium, SMInk());
            label.identifier = @"bilibiliCell";
            label.lineBreakMode = NSLineBreakByTruncatingTail;
            label.maximumNumberOfLines = 2;
        }
        NSDictionary<NSString*, id>* item = self.bilibiliItems[static_cast<NSUInteger>(row)];
        NSString* title = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"";
        NSString* author = [item[@"author"] isKindOfClass:NSString.class] ? item[@"author"] : @"";
        NSString* duration = [item[@"duration"] isKindOfClass:NSString.class] ? item[@"duration"] : @"";
        NSString* bvid = [item[@"bvid"] isKindOfClass:NSString.class] ? item[@"bvid"] : @"";
        label.stringValue = [NSString stringWithFormat:@"%@\n%@ · %@ · %@", title.length > 0 ? title : bvid, author.length > 0 ? author : @"UP", duration.length > 0 ? duration : @"--", bvid];
        label.toolTip = [item[@"url"] isKindOfClass:NSString.class] ? item[@"url"] : title;
        return label;
    }
    if (tableView != self.playlistTableView || row < 0 || row >= static_cast<NSInteger>(self.playlistPaths.count + (self.bilibiliCacheActive ? 1 : 0))) {
        return nil;
    }
    const BOOL cacheRow = self.bilibiliCacheActive && row == 0;
    const NSInteger itemIndex = row - (self.bilibiliCacheActive ? 1 : 0);
    NSView* cell = [SMFlippedView new];
    cell.identifier = @"playlistCard";
    cell.wantsLayer = YES;
    SMApplyChromeLayer(cell, 12, cacheRow ? SMColor(0.56, 0.78, 1.0, 0.30) : SMColor(1.0, 1.0, 1.0, 0.10), cacheRow ? 0.10 : 0.07);

    NSTextField* icon = SMLabel(cacheRow ? @"↓" : @"▶", 18, NSFontWeightBold, SMColor(0.78, 0.88, 1.0, 1.0));
    icon.translatesAutoresizingMaskIntoConstraints = YES;
    icon.alignment = NSTextAlignmentCenter;
    icon.frame = NSMakeRect(10, 16, 28, 28);
    [cell addSubview:icon];

    NSString* titleText = cacheRow ? (self.bilibiliCacheActiveTitle.length > 0 ? self.bilibiliCacheActiveTitle : @"B 站视频缓存中") : self.playlistPaths[static_cast<NSUInteger>(itemIndex)].lastPathComponent;
    NSTextField* title = SMLabel(titleText ?: @"视频", 12, NSFontWeightSemibold, SMInk());
    title.translatesAutoresizingMaskIntoConstraints = YES;
    title.lineBreakMode = NSLineBreakByTruncatingMiddle;
    title.maximumNumberOfLines = 1;
    const CGFloat visibleWidth = tableView.enclosingScrollView != nil ? tableView.enclosingScrollView.contentView.bounds.size.width : tableView.bounds.size.width;
    const CGFloat cellWidth = MAX(180.0, visibleWidth);
    title.frame = NSMakeRect(46, 12, cellWidth - 116.0, 20);
    [cell addSubview:title];

    NSTextField* detail = SMLabel(cacheRow ? @"缓存进行中，完成后自动加入播放列表" : @"双击播放 · 可置顶或删除", 10, NSFontWeightMedium, SMMuted());
    detail.translatesAutoresizingMaskIntoConstraints = YES;
    detail.lineBreakMode = NSLineBreakByTruncatingTail;
    detail.maximumNumberOfLines = 1;
    detail.frame = NSMakeRect(46, 34, cellWidth - 116.0, 16);
    [cell addSubview:detail];

    if (cacheRow) {
        NSProgressIndicator* progress = [NSProgressIndicator new];
        progress.translatesAutoresizingMaskIntoConstraints = YES;
        progress.indeterminate = YES;
        progress.style = NSProgressIndicatorStyleBar;
        progress.frame = NSMakeRect(46, 56, cellWidth - 72.0, 10);
        [progress startAnimation:nil];
        [cell addSubview:progress];
    } else {
        NSButton* pin = SMButton(@"↑");
        pin.translatesAutoresizingMaskIntoConstraints = YES;
        pin.font = SMFont(10, NSFontWeightSemibold, YES);
        pin.toolTip = @"置顶";
        pin.frame = NSMakeRect(cellWidth - 66.0, 10, 28, 24);
        pin.tag = itemIndex;
        pin.target = self;
        pin.action = @selector(pinPlaylistItem:);
        [cell addSubview:pin];

        NSButton* del = SMButton(@"×");
        del.translatesAutoresizingMaskIntoConstraints = YES;
        del.font = SMFont(10, NSFontWeightSemibold, YES);
        del.toolTip = @"删除";
        del.frame = NSMakeRect(cellWidth - 34.0, 10, 28, 24);
        del.tag = itemIndex;
        del.target = self;
        del.action = @selector(deletePlaylistItemButton:);
        [cell addSubview:del];
    }
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification*)notification {
    if (notification.object == self.bilibiliTableView) {
        NSInteger row = self.bilibiliTableView.selectedRow;
        if (row >= 0 && row < static_cast<NSInteger>(self.bilibiliItems.count)) {
            NSDictionary<NSString*, id>* item = self.bilibiliItems[static_cast<NSUInteger>(row)];
            NSString* url = [item[@"url"] isKindOfClass:NSString.class] ? item[@"url"] : @"";
            self.bilibiliURLField.stringValue = url;
            NSString* title = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"";
            self.bilibiliStatusLabel.stringValue = title.length > 0 ? [NSString stringWithFormat:@"已选中：%@", title] : @"已选中 B 站视频";
        }
        return;
    }
    if (notification.object != self.playlistTableView) {
        return;
    }
    NSInteger row = self.playlistTableView.selectedRow;
    const NSInteger itemIndex = row - (self.bilibiliCacheActive ? 1 : 0);
    if (itemIndex >= 0 && itemIndex < static_cast<NSInteger>(self.playlistPaths.count)) {
        self.importedPath = self.playlistPaths[static_cast<NSUInteger>(itemIndex)];
        self.importedFileLabel.stringValue = self.importedPath.lastPathComponent ?: @"已选择视频";
        self.previewStatusLabel.stringValue = @"已选择，按播放开始增强";
        [self savePlaylistToDefaults];
    }
}

- (void)addURLToPlaylist:(NSURL*)url select:(BOOL)select {
    NSString* path = url.path;
    if (path.length == 0) {
        return;
    }
    if (self.playlistPaths == nil) {
        self.playlistPaths = [NSMutableArray array];
    }
    [self.playlistPaths removeObject:path];
    [self.playlistPaths insertObject:path atIndex:0];
    if (select) {
        self.importedPath = path;
    }
}

- (NSURL*)bilibiliCacheScriptURL {
    NSURL* bundled = [NSBundle.mainBundle URLForResource:@"bilibili_cache_client"
                                           withExtension:@"py"
                                            subdirectory:@"tools"];
    if (bundled != nil) {
        return bundled;
    }
    NSString* cwd = NSFileManager.defaultManager.currentDirectoryPath ?: @"";
    NSURL* sourceTree = [NSURL fileURLWithPath:[cwd stringByAppendingPathComponent:@"tools/bilibili_cache_client.py"]];
    if ([NSFileManager.defaultManager fileExistsAtPath:sourceTree.path]) {
        return sourceTree;
    }
    return nil;
}

- (NSURL*)bilibiliCacheDirectoryURL {
    NSURL* appSupport = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL* directory = [[appSupport URLByAppendingPathComponent:@"Stellaria Motion" isDirectory:YES] URLByAppendingPathComponent:@"BilibiliCache" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return directory;
}

- (void)clearBilibiliCache:(id)sender {
    (void)sender;
    if (self.bilibiliImportTask != nil && self.bilibiliImportTask.isRunning) {
        self.bilibiliStatusLabel.stringValue = @"正在执行 B 站任务，完成后再清理缓存。";
        return;
    }
    NSURL* directory = [self bilibiliCacheDirectoryURL];
    NSFileManager* fm = NSFileManager.defaultManager;
    NSArray<NSURLResourceKey>* keys = @[NSURLIsDirectoryKey, NSURLFileSizeKey];
    NSDirectoryEnumerator<NSURL*>* enumerator = [fm enumeratorAtURL:directory
                                         includingPropertiesForKeys:keys
                                                            options:NSDirectoryEnumerationSkipsHiddenFiles
                                                       errorHandler:nil];
    NSUInteger removed = 0;
    unsigned long long bytes = 0;
    for (NSURL* url in enumerator) {
        NSNumber* isDirectory = nil;
        [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        if (isDirectory.boolValue) {
            continue;
        }
        NSString* name = url.lastPathComponent ?: @"";
        if ([name isEqualToString:@"bilibili_login_cookie.txt"]) {
            continue;
        }
        NSNumber* size = nil;
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        NSError* removeError = nil;
        if ([fm removeItemAtURL:url error:&removeError]) {
            removed += 1;
            bytes += size.unsignedLongLongValue;
        }
    }
    double mb = static_cast<double>(bytes) / (1024.0 * 1024.0);
    self.bilibiliStatusLabel.stringValue = [NSString stringWithFormat:@"已清理 B 站缓存：%lu 个文件，约 %.1f MB。登录态已保留。", static_cast<unsigned long>(removed), mb];
}

- (NSInteger)selectedBilibiliMaxHeight {
    NSString* title = self.bilibiliQualityPopup.titleOfSelectedItem ?: @"最高可用";
    return [self bilibiliMaxHeightForQualityTitle:title];
}

- (NSInteger)bilibiliMaxHeightForQualityTitle:(NSString*)title {
    if ([title containsString:@"1080"]) {
        return 1080;
    }
    if ([title containsString:@"720"]) {
        return 720;
    }
    if ([title containsString:@"480"]) {
        return 480;
    }
    if ([title containsString:@"360"]) {
        return 360;
    }
    return 2160;
}

- (NSString*)selectedBilibiliURL {
    NSString* direct = [self.bilibiliURLField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (direct.length > 0) {
        return direct;
    }
    if (self.bilibiliSelectedIndex >= 0 && self.bilibiliSelectedIndex < static_cast<NSInteger>(self.bilibiliItems.count)) {
        NSDictionary<NSString*, id>* item = self.bilibiliItems[static_cast<NSUInteger>(self.bilibiliSelectedIndex)];
        NSString* url = [item[@"url"] isKindOfClass:NSString.class] ? item[@"url"] : @"";
        if (url.length > 0) {
            return url;
        }
    }
    if (self.bilibiliTableView == nil) {
        return @"";
    }
    NSInteger row = self.bilibiliTableView.selectedRow;
    if (row >= 0 && row < static_cast<NSInteger>(self.bilibiliItems.count)) {
        NSDictionary<NSString*, id>* item = self.bilibiliItems[static_cast<NSUInteger>(row)];
        NSString* url = [item[@"url"] isKindOfClass:NSString.class] ? item[@"url"] : @"";
        if (url.length > 0) {
            return url;
        }
    }
    return @"";
}

- (void)setBilibiliImportRunning:(BOOL)running {
    self.bilibiliImportButton.enabled = !running;
    self.bilibiliURLField.enabled = !running;
    self.bilibiliSearchField.enabled = !running;
    self.bilibiliQualityPopup.enabled = !running;
    self.bilibiliSectionControl.enabled = !running;
    self.bilibiliOrderPopup.enabled = !running;
    if (self.bilibiliTableView != nil) {
        self.bilibiliTableView.enabled = !running;
    }
    if (self.previewStatusLabel != nil && running) {
        self.previewStatusLabel.stringValue = @"B 站视频缓存中，完成后自动本地增强播放";
    }
}

- (void)runBilibiliListMode:(NSString*)mode keyword:(NSString*)keyword {
    if (self.bilibiliImportTask != nil && self.bilibiliImportTask.isRunning) {
        return;
    }
    NSURL* script = [self bilibiliCacheScriptURL];
    if (script == nil) {
        self.bilibiliStatusLabel.stringValue = @"未找到 B 站缓存脚本";
        return;
    }
    NSMutableArray<NSString*>* args = [@[
        @"python3",
        script.path,
        @"--mode", mode,
        @"--output-dir", [self bilibiliCacheDirectoryURL].path,
        @"--limit", @"30",
        @"--json",
    ] mutableCopy];
    if (keyword.length > 0) {
        [args addObjectsFromArray:@[@"--keyword", keyword]];
    }
    if ([mode isEqualToString:@"home"] || [mode isEqualToString:@"search"]) {
        [args addObjectsFromArray:@[@"--category", [self bilibiliCategoryArgument], @"--order", [self bilibiliOrderArgument]]];
    }
    if (self.bilibiliCookiePath.length > 0) {
        [args addObjectsFromArray:@[@"--cookie-file", self.bilibiliCookiePath]];
    }
    NSPipe* pipe = [NSPipe pipe];
    NSTask* task = [NSTask new];
    task.launchPath = @"/usr/bin/env";
    task.arguments = args;
    task.standardOutput = pipe;
    task.standardError = pipe;
    self.bilibiliImportTask = task;
    [self setBilibiliImportRunning:YES];
    if ([mode isEqualToString:@"home"]) {
        NSInteger segment = self.bilibiliSectionControl.selectedSegment;
        NSString* sectionName = segment == 3 ? @"番剧" : (segment == 4 ? @"影视" : @"视频");
        self.bilibiliStatusLabel.stringValue = [NSString stringWithFormat:@"正在加载 B 站%@推荐...", sectionName];
    } else if ([mode isEqualToString:@"favorites"]) {
        self.bilibiliStatusLabel.stringValue = @"正在加载我的 B 站收藏...";
    } else {
        self.bilibiliStatusLabel.stringValue = @"正在搜索 B 站...";
    }
    MotionAppDelegate* __weak weakSelf = self;
    task.terminationHandler = ^(NSTask* finishedTask) {
        (void)finishedTask;
        NSData* data = [pipe.fileHandleForReading readDataToEndOfFile];
        dispatch_async(dispatch_get_main_queue(), ^{
            MotionAppDelegate* __strong self = weakSelf;
            if (self == nil) {
                return;
            }
            self.bilibiliImportTask = nil;
            [self setBilibiliImportRunning:NO];
            NSDictionary* result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![result isKindOfClass:NSDictionary.class] || ![result[@"ok"] boolValue]) {
                NSString* text = [result[@"error"] isKindOfClass:NSString.class] ? result[@"error"] : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                self.bilibiliStatusLabel.stringValue = [NSString stringWithFormat:@"B 站列表失败：%@", text.length > 0 ? text : @"未知错误"];
                return;
            }
            NSArray* items = [result[@"items"] isKindOfClass:NSArray.class] ? result[@"items"] : @[];
            self.bilibiliItems = [items mutableCopy];
            self.bilibiliSelectedIndex = -1;
            if (self.bilibiliTableView != nil) {
                [self.bilibiliTableView reloadData];
            }
            [self rebuildBilibiliGrid];
            self.bilibiliStatusLabel.stringValue = [NSString stringWithFormat:@"已加载 %lu 个条目。可在每张卡片选择清晰度并缓存。", static_cast<unsigned long>(self.bilibiliItems.count)];
        });
    };
    NSError* launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        self.bilibiliImportTask = nil;
        [self setBilibiliImportRunning:NO];
        self.bilibiliStatusLabel.stringValue = [NSString stringWithFormat:@"B 站列表启动失败：%@", launchError.localizedDescription ?: @"python3 unavailable"];
    }
}

- (void)loadBilibiliHome:(id)sender {
    (void)sender;
    [self runBilibiliListMode:@"home" keyword:@""];
}

- (void)searchBilibili:(id)sender {
    (void)sender;
    NSString* keyword = [self.bilibiliSearchField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (keyword.length == 0) {
        self.bilibiliStatusLabel.stringValue = @"请输入搜索关键词";
        return;
    }
    [self runBilibiliListMode:@"search" keyword:keyword];
}

- (void)chooseBilibiliCookie:(id)sender {
    (void)sender;
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"txt"], [UTType typeWithFilenameExtension:@"cookies"]];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || panel.URL.path.length == 0) {
            return;
        }
        self.bilibiliCookiePath = panel.URL.path;
        [NSUserDefaults.standardUserDefaults setObject:self.bilibiliCookiePath forKey:@"motion.bilibiliCookiePath"];
        [NSUserDefaults.standardUserDefaults synchronize];
        self.bilibiliCookieLabel.stringValue = [NSString stringWithFormat:@"登录态：%@", self.bilibiliCookiePath.lastPathComponent ?: self.bilibiliCookiePath];
    }];
}

- (void)loginBilibili:(id)sender {
    (void)sender;
    if (self.bilibiliImportTask != nil && self.bilibiliImportTask.isRunning) {
        return;
    }
    NSURL* script = [self bilibiliCacheScriptURL];
    if (script == nil) {
        self.bilibiliStatusLabel.stringValue = @"未找到 B 站缓存脚本";
        return;
    }
    NSPipe* pipe = [NSPipe pipe];
    NSTask* task = [NSTask new];
    task.launchPath = @"/usr/bin/env";
    task.arguments = @[
        @"python3",
        script.path,
        @"--mode", @"login",
        @"--output-dir", [self bilibiliCacheDirectoryURL].path,
        @"--json",
    ];
    task.standardOutput = pipe;
    task.standardError = pipe;
    self.bilibiliImportTask = task;
    [self setBilibiliImportRunning:YES];
    self.bilibiliStatusLabel.stringValue = @"已打开 B 站扫码登录页，请用手机客户端确认登录。";
    MotionAppDelegate* __weak weakSelf = self;
    task.terminationHandler = ^(NSTask* finishedTask) {
        (void)finishedTask;
        NSData* data = [pipe.fileHandleForReading readDataToEndOfFile];
        dispatch_async(dispatch_get_main_queue(), ^{
            MotionAppDelegate* __strong self = weakSelf;
            if (self == nil) {
                return;
            }
            self.bilibiliImportTask = nil;
            [self setBilibiliImportRunning:NO];
            NSDictionary* result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![result isKindOfClass:NSDictionary.class] || ![result[@"ok"] boolValue]) {
                NSString* text = [result[@"error"] isKindOfClass:NSString.class] ? result[@"error"] : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                self.bilibiliStatusLabel.stringValue = [NSString stringWithFormat:@"扫码登录失败：%@", text.length > 0 ? text : @"未知错误"];
                return;
            }
            NSString* path = [result[@"cookieFile"] isKindOfClass:NSString.class] ? result[@"cookieFile"] : @"";
            if (path.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:path]) {
                self.bilibiliStatusLabel.stringValue = @"扫码登录完成但未生成登录态文件";
                return;
            }
            self.bilibiliCookiePath = path;
            [NSUserDefaults.standardUserDefaults setObject:path forKey:@"motion.bilibiliCookiePath"];
            [NSUserDefaults.standardUserDefaults synchronize];
            self.bilibiliCookieLabel.stringValue = [NSString stringWithFormat:@"登录态：%@", path.lastPathComponent ?: path];
            self.bilibiliStatusLabel.stringValue = @"扫码登录完成，本地 App 登录态已自动设置。";
            [self runBilibiliListMode:@"home" keyword:@""];
        });
    };
    NSError* launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        self.bilibiliImportTask = nil;
        [self setBilibiliImportRunning:NO];
        self.bilibiliStatusLabel.stringValue = [NSString stringWithFormat:@"扫码登录启动失败：%@", launchError.localizedDescription ?: @"python3 unavailable"];
    }
}

- (void)importBilibiliURL:(id)sender {
    (void)sender;
    if (self.bilibiliImportTask != nil && self.bilibiliImportTask.isRunning) {
        return;
    }
    NSString* input = [self selectedBilibiliURL];
    if (input.length == 0) {
        self.bilibiliStatusLabel.stringValue = @"请先选择视频或粘贴 B 站链接";
        return;
    }
    NSString* activeTitle = input.lastPathComponent ?: @"B 站视频";
    if (self.bilibiliSelectedIndex >= 0 && self.bilibiliSelectedIndex < static_cast<NSInteger>(self.bilibiliItems.count)) {
        NSDictionary<NSString*, id>* item = self.bilibiliItems[static_cast<NSUInteger>(self.bilibiliSelectedIndex)];
        NSString* title = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"";
        if (title.length > 0) {
            activeTitle = title;
        }
    }
    NSURL* script = [self bilibiliCacheScriptURL];
    if (script == nil) {
        self.previewStatusLabel.stringValue = @"未找到 B 站缓存脚本";
        return;
    }
    NSURL* cacheDir = [self bilibiliCacheDirectoryURL];
    NSPipe* pipe = [NSPipe pipe];
    NSTask* task = [NSTask new];
    task.launchPath = @"/usr/bin/env";
    NSMutableArray<NSString*>* args = [@[
        @"python3",
        script.path,
        @"--mode", @"cache",
        @"--url", input,
        @"--output-dir", cacheDir.path,
        @"--max-height", [NSString stringWithFormat:@"%ld", static_cast<long>([self selectedBilibiliMaxHeight])],
        @"--json",
    ] mutableCopy];
    if (self.bilibiliCookiePath.length > 0) {
        [args addObjectsFromArray:@[@"--cookie-file", self.bilibiliCookiePath]];
    }
    task.arguments = args;
    task.standardOutput = pipe;
    task.standardError = pipe;
    self.bilibiliImportTask = task;
    self.bilibiliCacheActive = YES;
    self.bilibiliCacheActiveTitle = activeTitle;
    self.bilibiliCacheActiveURL = input;
    [self setBilibiliImportRunning:YES];
    [self.playlistTableView reloadData];
    self.bilibiliStatusLabel.stringValue = @"正在缓存 B 站视频，完成后自动播放...";
    MotionAppDelegate* __weak weakSelf = self;
    task.terminationHandler = ^(NSTask* finishedTask) {
        (void)finishedTask;
        NSData* data = [pipe.fileHandleForReading readDataToEndOfFile];
        dispatch_async(dispatch_get_main_queue(), ^{
            MotionAppDelegate* __strong self = weakSelf;
            if (self == nil) {
                return;
            }
            self.bilibiliImportTask = nil;
            self.bilibiliCacheActive = NO;
            self.bilibiliCacheActiveTitle = @"";
            self.bilibiliCacheActiveURL = @"";
            [self setBilibiliImportRunning:NO];
            [self.playlistTableView reloadData];
            NSError* jsonError = nil;
            NSDictionary* result = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (![result isKindOfClass:NSDictionary.class] || ![result[@"ok"] boolValue]) {
                NSString* text = [result[@"error"] isKindOfClass:NSString.class] ? result[@"error"] : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                self.bilibiliStatusLabel.stringValue = [NSString stringWithFormat:@"B 站缓存失败：%@", text.length > 0 ? text : @"未知错误"];
                return;
            }
            NSString* path = [result[@"path"] isKindOfClass:NSString.class] ? result[@"path"] : @"";
            if (path.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:path]) {
                self.bilibiliStatusLabel.stringValue = @"B 站缓存完成但输出文件不存在";
                return;
            }
            NSDictionary* quality = [result[@"quality"] isKindOfClass:NSDictionary.class] ? result[@"quality"] : nil;
            if (quality != nil) {
                self.bilibiliStatusLabel.stringValue = [NSString stringWithFormat:@"缓存完成：%@p · %@", quality[@"height"] ?: @"--", [quality[@"loginCookie"] boolValue] ? @"已使用 cookie" : @"公开视频权限"];
            } else {
                self.bilibiliStatusLabel.stringValue = @"缓存命中，开始播放";
            }
            NSURL* url = [NSURL fileURLWithPath:path];
            [self addURLToPlaylist:url select:YES];
            [self savePlaylistToDefaults];
            [self selectSection:0];
            [self loadImportedURL:url autoplay:YES];
        });
    };
    NSError* launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        self.bilibiliImportTask = nil;
        self.bilibiliCacheActive = NO;
        self.bilibiliCacheActiveTitle = @"";
        self.bilibiliCacheActiveURL = @"";
        [self setBilibiliImportRunning:NO];
        [self.playlistTableView reloadData];
        self.bilibiliStatusLabel.stringValue = [NSString stringWithFormat:@"B 站缓存启动失败：%@", launchError.localizedDescription ?: @"python3 unavailable"];
    }
}

- (void)selectImportedPathInPlaylist {
    [self.playlistTableView reloadData];
    NSUInteger index = self.importedPath.length > 0 ? [self.playlistPaths indexOfObject:self.importedPath] : NSNotFound;
    if (index != NSNotFound && self.playlistTableView != nil) {
        NSIndexSet* set = [NSIndexSet indexSetWithIndex:index + (self.bilibiliCacheActive ? 1 : 0)];
        [self.playlistTableView selectRowIndexes:set byExtendingSelection:NO];
        [self.playlistTableView scrollRowToVisible:static_cast<NSInteger>(index + (self.bilibiliCacheActive ? 1 : 0))];
    }
}

- (CGSize)naturalVideoSizeForURL:(NSURL*)url {
    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:url options:nil];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVAssetTrack* track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
#pragma clang diagnostic pop
    CGSize size = track != nil ? CGSizeApplyAffineTransform(track.naturalSize, track.preferredTransform) : CGSizeMake(16.0, 9.0);
    size.width = fabs(size.width);
    size.height = fabs(size.height);
    if (size.width < 1.0 || size.height < 1.0) {
        size = CGSizeMake(16.0, 9.0);
    }
    return size;
}

- (void)loadImportedURL:(NSURL*)url autoplay:(BOOL)autoplay {
    if (url == nil) {
        return;
    }
    [self.onlineProcessor stop];
    self.localPreviewView.hidden = YES;
    self.importedPath = url.path;
    CGSize naturalSize = [self naturalVideoSizeForURL:url];
    [self updateLocalPreviewAspectWidth:naturalSize.width height:naturalSize.height];
    self.importedFileLabel.stringValue = url.lastPathComponent ?: @"已导入视频";
    self.previewStatusLabel.stringValue = autoplay ? @"增强播放启动中" : @"已载入，按播放开始增强";
    self.playerView.videoGravity = AVLayerVideoGravityResizeAspect;
    self.activePlayer = [AVPlayer playerWithURL:url];
    self.activePlayer.volume = static_cast<float>(self.playerVolumeSlider != nil ? self.playerVolumeSlider.doubleValue : 1.0);
    self.playerView.player = self.activePlayer;
    [self refreshInterpolationModeControls];
    [self saveSettingsFromControls];
    [self savePlaylistToDefaults];
    [self selectImportedPathInPlaylist];
    [self setDiagnosticStatus:@"已载入" output:@"等待播放" frame:@"就绪" queue:@"1.0x"];
    [self refreshPlayerControls:nil];
    if (autoplay) {
        [self playPreview:nil];
    }
}

- (void)playSelectedPlaylistItem:(id)sender {
    (void)sender;
    NSInteger row = self.playlistTableView.selectedRow;
    NSInteger itemIndex = row - (self.bilibiliCacheActive ? 1 : 0);
    if (itemIndex < 0 || itemIndex >= static_cast<NSInteger>(self.playlistPaths.count)) {
        return;
    }
    [self loadImportedURL:[NSURL fileURLWithPath:self.playlistPaths[static_cast<NSUInteger>(itemIndex)]] autoplay:YES];
}

- (void)removeSelectedPlaylistItem:(id)sender {
    (void)sender;
    NSInteger row = self.playlistTableView.selectedRow;
    NSInteger itemIndex = row - (self.bilibiliCacheActive ? 1 : 0);
    if (itemIndex < 0 || itemIndex >= static_cast<NSInteger>(self.playlistPaths.count)) {
        return;
    }
    NSString* removed = self.playlistPaths[static_cast<NSUInteger>(itemIndex)];
    [self.playlistPaths removeObjectAtIndex:static_cast<NSUInteger>(itemIndex)];
    if ([self.importedPath isEqualToString:removed]) {
        self.importedPath = self.playlistPaths.firstObject;
        if (self.importedPath.length > 0) {
            [self loadImportedURL:[NSURL fileURLWithPath:self.importedPath] autoplay:NO];
        } else {
            self.playerView.player = nil;
            self.activePlayer = nil;
            self.importedFileLabel.stringValue = @"尚未选择文件";
            self.previewStatusLabel.stringValue = @"等待导入视频";
        }
    }
    [self savePlaylistToDefaults];
    [self selectImportedPathInPlaylist];
}

- (void)pinPlaylistItem:(NSButton*)sender {
    NSInteger index = sender.tag;
    if (index <= 0 || index >= static_cast<NSInteger>(self.playlistPaths.count)) {
        return;
    }
    NSString* path = self.playlistPaths[static_cast<NSUInteger>(index)];
    [self.playlistPaths removeObjectAtIndex:static_cast<NSUInteger>(index)];
    [self.playlistPaths insertObject:path atIndex:0];
    [self savePlaylistToDefaults];
    [self.playlistTableView reloadData];
}

- (void)deletePlaylistItemButton:(NSButton*)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= static_cast<NSInteger>(self.playlistPaths.count)) {
        return;
    }
    [self.playlistTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:index + (self.bilibiliCacheActive ? 1 : 0)] byExtendingSelection:NO];
    [self removeSelectedPlaylistItem:sender];
}

- (void)togglePlayerFullscreen:(id)sender {
    (void)sender;
    if (self.playerVideoFullscreen || self.playerFullscreenWindow != nil) {
        [self exitPlayerFullscreen];
    } else {
        [self enterPlayerFullscreen];
    }
}

- (void)enterPlayerFullscreen {
    if (self.playerVideoFullscreen || self.playerFullscreenWindow != nil) {
        return;
    }
    if (self.importedPath.length > 0 && !self.onlineProcessor.isRunning) {
        [self playPreview:nil];
    }
    NSRect screenFrame = (self.window.screen ?: NSScreen.mainScreen).frame;
    NSWindow* fullscreenWindow = [[NSWindow alloc] initWithContentRect:screenFrame
                                                             styleMask:NSWindowStyleMaskTitled |
                                                                       NSWindowStyleMaskClosable |
                                                                       NSWindowStyleMaskResizable
                                                               backing:NSBackingStoreBuffered
                                                                 defer:NO];
    fullscreenWindow.title = self.importedPath.lastPathComponent ?: @"Stellaria Motion Player";
    fullscreenWindow.delegate = self;
    fullscreenWindow.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    fullscreenWindow.titlebarAppearsTransparent = YES;
    fullscreenWindow.toolbarStyle = NSWindowToolbarStyleUnifiedCompact;
    fullscreenWindow.backgroundColor = NSColor.blackColor;

    NSView* root = [NSView new];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    root.wantsLayer = YES;
    root.layer.backgroundColor = NSColor.blackColor.CGColor;
    fullscreenWindow.contentView = root;

    self.playerFullscreenWindow = fullscreenWindow;
    self.playerFullscreenHost = root;
    self.playerFullscreenButton.title = @"退出全屏";
    [self attachLocalPreviewViewToHost:root hidden:self.localPreviewView != nil ? self.localPreviewView.hidden : NO];
    self.playerFullscreenControlsView = [self buildPlayerFullscreenControlsView];
    [root addSubview:self.playerFullscreenControlsView positioned:NSWindowAbove relativeTo:nil];
    [NSLayoutConstraint activateConstraints:@[
        [self.playerFullscreenControlsView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:28.0],
        [self.playerFullscreenControlsView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-28.0],
        [self.playerFullscreenControlsView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-30.0],
        [self.playerFullscreenControlsView.heightAnchor constraintEqualToConstant:92.0],
    ]];
    [self refreshPlayerControls:nil];
    [self installPlayerFullscreenEscapeMonitor];
    [self installPlayerFullscreenMouseMoveMonitor];
    [fullscreenWindow makeKeyAndOrderFront:nil];
    [fullscreenWindow toggleFullScreen:nil];
    [self showPlayerFullscreenControlsAndScheduleHide];
}

- (void)exitPlayerFullscreen {
    if (self.playerFullscreenWindow != nil && (self.playerVideoFullscreen || (self.playerFullscreenWindow.styleMask & NSWindowStyleMaskFullScreen) != 0)) {
        [self.playerFullscreenWindow toggleFullScreen:nil];
    } else {
        [self finishPlayerFullscreenExit];
    }
}

- (void)installPlayerFullscreenEscapeMonitor {
    if (self.playerFullscreenEventMonitor != nil) {
        return;
    }
    MotionAppDelegate* __weak weakSelf = self;
    self.playerFullscreenEventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent* (NSEvent* event) {
        MotionAppDelegate* __strong self = weakSelf;
        if (self == nil) {
            return event;
        }
        if (event.keyCode == 53 && (self.playerVideoFullscreen || self.playerFullscreenWindow != nil)) {
            [self exitPlayerFullscreen];
            return nil;
        }
        if (self.playerFullscreenWindow != nil) {
            [self showPlayerFullscreenControlsAndScheduleHide];
        }
        return event;
    }];
}

- (void)installPlayerFullscreenMouseMoveMonitor {
    if (self.playerFullscreenMouseMoveMonitor != nil) {
        return;
    }
    MotionAppDelegate* __weak weakSelf = self;
    self.playerFullscreenMouseMoveMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved | NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown handler:^NSEvent* (NSEvent* event) {
        MotionAppDelegate* __strong self = weakSelf;
        if (self != nil && self.playerFullscreenWindow != nil) {
            [self showPlayerFullscreenControlsAndScheduleHide];
        }
        return event;
    }];
}

- (void)windowWillEnterFullScreen:(NSNotification*)notification {
    if (notification.object != self.playerFullscreenWindow) {
        return;
    }
    self.playerVideoFullscreen = YES;
}

- (void)windowWillExitFullScreen:(NSNotification*)notification {
    if (notification.object != self.playerFullscreenWindow) {
        return;
    }
    self.playerVideoFullscreen = NO;
}

- (void)windowDidExitFullScreen:(NSNotification*)notification {
    if (notification.object != self.playerFullscreenWindow) {
        return;
    }
    [self finishPlayerFullscreenExit];
}

- (void)windowWillClose:(NSNotification*)notification {
    if (notification.object == self.playerFullscreenWindow) {
        [self finishPlayerFullscreenExit];
    }
}

- (void)finishPlayerFullscreenExit {
    self.playerVideoFullscreen = NO;
    self.playerFullscreenButton.title = @"全屏";
    [self removePlayerFullscreenEscapeMonitor];
    [self removePlayerFullscreenMouseMoveMonitor];
    [self.playerFullscreenControlsHideTimer invalidate];
    self.playerFullscreenControlsHideTimer = nil;
    [self installLocalPreviewLayerInPlayerView];
    NSWindow* window = self.playerFullscreenWindow;
    [self.playerFullscreenControlsView removeFromSuperview];
    self.playerFullscreenControlsView = nil;
    self.playerFullscreenSeekSlider = nil;
    self.playerFullscreenCurrentTimeLabel = nil;
    self.playerFullscreenDurationLabel = nil;
    self.playerFullscreenPlayPauseButton = nil;
    self.playerFullscreenWindow = nil;
    self.playerFullscreenHost = nil;
    if (window != nil) {
        window.delegate = nil;
        [window orderOut:nil];
    }
    [self.window makeKeyAndOrderFront:nil];
}

- (void)removePlayerFullscreenEscapeMonitor {
    if (self.playerFullscreenEventMonitor != nil) {
        [NSEvent removeMonitor:self.playerFullscreenEventMonitor];
        self.playerFullscreenEventMonitor = nil;
    }
}

- (void)removePlayerFullscreenMouseMoveMonitor {
    if (self.playerFullscreenMouseMoveMonitor != nil) {
        [NSEvent removeMonitor:self.playerFullscreenMouseMoveMonitor];
        self.playerFullscreenMouseMoveMonitor = nil;
    }
}

- (void)importVideo:(id)sender {
    (void)sender;
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[
        UTTypeMPEG4Movie,
        UTTypeQuickTimeMovie,
        [UTType typeWithFilenameExtension:@"mkv"],
    ];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = YES;

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || panel.URL == nil) {
            return;
        }
        NSArray<NSURL*>* urls = panel.URLs.count > 0 ? panel.URLs : @[panel.URL];
        BOOL first = YES;
        for (NSURL* url in urls) {
            [self addURLToPlaylist:url select:first];
            first = NO;
        }
        NSURL* selected = [NSURL fileURLWithPath:self.importedPath.length > 0 ? self.importedPath : panel.URL.path];
        [self savePlaylistToDefaults];
        [self loadImportedURL:selected autoplay:YES];
    }];
}

- (void)playPreview:(id)sender {
    (void)sender;
    if (self.importedPath.length == 0) {
        self.previewStatusLabel.stringValue = @"请先导入本地视频";
        return;
    }

    [self.previewProcessor cancel];
    [self.onlineProcessor stop];
    NSURL* inputURL = [NSURL fileURLWithPath:self.importedPath];
    const double targetFPS = [self effectiveOnlineTargetFPS];
    NSString* previewOutput = [NSString stringWithFormat:@"%.0ffps / 1x", targetFPS];
    self.previewProcessor = nil;

    AVPlayerItem* item = [AVPlayerItem playerItemWithURL:inputURL];
    AVPlayer* player = [AVPlayer playerWithPlayerItem:item];
    player.volume = static_cast<float>(self.playerVolumeSlider != nil ? self.playerVolumeSlider.doubleValue : 1.0);
    self.activePlayer = player;
    [self installLocalPreviewLayerInPlayerView];
    self.localPreviewView.hidden = YES;
    self.localPreviewLayer.frame = self.localPreviewView.bounds;

    if (self.onlineProcessor == nil) {
        self.onlineProcessor = [SMMotionOnlineProcessor new];
    }
    NSString* modelMode = [self currentRuntimeSettingsPayload][@"rifeBackend"] ?: @"stellaria_sp4_a1p";
    MotionAppDelegate* __weak weakSelf = self;
    [self.onlineProcessor startLocalPlaybackWithPlayer:player
                                                  item:item
                                            targetFPS:targetFPS
                                            flowHeight:[self effectiveRealtimeFlowHeight]
                                           gpuBudgetMs:[self effectiveRealtimeGpuBudgetMs]
                                         frameMultiple:[self effectiveOnlineFrameMultiplier]
                                             modelMode:modelMode
                                       settingsSummary:[self runtimeSettingsSummary]
                                           outputLayer:self.localPreviewLayer
                                              progress:^(NSDictionary<NSString*, id>* status) {
                                                  MotionAppDelegate* __strong self = weakSelf;
                                                  if (self != nil) {
                                                      [self handleLocalPreviewProgress:status];
                                                  }
                                              }];
    self.playerView.player = player;
    player.rate = [self selectedPlayerRate];
    self.previewStatusLabel.stringValue = @"增强播放启动中";
    [self setDiagnosticStatus:@"Realtime preview"
                       output:previewOutput
                        frame:@"正在播放"
                        queue:self.playerSpeedPopup.titleOfSelectedItem ?: @"1.0x"];
}

- (void)handleLocalPreviewProgress:(NSDictionary<NSString*, id>*)status {
    NSString* state = [status[@"state"] isKindOfClass:NSString.class] ? status[@"state"] : @"local_playback";
    NSString* message = [status[@"message"] isKindOfClass:NSString.class] ? status[@"message"] : @"本地视频 INT4 实时插帧中";

    if ([state isEqualToString:@"error"]) {
        self.localPreviewView.hidden = YES;
        self.previewStatusLabel.stringValue = message.length > 0 ? message : @"本地实时插帧启动失败";
        [self setDiagnosticStatus:@"Local preview failed"
                           output:@"增强播放不可用"
                            frame:@"已停止"
                            queue:@"depth 0"];
        return;
    }

    const double width = [status[@"width"] respondsToSelector:@selector(doubleValue)] ? [status[@"width"] doubleValue] : 0.0;
    const double height = [status[@"height"] respondsToSelector:@selector(doubleValue)] ? [status[@"height"] doubleValue] : 0.0;
    const unsigned long long rifeFrames = [status[@"rifeFrames"] respondsToSelector:@selector(unsignedLongLongValue)] ? [status[@"rifeFrames"] unsignedLongLongValue] : 0;
    const BOOL loop = [self stateOfControl:self.playerLoopSwitch fallback:NO];
    const BOOL enhancedActive = rifeFrames > 0;

    self.localPreviewView.hidden = !enhancedActive;
    self.previewStatusLabel.stringValue = enhancedActive ? @"增强播放中" : @"正在准备增强画面";
    self.diagStatusLabel.stringValue = [NSString stringWithFormat:@"状态  %@", enhancedActive ? @"增强播放中" : @"准备中"];
    self.diagFrameRateLabel.stringValue = @"模式  增强播放";
    self.diagOutputLabel.stringValue = width > 0.0 && height > 0.0
        ? [NSString stringWithFormat:@"输出  %.0f x %.0f", width, height]
        : @"输出  --";
    self.diagFrameLabel.stringValue = [NSString stringWithFormat:@"循环  %@", loop ? @"开启" : @"关闭"];
    self.diagQueueLabel.stringValue = [NSString stringWithFormat:@"倍速  %@", self.playerSpeedPopup.titleOfSelectedItem ?: @"1.0x"];
    self.diagKernelLabel.stringValue = [NSString stringWithFormat:@"音量  %.0f%%", self.playerVolumeSlider.doubleValue * 100.0];
}

- (void)startExport:(id)sender {
    (void)sender;
    [self.exportTimer invalidate];
    self.exportTimer = nil;
    self.exportSession = nil;
    [self.offlineProcessor cancel];
    self.offlineProcessor = nil;
    self.exportURL = nil;
    self.exportProgress.doubleValue = 0.0;

    if (self.importedPath.length == 0) {
        self.exportStatusLabel.stringValue = @"请先导入本地视频";
        return;
    }

    NSURL* inputURL = [NSURL fileURLWithPath:self.importedPath];
    NSString* baseName = [[inputURL.lastPathComponent stringByDeletingPathExtension] stringByAppendingString:@"-stellaria-motion.mp4"];

    NSSavePanel* panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[UTTypeMPEG4Movie];
    panel.nameFieldStringValue = baseName;
    panel.canCreateDirectories = YES;

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || panel.URL == nil) {
            self.exportStatusLabel.stringValue = @"导出已取消";
            return;
        }
        [self beginRealExportFromURL:inputURL toURL:panel.URL];
    }];
}

- (void)beginRealExportFromURL:(NSURL*)inputURL toURL:(NSURL*)outputURL {
    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:inputURL options:nil];

    NSError* removeError = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:outputURL.path]) {
        [[NSFileManager defaultManager] removeItemAtURL:outputURL error:&removeError];
    }
    if (removeError != nil) {
        self.exportStatusLabel.stringValue = [NSString stringWithFormat:@"无法覆盖输出文件：%@", removeError.localizedDescription];
        return;
    }

    const CGFloat upscale = self.upscalePopup.indexOfSelectedItem == 1 ? 2.0 : 1.0;
    self.exportURL = outputURL;
    self.exportProgress.doubleValue = 0.0;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVAssetTrack* videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
#pragma clang diagnostic pop
    CGSize naturalSize = videoTrack != nil ? CGSizeApplyAffineTransform(videoTrack.naturalSize, videoTrack.preferredTransform) : CGSizeMake(1920.0, 1080.0);
    naturalSize.width = fabs(naturalSize.width);
    naturalSize.height = fabs(naturalSize.height);
    if (naturalSize.width < 1.0 || naturalSize.height < 1.0) {
        naturalSize = videoTrack != nil ? videoTrack.naturalSize : CGSizeMake(1920.0, 1080.0);
    }

    MotionQualitySettings settings = [self effectiveQualitySettingsForWidth:static_cast<uint32_t>(naturalSize.width)
                                                                      height:static_cast<uint32_t>(naturalSize.height)
                                                                    offline:YES];
    const double targetFPS = [self effectiveOfflineTargetFPS];
    NSString* exportOutput = [NSString stringWithFormat:@"%.0ffps / %.0fx / flow %up",
                              targetFPS,
                              upscale,
                              settings.flowInputHeight];
    self.exportStatusLabel.stringValue = [NSString stringWithFormat:@"导出任务已准备 · %.0ffps · %.0fx", targetFPS, upscale];
    [self setDiagnosticStatus:@"Export rendering"
                       output:exportOutput
                        frame:@"processing"
                        queue:@"depth 1"];

    SMMotionOfflineProcessor* processor = [SMMotionOfflineProcessor new];
    processor.includeAudio = NO;
    self.offlineProcessor = processor;
    [processor startExportFromURL:inputURL
                            toURL:outputURL
                          upscale:upscale
                        targetFPS:targetFPS
                         progress:^(double progressValue, NSString* status) {
                             self.exportProgress.doubleValue = progressValue * 100.0;
                             self.exportStatusLabel.stringValue = status;
                             [self setDiagnosticStatus:@"Export rendering"
                                                output:exportOutput
                                                 frame:[NSString stringWithFormat:@"progress %.0f%%", progressValue * 100.0]
                                                 queue:@"depth 1"];
                         }
                       completion:^(BOOL success, NSString* message) {
                           self.exportProgress.doubleValue = success ? 100.0 : self.exportProgress.doubleValue;
                           self.exportStatusLabel.stringValue = message;
                           [self setDiagnosticStatus:success ? @"Export complete" : @"Export failed"
                                              output:exportOutput
                                               frame:success ? @"drop 0 / repeat 0" : @"writer guarded"
                                               queue:@"depth 0"];
                           self.offlineProcessor = nil;
                       }];
}

- (AVMutableVideoComposition*)videoCompositionForAsset:(AVAsset*)asset upscale:(CGFloat)upscale {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray<AVAssetTrack*>* tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    AVAssetTrack* track = tracks.firstObject;
#pragma clang diagnostic pop
    if (track == nil) {
        return nil;
    }

    CGSize naturalSize = CGSizeApplyAffineTransform(track.naturalSize, track.preferredTransform);
    naturalSize.width = fabs(naturalSize.width);
    naturalSize.height = fabs(naturalSize.height);
    if (naturalSize.width < 1.0 || naturalSize.height < 1.0) {
        naturalSize = track.naturalSize;
    }

    if (upscale > 1.01) {
        const CGSize outputSize = CGSizeMake(naturalSize.width * upscale, naturalSize.height * upscale);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        AVMutableVideoComposition* composition =
            [AVMutableVideoComposition videoCompositionWithAsset:asset
                                      applyingCIFiltersWithHandler:^(AVAsynchronousCIImageFilteringRequest* request) {
                                          CIImage* source = request.sourceImage;
                                          CIFilter* lanczos = [CIFilter filterWithName:@"CILanczosScaleTransform"];
                                          [lanczos setValue:source forKey:kCIInputImageKey];
                                          [lanczos setValue:@(upscale) forKey:kCIInputScaleKey];
                                          [lanczos setValue:@1.0 forKey:kCIInputAspectRatioKey];
                                          CIImage* output = lanczos.outputImage ?: [source imageByApplyingTransform:CGAffineTransformMakeScale(upscale, upscale)];
                                          output = [output imageByCroppingToRect:CGRectMake(0.0, 0.0, outputSize.width, outputSize.height)];
                                          [request finishWithImage:output context:nil];
                                      }];
#pragma clang diagnostic pop
        composition.renderSize = outputSize;
        composition.frameDuration = CMTimeMake(1, 60);
        return composition;
    }

    AVMutableVideoCompositionInstruction* instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = CMTimeRangeMake(kCMTimeZero, asset.duration);

    AVMutableVideoCompositionLayerInstruction* layer = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:track];
    CGAffineTransform transform = track.preferredTransform;
    transform = CGAffineTransformConcat(transform, CGAffineTransformMakeScale(upscale, upscale));
    [layer setTransform:transform atTime:kCMTimeZero];
    instruction.layerInstructions = @[layer];

    AVMutableVideoComposition* composition = [AVMutableVideoComposition videoComposition];
    composition.instructions = @[instruction];
    composition.renderSize = CGSizeMake(naturalSize.width * upscale, naturalSize.height * upscale);
    composition.frameDuration = CMTimeMake(1, 60);
    return composition;
}

- (void)tickExportProgress:(NSTimer*)timer {
    (void)timer;
    if (self.exportSession == nil) {
        return;
    }
    self.exportProgress.doubleValue = self.exportSession.progress * 100.0;
    if (self.exportSession.status == AVAssetExportSessionStatusExporting) {
        self.exportStatusLabel.stringValue = [NSString stringWithFormat:@"正在导出真实视频文件... %.0f%%", self.exportProgress.doubleValue];
    }
}

- (void)applicationWillTerminate:(NSNotification*)notification {
    (void)notification;
    if (self.exportSession.status == AVAssetExportSessionStatusExporting ||
        self.exportSession.status == AVAssetExportSessionStatusWaiting) {
        [self.exportSession cancelExport];
    }
    [self.offlineProcessor cancel];
    [self.previewProcessor cancel];
    [self.onlineProcessor stop];
    [self.browserStreamBridge stop];
    [self hideBrowserOverlay];
    [self exitPlayerFullscreen];
    [self writeOnlineStatus:@{@"running": @NO, @"state": @"stopped", @"message": @"App terminated"}];
    [self.playerControlTimer invalidate];
    [self.playerFullscreenControlsHideTimer invalidate];
    [self removePlayerFullscreenEscapeMonitor];
    [self removePlayerFullscreenMouseMoveMonitor];
    if (self.playerKeyboardEventMonitor != nil) {
        [NSEvent removeMonitor:self.playerKeyboardEventMonitor];
        self.playerKeyboardEventMonitor = nil;
    }
    [self.exportTimer invalidate];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    (void)sender;
    return NO;
}

@end

int main(int argc, const char* argv[]) {
    (void)argc;
    (void)argv;

    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        MotionAppDelegate* delegate = [MotionAppDelegate new];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
