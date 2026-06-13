#include "Video/MotionOnlineProcessor.h"

#include "Core/MotionQuality.h"
#include "Core/RenderGraph.h"
#include "VFI/MotionVFIPipeline.h"
#include "VFI/RIFEMetal4BitRunner.h"
#include "VFI/RIFEMPSGraphRunner.h"
#include "VFI/RIFEModelBackend.h"
#include "VFI/RIFESP4Runner.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <simd/simd.h>

#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <vector>
#include <unistd.h>

using namespace Stellaria::Motion;

namespace {

struct SMBGRAInterpolateParams {
    uint32_t outWidth;
    uint32_t outHeight;
    simd_float2 inverseUpscale;
    float t;
};

struct SMRIFETextureParams {
    uint32_t width;
    uint32_t height;
    uint32_t modelWidth;
    uint32_t modelHeight;
};

NSURL* SMMotionKernelLibraryURL() {
    NSURL* bundled = [[NSBundle mainBundle] URLForResource:@"MotionKernels" withExtension:@"metallib"];
    if (bundled != nil) {
        return bundled;
    }

    NSString* cwd = [[NSFileManager defaultManager] currentDirectoryPath];
    NSURL* cwdURL = [NSURL fileURLWithPath:[cwd stringByAppendingPathComponent:@"MotionKernels.metallib"]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:cwdURL.path]) {
        return cwdURL;
    }
    return nil;
}

uint32_t SMEvenDimension(CGFloat value) {
    uint32_t dimension = static_cast<uint32_t>(llround(MAX(2.0, value)));
    if ((dimension & 1U) != 0U) {
        ++dimension;
    }
    return dimension;
}

uint32_t SMAlign16(NSUInteger value) {
    return static_cast<uint32_t>((value + 15U) & ~15U);
}

uint32_t SMCappedRIFEHeight(NSUInteger sourceHeight, double requestedHeight, double gpuBudgetMs) {
    (void)sourceHeight;
    double capped = requestedHeight > 0.0 ? requestedHeight : 540.0;
    if (gpuBudgetMs > 0.0) {
        if (gpuBudgetMs <= 8.0) {
            capped = MIN(capped, 360.0);
        } else if (gpuBudgetMs <= 16.0) {
            capped = MIN(capped, 540.0);
        } else if (gpuBudgetMs <= 24.0) {
            capped = MIN(capped, 720.0);
        }
    }
    capped = MAX(180.0, MIN(2160.0, capped));
    return SMAlign16(static_cast<NSUInteger>(llround(capped)));
}

uint32_t SMRIFEWidthForHeight(NSUInteger sourceWidth, NSUInteger sourceHeight, uint32_t modelHeight) {
    if (sourceWidth == 0 || sourceHeight == 0 || modelHeight == 0) {
        return 16;
    }
    const double scaledWidth = static_cast<double>(modelHeight) * static_cast<double>(sourceWidth) / static_cast<double>(sourceHeight);
    return SMAlign16(static_cast<NSUInteger>(llround(MAX(16.0, scaledWidth))));
}

double SMCappedSP4RealtimeHeight(double requestedHeight, double gpuBudgetMs, double targetFPS) {
    (void)gpuBudgetMs;
    (void)targetFPS;
    const double requested = requestedHeight > 0.0 ? requestedHeight : 360.0;
    return MAX(128.0, MIN(2160.0, requested));
}

NSString* SMErrorMessage(NSError* error) {
    if (error == nil) {
        return @"未知错误";
    }
    NSString* reason = error.localizedDescription ?: @"ScreenCaptureKit 启动失败";
    if ([reason localizedCaseInsensitiveContainsString:@"permission"] ||
        [reason localizedCaseInsensitiveContainsString:@"TCC"] ||
        [reason localizedCaseInsensitiveContainsString:@"denied"]) {
        return [NSString stringWithFormat:@"%@ · 需要在系统设置授予屏幕录制权限", reason];
    }
    return reason;
}

BOOL SMCreateTexture(CVMetalTextureCacheRef cache,
                     CVPixelBufferRef buffer,
                     MTLPixelFormat format,
                     id<MTLTexture>* textureOut,
                     CVMetalTextureRef* textureRefOut) {
    if (cache == nullptr || buffer == nullptr || textureOut == nullptr || textureRefOut == nullptr) {
        return NO;
    }

    CVMetalTextureRef textureRef = nullptr;
    const size_t width = CVPixelBufferGetWidth(buffer);
    const size_t height = CVPixelBufferGetHeight(buffer);
    const CVReturn result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                      cache,
                                                                      buffer,
                                                                      nullptr,
                                                                      format,
                                                                      width,
                                                                      height,
                                                                      0,
                                                                      &textureRef);
    if (result != kCVReturnSuccess || textureRef == nullptr) {
        return NO;
    }

    id<MTLTexture> texture = CVMetalTextureGetTexture(textureRef);
    if (texture == nil) {
        CFRelease(textureRef);
        return NO;
    }

    *textureOut = texture;
    *textureRefOut = textureRef;
    return YES;
}

BOOL SMCopyTexture(id<MTLCommandBuffer> commandBuffer,
                   id<MTLTexture> source,
                   id<MTLTexture> destination) {
    if (commandBuffer == nil || source == nil || destination == nil ||
        source.width == 0 || source.height == 0 ||
        destination.width == 0 || destination.height == 0) {
        return NO;
    }
    const NSUInteger copyWidth = MIN(source.width, destination.width);
    const NSUInteger copyHeight = MIN(source.height, destination.height);
    if (copyWidth == 0 || copyHeight == 0) {
        return NO;
    }
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    if (blit == nil) {
        return NO;
    }
    [blit copyFromTexture:source
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(copyWidth, copyHeight, 1)
                toTexture:destination
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    return YES;
}

SCDisplay* SMDisplayForRect(NSArray<SCDisplay*>* displays, CGRect rect) API_AVAILABLE(macos(12.3)) {
    if (displays.count == 0) {
        return nil;
    }

    const CGPoint mid = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
    for (SCDisplay* display in displays) {
        if (CGRectContainsPoint(display.frame, mid)) {
            return display;
        }
    }
    return displays.firstObject;
}

CGRect SMLocalRectForDisplay(CGRect rect, SCDisplay* display) API_AVAILABLE(macos(12.3)) {
    CGRect local = rect;
    local.origin.x -= display.frame.origin.x;
    local.origin.y -= display.frame.origin.y;
    local.origin.x = MAX(0.0, local.origin.x);
    local.origin.y = MAX(0.0, local.origin.y);
    local.size.width = MIN(local.size.width, MAX(2.0, static_cast<CGFloat>(display.width) - local.origin.x));
    local.size.height = MIN(local.size.height, MAX(2.0, static_cast<CGFloat>(display.height) - local.origin.y));
    return local;
}

std::filesystem::path SMRIFEModelPath() {
    NSString* resource = [[NSBundle mainBundle] pathForResource:@"flownet"
                                                         ofType:@"safetensors"
                                                    inDirectory:@"Models/RIFE-safetensors"];
    if (resource.length > 0) {
        return std::filesystem::path(resource.UTF8String);
    }
    if (const char* env = std::getenv("STELLARIA_MOTION_RIFE_MODEL")) {
        return std::filesystem::path(env);
    }
    return std::filesystem::path("Models/RIFE-safetensors/flownet.safetensors");
}

NSArray<SCWindow*>* SMWindowsOwnedByCurrentProcess(SCShareableContent* content) API_AVAILABLE(macos(12.3)) {
    const pid_t pid = getpid();
    NSMutableArray<SCWindow*>* windows = [NSMutableArray array];
    for (SCWindow* window in content.windows) {
        if (window.owningApplication.processID == pid) {
            [windows addObject:window];
        }
    }
    return windows;
}

} // namespace

@interface SMMotionOnlineProcessor () <SCStreamOutput, SCStreamDelegate>
@property(strong) SCStream* stream;
@property(strong) dispatch_queue_t sampleQueue;
@property(strong) dispatch_queue_t displayQueue;
@property(strong) dispatch_source_t displayTimer;
@property(strong) dispatch_source_t localFrameTimer;
@property(copy) SMMotionOnlineProgressHandler progress;
@property(assign) CGRect captureRect;
@property(assign) double targetFPS;
@property(assign) double frameMultiple;
@property(assign) uint32_t flowHeight;
@property(assign) double gpuBudgetMs;
@property(copy) NSString* modelMode;
@property(copy) NSString* settingsSummary;
@property(strong) id<MTLDevice> device;
@property(strong) id<MTLCommandQueue> commandQueue;
@property(strong) id<MTLComputePipelineState> interpolatePipeline;
@property(strong) id<MTLComputePipelineState> rifePackPipeline;
@property(strong) id<MTLComputePipelineState> rifeUnpackPipeline;
@property(strong) CAMetalLayer* outputLayer;
@property(assign) CVMetalTextureCacheRef textureCache;
@property(strong) id<MTLTexture> outputTexture;
@property(strong) id<MTLTexture> displayCurrentTexture;
@property(strong) id<MTLTexture> displayMidTexture;
@property(strong) id<MTLTexture> displayLateTexture;
@property(strong) id<MTLTexture> displayNextTexture;
@property(strong) NSArray* displaySubframeTextures;
@property(assign) Stellaria::Motion::RIFEMPSGraphRunner* rifeRunner;
@property(assign) Stellaria::Motion::RIFEMetal4BitRunner* rifeMetal4Runner;
@property(assign) Stellaria::Motion::RIFESP4Runner* rifeSP4Runner;
@property(strong) id<MTLBuffer> rifeInputBuffer;
@property(strong) id<MTLBuffer> rifeOutputBuffer;
@property(assign) NSUInteger rifeModelWidth;
@property(assign) NSUInteger rifeModelHeight;
@property(assign) uint64_t rifeFrames;
@property(assign) CVPixelBufferRef previousBuffer;
@property(assign) CMTime previousPTS;
@property(strong) AVPlayer* localPlayer;
@property(strong) AVPlayerItem* localPlayerItem;
@property(strong) AVPlayerItemVideoOutput* localVideoOutput;
@property(assign) CFTimeInterval sequenceStartTime;
@property(assign) double sequenceDuration;
@property(assign) BOOL sequenceReady;
@property(assign) NSUInteger sequenceSubframeCount;
@property(assign) BOOL sequenceShowsNextFrame;
@property(assign) uint64_t sequencePairIndex;
@property(assign) CFTimeInterval startTime;
@property(assign) CFTimeInterval lastReportTime;
@property(assign) uint64_t inputFrames;
@property(assign) uint64_t generatedFrames;
@property(assign) uint64_t droppedFrames;
@property(assign) uint64_t repeatedFrames;
@property(assign) double lastGpuMs;
@property(copy) NSString* graphSummary;
- (BOOL)prepareMetalRuntimeForDrawableSize:(CGSize)drawableSize errorMessage:(NSString**)errorMessage;
- (void)startLocalFrameTimer;
- (void)pullLocalVideoFrame;
- (void)consumePixelBuffer:(CVPixelBufferRef)currentBuffer pts:(CMTime)pts;
- (BOOL)processTexturesWithRIFESP4Previous:(id<MTLTexture>)previous current:(id<MTLTexture>)current outputs:(NSArray*)outputs tValues:(const float*)tValues count:(NSUInteger)count width:(NSUInteger)width height:(NSUInteger)height;
- (BOOL)processTexturesWithRIFESP4Previous:(id<MTLTexture>)previous current:(id<MTLTexture>)current output:(id<MTLTexture>)output lateOutput:(id<MTLTexture>)lateOutput width:(NSUInteger)width height:(NSUInteger)height primaryT:(float)primaryT lateT:(float)lateT;
@end

@implementation SMMotionOnlineProcessor

- (instancetype)init {
    self = [super init];
    if (self) {
        _rifeRunner = new Stellaria::Motion::RIFEMPSGraphRunner();
        _rifeMetal4Runner = new Stellaria::Motion::RIFEMetal4BitRunner();
        _rifeSP4Runner = new Stellaria::Motion::RIFESP4Runner();
    }
    return self;
}

- (void)dealloc {
    [self stop];
    delete _rifeRunner;
    _rifeRunner = nullptr;
    delete _rifeMetal4Runner;
    _rifeMetal4Runner = nullptr;
    delete _rifeSP4Runner;
    _rifeSP4Runner = nullptr;
    if (_textureCache != nullptr) {
        CFRelease(_textureCache);
        _textureCache = nullptr;
    }
    if (_previousBuffer != nullptr) {
        CVPixelBufferRelease(_previousBuffer);
        _previousBuffer = nullptr;
    }
}

- (BOOL)prepareMetalRuntimeForDrawableSize:(CGSize)drawableSize errorMessage:(NSString**)errorMessage {
    self.device = MTLCreateSystemDefaultDevice();
    self.commandQueue = self.device != nil ? [self.device newCommandQueue] : nil;
    if (self.commandQueue != nil && self.rifeMetal4Runner != nullptr) {
        self.rifeMetal4Runner->SetCommandQueue((__bridge void*)self.commandQueue);
    }
    if (self.commandQueue != nil && self.rifeSP4Runner != nullptr) {
        self.rifeSP4Runner->SetCommandQueue((__bridge void*)self.commandQueue);
    }
    if (self.commandQueue != nil && self.rifeRunner != nullptr) {
        self.rifeRunner->SetCommandQueue((__bridge void*)self.commandQueue);
    }

    if (_textureCache != nullptr) {
        CFRelease(_textureCache);
        _textureCache = nullptr;
    }
    CVReturn cacheResult = kCVReturnError;
    if (self.device != nil) {
        cacheResult = CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, self.device, nullptr, &_textureCache);
    }

    NSError* metalError = nil;
    NSURL* libraryURL = SMMotionKernelLibraryURL();
    id<MTLLibrary> library = libraryURL != nil ? [self.device newLibraryWithURL:libraryURL error:&metalError] : nil;
    id<MTLFunction> function = [library newFunctionWithName:@"fused_bgra_interpolate_lanczos_present"];
    self.interpolatePipeline = function != nil ? [self.device newComputePipelineStateWithFunction:function error:&metalError] : nil;
    id<MTLFunction> packFunction = [library newFunctionWithName:@"pack_bgra_pair_to_rife_input"];
    id<MTLFunction> unpackFunction = [library newFunctionWithName:@"unpack_rife_output_to_bgra"];
    self.rifePackPipeline = packFunction != nil ? [self.device newComputePipelineStateWithFunction:packFunction error:&metalError] : nil;
    self.rifeUnpackPipeline = unpackFunction != nil ? [self.device newComputePipelineStateWithFunction:unpackFunction error:&metalError] : nil;

    if (self.device == nil || self.commandQueue == nil || cacheResult != kCVReturnSuccess || self.interpolatePipeline == nil || self.rifePackPipeline == nil || self.rifeUnpackPipeline == nil) {
        if (errorMessage != nullptr) {
            *errorMessage = [NSString stringWithFormat:@"Metal 在线插帧初始化失败：%@", metalError.localizedDescription ?: @"kernel unavailable"];
        }
        return NO;
    }

    if (self.outputLayer != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.outputLayer.device = self.device;
            self.outputLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            self.outputLayer.framebufferOnly = NO;
            self.outputLayer.presentsWithTransaction = NO;
            if ([self.outputLayer respondsToSelector:NSSelectorFromString(@"setAllowsNextDrawableTimeout:")]) {
                [self.outputLayer setValue:@NO forKey:@"allowsNextDrawableTimeout"];
            }
            if ([self.outputLayer respondsToSelector:NSSelectorFromString(@"setMaximumDrawableCount:")]) {
                [self.outputLayer setValue:@3 forKey:@"maximumDrawableCount"];
            }
            self.outputLayer.drawableSize = CGSizeMake(MAX(2.0, round(drawableSize.width)),
                                                       MAX(2.0, round(drawableSize.height)));
        });
    }
    return YES;
}

- (void)startCaptureWithRect:(CGRect)rect
                   targetFPS:(double)targetFPS
                  flowHeight:(uint32_t)flowHeight
                  gpuBudgetMs:(double)gpuBudgetMs
               frameMultiple:(double)frameMultiple
                   modelMode:(NSString*)modelMode
             settingsSummary:(NSString*)settingsSummary
                  outputLayer:(CAMetalLayer*)outputLayer
                    progress:(SMMotionOnlineProgressHandler)progress {
    [self stop];

    self.progress = progress;
    self.captureRect = rect;
    self.targetFPS = MAX(24.0, targetFPS);
    self.flowHeight = MAX(1U, flowHeight);
    self.gpuBudgetMs = MAX(4.0, MIN(40.0, gpuBudgetMs));
    self.frameMultiple = MAX(1.0, frameMultiple);
    self.modelMode = modelMode.length > 0 ? modelMode : @"stellaria_sp4_a1p";
    self.settingsSummary = settingsSummary ?: @"";
    self.outputLayer = outputLayer;
    self.sampleQueue = dispatch_queue_create("studio.stellaria.motion.online.sample", DISPATCH_QUEUE_SERIAL);
    self.displayQueue = dispatch_queue_create("studio.stellaria.motion.online.display", DISPATCH_QUEUE_SERIAL);
    self.startTime = CACurrentMediaTime();
    self.lastReportTime = 0.0;
    self.sequenceStartTime = 0.0;
    self.sequenceDuration = 1.0 / MAX(24.0, self.targetFPS);
    self.sequenceReady = NO;
    self.sequenceSubframeCount = 1;
    self.sequenceShowsNextFrame = YES;
    self.sequencePairIndex = 0;
    self.inputFrames = 0;
    self.generatedFrames = 0;
    self.droppedFrames = 0;
    self.repeatedFrames = 0;
    self.lastGpuMs = 0.0;
    self.previousPTS = kCMTimeInvalid;

    if (rect.size.width < 2.0 || rect.size.height < 2.0) {
        [self emit:@{@"state": @"error", @"message": @"浏览器视频 rect 无效，先播放或滚动到视频区域"}];
        return;
    }

    if (@available(macOS 12.3, *)) {
        if (!CGPreflightScreenCaptureAccess()) {
            const bool requested = CGRequestScreenCaptureAccess();
            if (!requested && !CGPreflightScreenCaptureAccess()) {
                [self emit:@{@"state": @"error",
                             @"message": @"ScreenCaptureKit 权限未授予：请在系统设置 > 隐私与安全性 > 屏幕与系统录音 中启用 Stellaria Motion，然后重启 App"}];
                return;
            }
        }

        NSString* metalError = nil;
        if (![self prepareMetalRuntimeForDrawableSize:CGSizeMake(SMEvenDimension(rect.size.width), SMEvenDimension(rect.size.height)) errorMessage:&metalError]) {
            [self emit:@{@"state": @"error",
                         @"message": metalError ?: @"Metal 在线插帧初始化失败"}];
            return;
        }
        [self startDisplayTimer];

        [self rebuildGraphSummaryForWidth:SMEvenDimension(rect.size.width) height:SMEvenDimension(rect.size.height)];
        [self emit:@{@"state": @"starting",
                     @"message": @"正在启动 ScreenCaptureKit 在线插帧",
                     @"pipeline": self.graphSummary ?: @"RenderGraph pending"}];

        SMMotionOnlineProcessor* __weak weakSelf = self;
        [SCShareableContent getShareableContentExcludingDesktopWindows:YES
                                                   onScreenWindowsOnly:YES
                                                     completionHandler:^(SCShareableContent* content, NSError* error) {
            SMMotionOnlineProcessor* __strong self = weakSelf;
            if (self == nil) {
                return;
            }
            if (content == nil || error != nil) {
                [self emit:@{@"state": @"error", @"message": SMErrorMessage(error)}];
                return;
            }

            SCDisplay* display = SMDisplayForRect(content.displays, rect);
            if (display == nil) {
                [self emit:@{@"state": @"error", @"message": @"未找到可捕获显示器"}];
                return;
            }

            CGRect localRect = SMLocalRectForDisplay(rect, display);
            NSArray<SCWindow*>* excludedWindows = SMWindowsOwnedByCurrentProcess(content);
            SCContentFilter* filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:excludedWindows];
            SCStreamConfiguration* config = [SCStreamConfiguration new];
            config.width = SMEvenDimension(localRect.size.width);
            config.height = SMEvenDimension(localRect.size.height);
            config.sourceRect = localRect;
            config.pixelFormat = kCVPixelFormatType_32BGRA;
            const double captureFPS = MAX(24.0, MIN(60.0, self.targetFPS / MAX(1.0, self.frameMultiple)));
            config.minimumFrameInterval = CMTimeMake(1, static_cast<int32_t>(llround(captureFPS)));
            config.queueDepth = 3;
            config.showsCursor = NO;
            config.capturesAudio = NO;

            self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
            NSError* outputError = nil;
            if (![self.stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.sampleQueue error:&outputError]) {
                [self emit:@{@"state": @"error", @"message": SMErrorMessage(outputError)}];
                self.stream = nil;
                return;
            }

            [self.stream startCaptureWithCompletionHandler:^(NSError* startError) {
                if (startError != nil) {
                    [self emit:@{@"state": @"error", @"message": SMErrorMessage(startError)}];
                    self.stream = nil;
                    return;
                }
                self.running = YES;
                [self emit:@{@"state": @"capturing",
                             @"message": @"在线插帧捕获中",
                             @"width": @(config.width),
                             @"height": @(config.height),
                             @"pipeline": self.graphSummary ?: @"SCK -> Metal fused VFI"}];
            }];
        }];
    } else {
        [self emit:@{@"state": @"error", @"message": @"当前 macOS 不支持 ScreenCaptureKit"}];
    }
}

- (void)startLocalPlaybackWithPlayer:(AVPlayer*)player
                                 item:(AVPlayerItem*)item
                            targetFPS:(double)targetFPS
                           flowHeight:(uint32_t)flowHeight
                          gpuBudgetMs:(double)gpuBudgetMs
                        frameMultiple:(double)frameMultiple
                            modelMode:(NSString*)modelMode
                      settingsSummary:(NSString*)settingsSummary
                          outputLayer:(CAMetalLayer*)outputLayer
                             progress:(SMMotionOnlineProgressHandler)progress {
    [self stop];
    self.progress = progress;

    if (player == nil || item == nil) {
        [self emit:@{@"state": @"error", @"message": @"本地播放器未就绪"}];
        return;
    }

    self.targetFPS = MAX(24.0, targetFPS);
    self.flowHeight = MAX(1U, flowHeight);
    self.gpuBudgetMs = MAX(4.0, MIN(40.0, gpuBudgetMs));
    self.frameMultiple = MAX(1.0, frameMultiple);
    self.modelMode = modelMode.length > 0 ? modelMode : @"stellaria_sp4_a1p";
    self.settingsSummary = settingsSummary ?: @"";
    self.outputLayer = outputLayer;
    self.localPlayer = player;
    self.localPlayerItem = item;
    self.sampleQueue = dispatch_queue_create("studio.stellaria.motion.local.sample", DISPATCH_QUEUE_SERIAL);
    self.displayQueue = dispatch_queue_create("studio.stellaria.motion.local.display", DISPATCH_QUEUE_SERIAL);
    self.startTime = CACurrentMediaTime();
    self.lastReportTime = 0.0;
    self.sequenceStartTime = 0.0;
    self.sequenceDuration = 1.0 / MAX(24.0, self.targetFPS);
    self.sequenceReady = NO;
    self.sequenceSubframeCount = 1;
    self.sequenceShowsNextFrame = YES;
    self.sequencePairIndex = 0;
    self.inputFrames = 0;
    self.generatedFrames = 0;
    self.droppedFrames = 0;
    self.repeatedFrames = 0;
    self.lastGpuMs = 0.0;
    self.previousPTS = kCMTimeInvalid;

    NSDictionary* outputAttributes = @{
        (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString*)kCVPixelBufferMetalCompatibilityKey: @YES,
        (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    self.localVideoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:outputAttributes];
    if ([self.localVideoOutput respondsToSelector:NSSelectorFromString(@"setSuppressesPlayerRendering:")]) {
        [self.localVideoOutput setValue:@YES forKey:@"suppressesPlayerRendering"];
    }
    [item addOutput:self.localVideoOutput];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVAssetTrack* track = [[item.asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
#pragma clang diagnostic pop
    CGSize naturalSize = track != nil ? CGSizeApplyAffineTransform(track.naturalSize, track.preferredTransform) : CGSizeMake(1920.0, 1080.0);
    naturalSize.width = fabs(naturalSize.width);
    naturalSize.height = fabs(naturalSize.height);
    if (naturalSize.width < 2.0 || naturalSize.height < 2.0) {
        naturalSize = CGSizeMake(1920.0, 1080.0);
    }

    NSString* metalError = nil;
    if (![self prepareMetalRuntimeForDrawableSize:naturalSize errorMessage:&metalError]) {
        [self emit:@{@"state": @"error", @"message": metalError ?: @"Metal 本地插帧初始化失败"}];
        return;
    }

    [self rebuildGraphSummaryForWidth:SMEvenDimension(naturalSize.width) height:SMEvenDimension(naturalSize.height)];
    self.running = YES;
    [self startDisplayTimer];
    [self startLocalFrameTimer];
    [self.localVideoOutput requestNotificationOfMediaDataChangeWithAdvanceInterval:0.03];
    [player play];
    [self emit:@{@"state": @"local_playback",
                 @"message": @"本地视频实时增强中",
                 @"width": @(naturalSize.width),
                 @"height": @(naturalSize.height),
                 @"pipeline": self.graphSummary ?: @"AVPlayerItemVideoOutput -> Metal INT4 -> CAMetalLayer"}];
}

- (void)stop {
    self.running = NO;
    if (_previousBuffer != nullptr) {
        CVPixelBufferRelease(_previousBuffer);
        _previousBuffer = nullptr;
    }
    self.previousPTS = kCMTimeInvalid;
    self.outputTexture = nil;
    self.displayCurrentTexture = nil;
    self.displayMidTexture = nil;
    self.displayLateTexture = nil;
    self.displayNextTexture = nil;
    self.displaySubframeTextures = nil;
    self.rifeInputBuffer = nil;
    self.rifeOutputBuffer = nil;
    self.sequenceReady = NO;
    self.sequenceSubframeCount = 1;
    self.sequenceShowsNextFrame = YES;
    dispatch_source_t timer = self.displayTimer;
    self.displayTimer = nil;
    if (timer != nil) {
        dispatch_source_cancel(timer);
    }
    dispatch_source_t localTimer = self.localFrameTimer;
    self.localFrameTimer = nil;
    if (localTimer != nil) {
        dispatch_source_cancel(localTimer);
    }
    if (self.localVideoOutput != nil && self.localPlayerItem != nil) {
        [self.localPlayerItem removeOutput:self.localVideoOutput];
    }
    [self.localPlayer pause];
    self.localVideoOutput = nil;
    self.localPlayerItem = nil;
    self.localPlayer = nil;
    self.outputLayer = nil;
    self.sampleQueue = nil;
    self.displayQueue = nil;
    SCStream* stream = self.stream;
    self.stream = nil;
    if (stream != nil) {
        [stream stopCaptureWithCompletionHandler:nil];
    }
}

- (void)stream:(SCStream*)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    (void)stream;
    if (type != SCStreamOutputTypeScreen || sampleBuffer == nullptr || !CMSampleBufferIsValid(sampleBuffer)) {
        self.droppedFrames += 1;
        return;
    }

    CVPixelBufferRef currentBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (currentBuffer == nullptr) {
        self.droppedFrames += 1;
        return;
    }

    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (CMTIME_IS_INVALID(pts)) {
        pts = CMTimeMake(static_cast<int64_t>(self.inputFrames), static_cast<int32_t>(MAX(24.0, self.targetFPS)));
    }
    [self consumePixelBuffer:currentBuffer pts:pts];
}

- (void)consumePixelBuffer:(CVPixelBufferRef)currentBuffer pts:(CMTime)pts {
    if (currentBuffer == nullptr) {
        self.droppedFrames += 1;
        return;
    }
    self.inputFrames += 1;
    if (CMTIME_IS_INVALID(pts)) {
        pts = CMTimeMake(static_cast<int64_t>(self.inputFrames), static_cast<int32_t>(MAX(24.0, self.targetFPS)));
    }
    if (self.previousBuffer != nullptr) {
        if (CMTIME_IS_VALID(self.previousPTS) && CMTimeCompare(pts, self.previousPTS) <= 0) {
            self.repeatedFrames += 1;
        } else {
            [self generateIntermediateFromPrevious:self.previousBuffer current:currentBuffer currentPTS:pts t:0.5];
        }
    } else {
        [self copyInitialFrameForDisplay:currentBuffer];
    }

    if (self.previousBuffer != nullptr) {
        CVPixelBufferRelease(self.previousBuffer);
    }
    self.previousBuffer = CVPixelBufferRetain(currentBuffer);
    self.previousPTS = pts;

    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.lastReportTime > 0.35) {
        self.lastReportTime = now;
        [self reportCaptureStatusWithBuffer:currentBuffer now:now];
    }
}

- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error {
    (void)stream;
    self.running = NO;
    [self emit:@{@"state": @"error", @"message": SMErrorMessage(error)}];
}

- (id<MTLTexture>)ensureDisplayTexture:(id<MTLTexture>)texture width:(NSUInteger)width height:(NSUInteger)height {
    if (texture != nil && texture.width == width && texture.height == height) {
        return texture;
    }
    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:width
                                                                                         height:height
                                                                                      mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead |
                       MTLTextureUsageShaderWrite;
    descriptor.storageMode = MTLStorageModePrivate;
    return [self.device newTextureWithDescriptor:descriptor];
}

- (void)startDisplayTimer {
    dispatch_source_t oldTimer = self.displayTimer;
    if (oldTimer != nil) {
        dispatch_source_cancel(oldTimer);
        self.displayTimer = nil;
    }
    dispatch_queue_t queue = self.displayQueue ?: self.sampleQueue;
    if (queue == nil) {
        return;
    }
    const double fps = MAX(24.0, self.targetFPS);
    const uint64_t intervalNs = static_cast<uint64_t>(MAX(1.0, 1000000000.0 / fps));
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(intervalNs)),
                              intervalNs,
                              static_cast<uint64_t>(intervalNs / 16));
    SMMotionOnlineProcessor* __weak weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        SMMotionOnlineProcessor* __strong self = weakSelf;
        if (self != nil) {
            [self presentDisplayTick];
        }
    });
    self.displayTimer = timer;
    dispatch_resume(timer);
}

- (void)startLocalFrameTimer {
    dispatch_source_t oldTimer = self.localFrameTimer;
    if (oldTimer != nil) {
        dispatch_source_cancel(oldTimer);
        self.localFrameTimer = nil;
    }
    if (self.sampleQueue == nil) {
        return;
    }
    const double fps = MAX(60.0, MIN(240.0, self.targetFPS));
    const uint64_t intervalNs = static_cast<uint64_t>(MAX(1.0, 1000000000.0 / fps));
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.sampleQueue);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(intervalNs)),
                              intervalNs,
                              static_cast<uint64_t>(intervalNs / 8));
    SMMotionOnlineProcessor* __weak weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        SMMotionOnlineProcessor* __strong self = weakSelf;
        if (self != nil) {
            [self pullLocalVideoFrame];
        }
    });
    self.localFrameTimer = timer;
    dispatch_resume(timer);
}

- (void)pullLocalVideoFrame {
    if (!self.running || self.localVideoOutput == nil) {
        return;
    }

    CFTimeInterval hostTime = CACurrentMediaTime();
    CMTime itemTime = [self.localVideoOutput itemTimeForHostTime:hostTime];
    if (CMTIME_IS_INVALID(itemTime)) {
        itemTime = self.localPlayer.currentTime;
    }
    if (CMTIME_IS_INVALID(itemTime) || ![self.localVideoOutput hasNewPixelBufferForItemTime:itemTime]) {
        return;
    }

    CVPixelBufferRef buffer = [self.localVideoOutput copyPixelBufferForItemTime:itemTime itemTimeForDisplay:nullptr];
    if (buffer == nullptr) {
        self.droppedFrames += 1;
        return;
    }
    [self consumePixelBuffer:buffer pts:itemTime];
    CVPixelBufferRelease(buffer);
}

- (void)copyInitialFrameForDisplay:(CVPixelBufferRef)buffer {
    id<MTLTexture> currentTexture = nil;
    CVMetalTextureRef currentRef = nullptr;
    if (!SMCreateTexture(self.textureCache, buffer, MTLPixelFormatBGRA8Unorm, &currentTexture, &currentRef)) {
        if (currentRef != nullptr) {
            CFRelease(currentRef);
        }
        self.droppedFrames += 1;
        return;
    }

    const NSUInteger width = CVPixelBufferGetWidth(buffer);
    const NSUInteger height = CVPixelBufferGetHeight(buffer);
    self.displayCurrentTexture = [self ensureDisplayTexture:self.displayCurrentTexture width:width height:height];
    if (self.displayCurrentTexture == nil) {
        CFRelease(currentRef);
        self.droppedFrames += 1;
        return;
    }

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLTexture> displayTexture = self.displayCurrentTexture;
    if (!SMCopyTexture(commandBuffer, currentTexture, displayTexture)) {
        CFRelease(currentRef);
        self.droppedFrames += 1;
        return;
    }
    [commandBuffer addCompletedHandler:^(__unused id<MTLCommandBuffer> completed) {
        CFRelease(currentRef);
    }];
    [commandBuffer commit];
}

- (void)presentTexture:(id<MTLTexture>)texture {
    if (texture == nil || self.outputLayer == nil || self.commandQueue == nil) {
        return;
    }
    id<CAMetalDrawable> drawable = [self.outputLayer nextDrawable];
    if (drawable == nil) {
        self.droppedFrames += 1;
        return;
    }

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    const NSUInteger copyWidth = MIN(texture.width, drawable.texture.width);
    const NSUInteger copyHeight = MIN(texture.height, drawable.texture.height);
    [blit copyFromTexture:texture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(copyWidth, copyHeight, 1)
                toTexture:drawable.texture
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

- (void)presentDisplayTick {
    if (!self.running) {
        return;
    }

    id<MTLTexture> texture = self.displayCurrentTexture;
    NSArray* subframes = self.displaySubframeTextures;
    if (self.sequenceReady && subframes.count > 0 && self.displayNextTexture != nil) {
        const CFTimeInterval now = CACurrentMediaTime();
        const double phase = (now - self.sequenceStartTime) / MAX(0.008, self.sequenceDuration);
        const NSUInteger count = subframes.count;
        if (phase >= 1.0) {
            id<MTLTexture> lastSubframe = [subframes.lastObject conformsToProtocol:@protocol(MTLTexture)] ? subframes.lastObject : nil;
            self.displayCurrentTexture = self.sequenceShowsNextFrame ? self.displayNextTexture : lastSubframe;
            self.displayNextTexture = nil;
            self.displaySubframeTextures = nil;
            self.displayMidTexture = nil;
            self.displayLateTexture = nil;
            self.sequenceReady = NO;
            self.sequenceSubframeCount = 1;
            self.sequenceShowsNextFrame = YES;
            texture = self.displayCurrentTexture;
        } else {
            const double step = 1.0 / static_cast<double>(count + 1);
            const double firstThreshold = step * 0.92;
            if (phase >= firstThreshold) {
                NSUInteger index = static_cast<NSUInteger>(floor((phase - firstThreshold) / step));
                index = MIN(index, count - 1);
                id candidate = subframes[index];
                if ([candidate conformsToProtocol:@protocol(MTLTexture)]) {
                    texture = candidate;
                }
            }
        }
    } else if (self.sequenceReady && self.displayMidTexture != nil && self.displayNextTexture != nil) {
        const CFTimeInterval now = CACurrentMediaTime();
        const double phase = (now - self.sequenceStartTime) / MAX(0.008, self.sequenceDuration);
        const BOOL hasLateSubframe = self.sequenceSubframeCount >= 2 && self.displayLateTexture != nil;
        if (hasLateSubframe) {
            if (phase >= 0.30 && phase < 0.64) {
                texture = self.displayMidTexture;
            } else if (phase >= 0.64 && phase < 1.0) {
                texture = self.displayLateTexture;
            } else if (phase >= 1.0) {
                self.displayCurrentTexture = self.sequenceShowsNextFrame ? self.displayNextTexture : self.displayLateTexture;
                self.displayNextTexture = nil;
                self.sequenceReady = NO;
                self.sequenceSubframeCount = 1;
                self.sequenceShowsNextFrame = YES;
                texture = self.displayCurrentTexture;
            }
        } else if (phase >= 0.38 && phase < 0.76) {
            texture = self.displayMidTexture;
        } else if (phase >= 0.76) {
            self.displayCurrentTexture = self.displayNextTexture;
            self.displayNextTexture = nil;
            self.sequenceReady = NO;
            self.sequenceSubframeCount = 1;
            self.sequenceShowsNextFrame = YES;
            texture = self.displayCurrentTexture;
        }
    }
    [self presentTexture:texture];
}

- (BOOL)processTexturesWithRIFEMetal4Previous:(id<MTLTexture>)previous current:(id<MTLTexture>)current output:(id<MTLTexture>)output width:(NSUInteger)width height:(NSUInteger)height t:(float)t {
    if (previous == nil || current == nil || output == nil || self.rifeMetal4Runner == nullptr) {
        return NO;
    }

    const double requestedHeight = SMCappedSP4RealtimeHeight(self.flowHeight > 0 ? static_cast<double>(self.flowHeight) : 360.0,
                                                            self.gpuBudgetMs,
                                                            self.targetFPS);
    const NSUInteger sourceCapped = static_cast<NSUInteger>(MIN(static_cast<double>(height), requestedHeight));
    const NSUInteger modelHeight = MAX(static_cast<NSUInteger>(128), static_cast<NSUInteger>(SMAlign16(sourceCapped)));
    const NSUInteger modelWidth = SMRIFEWidthForHeight(width, height, static_cast<uint32_t>(modelHeight));
    if (!self.rifeMetal4Runner->IsReady() || self.rifeModelWidth != modelWidth || self.rifeModelHeight != modelHeight) {
        self.rifeMetal4Runner->SetCommandQueue((__bridge void*)self.commandQueue);
        if (!self.rifeMetal4Runner->Load(SMRIFEModelPath().string(), static_cast<uint32_t>(modelWidth), static_cast<uint32_t>(modelHeight))) {
            self.graphSummary = [NSString stringWithFormat:@"Metal INT4 unavailable: %s · fallback", self.rifeMetal4Runner->Diagnostics().c_str()];
            return NO;
        }
        self.rifeModelWidth = modelWidth;
        self.rifeModelHeight = modelHeight;
    }

    const Stellaria::Motion::RIFEMetal4BitRunResult result =
        self.rifeMetal4Runner->RunTexturesAtT((__bridge void*)previous,
                                              (__bridge void*)current,
                                              (__bridge void*)output,
                                              static_cast<uint32_t>(width),
                                              static_cast<uint32_t>(height),
                                              t);
    if (!result.ok) {
        self.graphSummary = [NSString stringWithFormat:@"Metal INT4 failed: %s · fallback", result.message.c_str()];
        return NO;
    }
    self.rifeFrames += 1;
    self.lastGpuMs = result.elapsedMs;
    self.graphSummary = [NSString stringWithFormat:@"RIFE Metal INT4 · %ux%u model · %.2fms / 16.67ms",
                                                   result.modelWidth,
                                                   result.modelHeight,
                                                   result.elapsedMs];
    return YES;
}

- (BOOL)processTexturesWithRIFESP4Previous:(id<MTLTexture>)previous current:(id<MTLTexture>)current output:(id<MTLTexture>)output width:(NSUInteger)width height:(NSUInteger)height t:(float)t {
    if (previous == nil || current == nil || output == nil || self.rifeSP4Runner == nullptr) {
        return NO;
    }

    const double requestedHeight = SMCappedSP4RealtimeHeight(self.flowHeight > 0 ? static_cast<double>(self.flowHeight) : 360.0,
                                                            self.gpuBudgetMs,
                                                            self.targetFPS);
    const NSUInteger sourceCapped = static_cast<NSUInteger>(MIN(static_cast<double>(height), requestedHeight));
    const NSUInteger modelHeight = MAX(static_cast<NSUInteger>(128), static_cast<NSUInteger>(SMAlign16(sourceCapped)));
    const NSUInteger modelWidth = SMRIFEWidthForHeight(width, height, static_cast<uint32_t>(modelHeight));
    if (!self.rifeSP4Runner->IsReady() || self.rifeModelWidth != modelWidth || self.rifeModelHeight != modelHeight) {
        self.rifeSP4Runner->SetCommandQueue((__bridge void*)self.commandQueue);
        if (!self.rifeSP4Runner->Load(SMRIFEModelPath().string(), static_cast<uint32_t>(modelWidth), static_cast<uint32_t>(modelHeight))) {
            self.graphSummary = [NSString stringWithFormat:@"SP4 A1P unavailable: %s · fallback", self.rifeSP4Runner->Diagnostics().c_str()];
            return NO;
        }
        self.rifeModelWidth = modelWidth;
        self.rifeModelHeight = modelHeight;
    }

    const Stellaria::Motion::RIFESP4RunResult result =
        self.rifeSP4Runner->RunTexturesAtT((__bridge void*)previous,
                                           (__bridge void*)current,
                                           (__bridge void*)output,
                                           static_cast<uint32_t>(width),
                                           static_cast<uint32_t>(height),
                                           t);
    if (!result.ok) {
        self.graphSummary = [NSString stringWithFormat:@"SP4 A1P failed: %s · fallback", result.message.c_str()];
        return NO;
    }
    self.rifeFrames += 1;
    self.lastGpuMs = result.elapsedMs;
    self.graphSummary = [NSString stringWithFormat:@"Stellaria SP4 SDK · %ux%u model · %.2fms / 16.67ms",
                                                   result.modelWidth,
                                                   result.modelHeight,
                                                   result.elapsedMs];
    return YES;
}

- (BOOL)processTexturesWithRIFESP4Previous:(id<MTLTexture>)previous current:(id<MTLTexture>)current output:(id<MTLTexture>)output lateOutput:(id<MTLTexture>)lateOutput width:(NSUInteger)width height:(NSUInteger)height primaryT:(float)primaryT lateT:(float)lateT {
    if (previous == nil || current == nil || output == nil || lateOutput == nil || self.rifeSP4Runner == nullptr) {
        return NO;
    }
    const float tValues[2] = {primaryT, lateT};
    return [self processTexturesWithRIFESP4Previous:previous
                                           current:current
                                           outputs:@[output, lateOutput]
                                           tValues:tValues
                                             count:2
                                             width:width
                                            height:height];
}

- (BOOL)processTexturesWithRIFESP4Previous:(id<MTLTexture>)previous current:(id<MTLTexture>)current outputs:(NSArray*)outputs tValues:(const float*)tValues count:(NSUInteger)count width:(NSUInteger)width height:(NSUInteger)height {
    if (previous == nil || current == nil || outputs.count == 0 || tValues == nullptr || self.rifeSP4Runner == nullptr) {
        return NO;
    }

    const double requestedHeight = SMCappedSP4RealtimeHeight(self.flowHeight > 0 ? static_cast<double>(self.flowHeight) : 360.0,
                                                            self.gpuBudgetMs,
                                                            self.targetFPS);
    const NSUInteger sourceCapped = static_cast<NSUInteger>(MIN(static_cast<double>(height), requestedHeight));
    const NSUInteger modelHeight = MAX(static_cast<NSUInteger>(128), static_cast<NSUInteger>(SMAlign16(sourceCapped)));
    const NSUInteger modelWidth = SMRIFEWidthForHeight(width, height, static_cast<uint32_t>(modelHeight));
    if (!self.rifeSP4Runner->IsReady() || self.rifeModelWidth != modelWidth || self.rifeModelHeight != modelHeight) {
        self.rifeSP4Runner->SetCommandQueue((__bridge void*)self.commandQueue);
        if (!self.rifeSP4Runner->Load(SMRIFEModelPath().string(), static_cast<uint32_t>(modelWidth), static_cast<uint32_t>(modelHeight))) {
            self.graphSummary = [NSString stringWithFormat:@"SP4 A1P unavailable: %s · fallback", self.rifeSP4Runner->Diagnostics().c_str()];
            return NO;
        }
        self.rifeModelWidth = modelWidth;
        self.rifeModelHeight = modelHeight;
    }

    const NSUInteger outputCount = MIN(count, outputs.count);
    std::vector<void*> outputPointers;
    outputPointers.reserve(outputCount);
    for (NSUInteger i = 0; i < outputCount; ++i) {
        id texture = outputs[i];
        if (![texture conformsToProtocol:@protocol(MTLTexture)]) {
            return NO;
        }
        outputPointers.push_back((__bridge void*)texture);
    }
    const Stellaria::Motion::RIFESP4RunResult result =
        self.rifeSP4Runner->RunTexturesAtTValues((__bridge void*)previous,
                                                 (__bridge void*)current,
                                                 outputPointers.data(),
                                                 tValues,
                                                 static_cast<uint32_t>(outputPointers.size()),
                                                 static_cast<uint32_t>(width),
                                                 static_cast<uint32_t>(height));
    if (!result.ok) {
        self.graphSummary = [NSString stringWithFormat:@"SP4 A1P batch failed: %s · fallback", result.message.c_str()];
        return NO;
    }
    self.rifeFrames += outputPointers.size();
    self.lastGpuMs = result.elapsedMs;
    self.graphSummary = [NSString stringWithFormat:@"Stellaria SP4 SDK batch x%lu · %ux%u model · %.2fms / %.2fms",
                                                   static_cast<unsigned long>(outputPointers.size()),
                                                   result.modelWidth,
                                                   result.modelHeight,
                                                   result.elapsedMs,
                                                   1000.0 / MAX(1.0, self.targetFPS)];
    return YES;
}

- (BOOL)processTexturesWithRIFEPrevious:(id<MTLTexture>)previous current:(id<MTLTexture>)current output:(id<MTLTexture>)output width:(NSUInteger)width height:(NSUInteger)height {
    if (previous == nil || current == nil || output == nil || self.rifeRunner == nullptr || self.rifePackPipeline == nil || self.rifeUnpackPipeline == nil) {
        return NO;
    }
    const NSUInteger modelHeight = SMCappedRIFEHeight(height, self.flowHeight, self.gpuBudgetMs);
    const NSUInteger modelWidth = SMRIFEWidthForHeight(width, height, static_cast<uint32_t>(modelHeight));
    const NSUInteger inputBytes = modelWidth * modelHeight * 6 * sizeof(float);
    const NSUInteger outputBytes = modelWidth * modelHeight * 3 * sizeof(float);
    if (self.rifeInputBuffer == nil || self.rifeInputBuffer.length < inputBytes) {
        self.rifeInputBuffer = [self.device newBufferWithLength:inputBytes options:MTLResourceStorageModeShared];
    }
    if (self.rifeOutputBuffer == nil || self.rifeOutputBuffer.length < outputBytes) {
        self.rifeOutputBuffer = [self.device newBufferWithLength:outputBytes options:MTLResourceStorageModeShared];
    }
    if (self.rifeInputBuffer == nil || self.rifeOutputBuffer == nil) {
        return NO;
    }
    if (!self.rifeRunner->IsReady() || self.rifeModelWidth != modelWidth || self.rifeModelHeight != modelHeight) {
        if (!self.rifeRunner->Load(SMRIFEModelPath().string(), static_cast<uint32_t>(modelWidth), static_cast<uint32_t>(modelHeight))) {
            self.graphSummary = [NSString stringWithFormat:@"RIFE unavailable: %s · fallback fused", self.rifeRunner->Diagnostics().c_str()];
            return NO;
        }
        self.rifeModelWidth = modelWidth;
        self.rifeModelHeight = modelHeight;
    }

    SMRIFETextureParams params{
        .width = static_cast<uint32_t>(width),
        .height = static_cast<uint32_t>(height),
        .modelWidth = static_cast<uint32_t>(modelWidth),
        .modelHeight = static_cast<uint32_t>(modelHeight),
    };

    id<MTLCommandBuffer> packCommand = [self.commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> pack = [packCommand computeCommandEncoder];
    [pack setComputePipelineState:self.rifePackPipeline];
    [pack setTexture:previous atIndex:0];
    [pack setTexture:current atIndex:1];
    [pack setBuffer:self.rifeInputBuffer offset:0 atIndex:0];
    [pack setBytes:&params length:sizeof(params) atIndex:1];
    const NSUInteger packWide = self.rifePackPipeline.threadExecutionWidth;
    const NSUInteger packHigh = MAX(1, self.rifePackPipeline.maxTotalThreadsPerThreadgroup / packWide);
    [pack dispatchThreads:MTLSizeMake(modelWidth, modelHeight, 1)
    threadsPerThreadgroup:MTLSizeMake(packWide, packHigh, 1)];
    [pack endEncoding];
    [packCommand commit];
    [packCommand waitUntilCompleted];
    if (packCommand.status != MTLCommandBufferStatusCompleted) {
        return NO;
    }

    Stellaria::Motion::RIFEMPSGraphRunResult result =
        self.rifeRunner->RunWithBuffers((__bridge void*)self.rifeInputBuffer, (__bridge void*)self.rifeOutputBuffer);
    if (!result.ok) {
        self.graphSummary = [NSString stringWithFormat:@"RIFE inference failed: %s · fallback fused", result.message.c_str()];
        return NO;
    }

    id<MTLCommandBuffer> unpackCommand = [self.commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> unpack = [unpackCommand computeCommandEncoder];
    [unpack setComputePipelineState:self.rifeUnpackPipeline];
    [unpack setBuffer:self.rifeOutputBuffer offset:0 atIndex:0];
    [unpack setTexture:previous atIndex:0];
    [unpack setTexture:current atIndex:1];
    [unpack setTexture:output atIndex:2];
    [unpack setBytes:&params length:sizeof(params) atIndex:1];
    const NSUInteger unpackWide = self.rifeUnpackPipeline.threadExecutionWidth;
    const NSUInteger unpackHigh = MAX(1, self.rifeUnpackPipeline.maxTotalThreadsPerThreadgroup / unpackWide);
    [unpack dispatchThreads:MTLSizeMake(width, height, 1)
      threadsPerThreadgroup:MTLSizeMake(unpackWide, unpackHigh, 1)];
    [unpack endEncoding];
    [unpackCommand commit];
    [unpackCommand waitUntilCompleted];
    if (unpackCommand.status != MTLCommandBufferStatusCompleted) {
        return NO;
    }
    self.rifeFrames += 1;
    self.lastGpuMs = result.elapsedMs;
    self.graphSummary = [NSString stringWithFormat:@"RIFE Student · %lux%lu model · %.1fms budget",
                                                   static_cast<unsigned long>(modelWidth),
                                                   static_cast<unsigned long>(modelHeight),
                                                   self.gpuBudgetMs > 0.0 ? self.gpuBudgetMs : 14.0];
    return YES;
}

- (void)generateIntermediateFromPrevious:(CVPixelBufferRef)previous current:(CVPixelBufferRef)current currentPTS:(CMTime)currentPTS t:(float)t {
    id<MTLTexture> previousTexture = nil;
    id<MTLTexture> currentTexture = nil;
    CVMetalTextureRef previousRef = nullptr;
    CVMetalTextureRef currentRef = nullptr;
    if (!SMCreateTexture(self.textureCache, previous, MTLPixelFormatBGRA8Unorm, &previousTexture, &previousRef) ||
        !SMCreateTexture(self.textureCache, current, MTLPixelFormatBGRA8Unorm, &currentTexture, &currentRef)) {
        if (previousRef != nullptr) {
            CFRelease(previousRef);
        }
        if (currentRef != nullptr) {
            CFRelease(currentRef);
        }
        self.droppedFrames += 1;
        return;
    }

    const NSUInteger width = CVPixelBufferGetWidth(current);
    const NSUInteger height = CVPixelBufferGetHeight(current);
    double sourceDuration = 1.0 / MAX(24.0, self.targetFPS / MAX(1.0, self.frameMultiple));
    if (CMTIME_IS_VALID(self.previousPTS) && CMTIME_IS_VALID(currentPTS)) {
        const double ptsDuration = CMTimeGetSeconds(CMTimeSubtract(currentPTS, self.previousPTS));
        if (std::isfinite(ptsDuration) && ptsDuration > 0.004 && ptsDuration < 0.25) {
            sourceDuration = ptsDuration;
        }
    }
    const double outputSlotsForPair = self.targetFPS * sourceDuration;
    const BOOL wantsHighMultiT = outputSlotsForPair >= 3.25 && self.interpolatePipeline != nil;
    NSUInteger sequenceSubframes = 1;
    if (wantsHighMultiT) {
        sequenceSubframes = static_cast<NSUInteger>(MIN(4.0, MAX(1.0, round(outputSlotsForPair) - 1.0)));
    } else if (outputSlotsForPair > 2.15 && self.interpolatePipeline != nil) {
        sequenceSubframes = 2;
    }
    const BOOL wantsLateSubframe = sequenceSubframes >= 2;
    const BOOL cadence24To60 = wantsLateSubframe && fabs(outputSlotsForPair - 2.5) < 0.18;
    const uint64_t pairIndex = self.sequencePairIndex++;
    const BOOL cadencePairShowsNext = wantsHighMultiT || !cadence24To60 || ((pairIndex & 1ULL) != 0ULL);
    std::vector<float> sequenceTValues;
    sequenceTValues.reserve(sequenceSubframes);
    if (wantsLateSubframe && cadence24To60 && !wantsHighMultiT) {
        sequenceTValues.push_back(cadencePairShowsNext ? 0.20f : 0.40f);
        sequenceTValues.push_back(cadencePairShowsNext ? 0.60f : 0.80f);
    } else {
        for (NSUInteger i = 0; i < sequenceSubframes; ++i) {
            sequenceTValues.push_back(static_cast<float>(static_cast<double>(i + 1) /
                                                         static_cast<double>(sequenceSubframes + 1)));
        }
    }
    const float primaryT = sequenceTValues.empty() ? t : sequenceTValues[0];
    const float lateT = sequenceTValues.size() >= 2 ? sequenceTValues[1] : primaryT;

    const BOOL replacingActiveSequence = self.sequenceReady;
    self.outputTexture = [self ensureDisplayTexture:self.outputTexture width:width height:height];
    NSMutableArray* subframeTextures = [NSMutableArray arrayWithCapacity:sequenceSubframes];
    for (NSUInteger i = 0; i < sequenceSubframes; ++i) {
        id<MTLTexture> reusable = nil;
        if (!replacingActiveSequence) {
            reusable = i == 0 ? self.displayMidTexture : (i == 1 ? self.displayLateTexture : nil);
        }
        id<MTLTexture> subframeTexture = [self ensureDisplayTexture:reusable width:width height:height];
        if (subframeTexture != nil) {
            [subframeTextures addObject:subframeTexture];
        }
    }
    id<MTLTexture> midTexture = subframeTextures.count >= 1 ? subframeTextures[0] : nil;
    id<MTLTexture> lateTexture = subframeTextures.count >= 2 ? subframeTextures[1] : nil;
    id<MTLTexture> nextTexture = [self ensureDisplayTexture:(replacingActiveSequence ? nil : self.displayNextTexture) width:width height:height];
    if (!replacingActiveSequence) {
        self.displayMidTexture = midTexture;
        self.displayLateTexture = lateTexture;
        self.displaySubframeTextures = subframeTextures.copy;
        self.displayNextTexture = nextTexture;
    }
    if (self.outputTexture == nil || midTexture == nil || nextTexture == nil ||
        subframeTextures.count < sequenceSubframes) {
        self.droppedFrames += 1;
        CFRelease(previousRef);
        CFRelease(currentRef);
        return;
    }

    SMBGRAInterpolateParams params{
        .outWidth = static_cast<uint32_t>(width),
        .outHeight = static_cast<uint32_t>(height),
        .inverseUpscale = simd_make_float2(1.0f, 1.0f),
        .t = primaryT,
    };

    const CFTimeInterval start = CACurrentMediaTime();
    NSString* lowerModelMode = [self.modelMode lowercaseString];
    const BOOL wantsRIFE = ![lowerModelMode isEqualToString:@"fused"] && ![lowerModelMode containsString:@"fused_basic"];
    const BOOL wantsSP4 = [lowerModelMode containsString:@"sp4"];
    const BOOL wantsMetal4 = [lowerModelMode containsString:@"metal"] || [lowerModelMode containsString:@"int4"];
    BOOL madeRIFE = NO;
    BOOL madeLateRIFE = NO;
    if (wantsRIFE) {
        if (wantsSP4) {
            madeRIFE = [self processTexturesWithRIFESP4Previous:previousTexture
                                                        current:currentTexture
                                                        outputs:subframeTextures
                                                        tValues:sequenceTValues.data()
                                                          count:sequenceTValues.size()
                                                          width:width
                                                         height:height];
            madeLateRIFE = madeRIFE;
        } else {
            madeRIFE = wantsSP4
            ? [self processTexturesWithRIFESP4Previous:previousTexture current:currentTexture output:midTexture width:width height:height t:primaryT]
            : (wantsMetal4
            ? [self processTexturesWithRIFEMetal4Previous:previousTexture current:currentTexture output:midTexture width:width height:height t:primaryT]
            : [self processTexturesWithRIFEPrevious:previousTexture current:currentTexture output:midTexture width:width height:height]);
        }
        if (!madeRIFE && wantsSP4) {
            madeRIFE = [self processTexturesWithRIFEMetal4Previous:previousTexture current:currentTexture output:midTexture width:width height:height t:primaryT];
        }
        if (!madeRIFE && (wantsMetal4 || wantsSP4)) {
            madeRIFE = [self processTexturesWithRIFEPrevious:previousTexture current:currentTexture output:midTexture width:width height:height];
        }
        if (madeRIFE && wantsLateSubframe && wantsMetal4) {
            madeLateRIFE = [self processTexturesWithRIFEMetal4Previous:previousTexture current:currentTexture output:lateTexture width:width height:height t:lateT];
        }
        if (madeRIFE && wantsLateSubframe && !madeLateRIFE && wantsSP4) {
                madeLateRIFE = [self processTexturesWithRIFEMetal4Previous:previousTexture current:currentTexture output:lateTexture width:width height:height t:lateT];
        }
    }
    if (madeRIFE) {
        id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
        const NSUInteger readySubframes = wantsLateSubframe && madeLateRIFE ? sequenceSubframes : 1;
        id<MTLTexture> baseTexture = replacingActiveSequence ? self.outputTexture : nil;
        if (replacingActiveSequence && !SMCopyTexture(commandBuffer, previousTexture, baseTexture)) {
            CFRelease(previousRef);
            CFRelease(currentRef);
            self.droppedFrames += 1;
            return;
        }
        if (!SMCopyTexture(commandBuffer, currentTexture, nextTexture)) {
            CFRelease(previousRef);
            CFRelease(currentRef);
            self.droppedFrames += 1;
            return;
        }

        SMMotionOnlineProcessor* __weak weakSelf = self;
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            SMMotionOnlineProcessor* __strong self = weakSelf;
            if (self != nil) {
                self.lastGpuMs = (CACurrentMediaTime() - start) * 1000.0;
                if (completed.status == MTLCommandBufferStatusCompleted) {
                    self.generatedFrames += readySubframes;
                    dispatch_queue_t queue = self.displayQueue;
                    void (^markReady)(void) = ^{
                        if (baseTexture != nil) {
                            self.displayCurrentTexture = baseTexture;
                        }
                        self.displayMidTexture = midTexture;
                        self.displayLateTexture = readySubframes >= 2 ? lateTexture : nil;
                        self.displaySubframeTextures = subframeTextures.copy;
                        self.displayNextTexture = nextTexture;
                        self.sequenceDuration = sourceDuration;
                        self.sequenceSubframeCount = readySubframes;
                        self.sequenceShowsNextFrame = readySubframes >= 2 ? cadencePairShowsNext : YES;
                        self.sequenceStartTime = CACurrentMediaTime();
                        self.sequenceReady = YES;
                    };
                    if (queue != nil) {
                        dispatch_async(queue, markReady);
                    } else {
                        markReady();
                    }
                } else {
                    self.droppedFrames += 1;
                }
            }
            CFRelease(previousRef);
            CFRelease(currentRef);
        }];
        [commandBuffer commit];
        return;
    }

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    const NSUInteger threadsWide = self.interpolatePipeline.threadExecutionWidth;
    const NSUInteger threadsHigh = MAX(1, self.interpolatePipeline.maxTotalThreadsPerThreadgroup / threadsWide);
    for (NSUInteger i = 0; i < subframeTextures.count; ++i) {
        id texture = subframeTextures[i];
        if (![texture conformsToProtocol:@protocol(MTLTexture)]) {
            continue;
        }
        SMBGRAInterpolateParams subframeParams = params;
        subframeParams.t = i < sequenceTValues.size() ? sequenceTValues[i] : primaryT;
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
        [encoder setComputePipelineState:self.interpolatePipeline];
        [encoder setTexture:previousTexture atIndex:0];
        [encoder setTexture:currentTexture atIndex:1];
        [encoder setTexture:(id<MTLTexture>)texture atIndex:2];
        [encoder setBytes:&subframeParams length:sizeof(subframeParams) atIndex:0];
        [encoder dispatchThreads:MTLSizeMake(width, height, 1)
           threadsPerThreadgroup:MTLSizeMake(threadsWide, threadsHigh, 1)];
        [encoder endEncoding];
    }

    if (!SMCopyTexture(commandBuffer, currentTexture, nextTexture)) {
        CFRelease(previousRef);
        CFRelease(currentRef);
        self.droppedFrames += 1;
        return;
    }
    id<MTLTexture> baseTexture = replacingActiveSequence ? self.outputTexture : nil;
    if (replacingActiveSequence && !SMCopyTexture(commandBuffer, previousTexture, baseTexture)) {
        CFRelease(previousRef);
        CFRelease(currentRef);
        self.droppedFrames += 1;
        return;
    }

    SMMotionOnlineProcessor* __weak weakSelf = self;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        SMMotionOnlineProcessor* __strong self = weakSelf;
        if (self != nil) {
            self.lastGpuMs = (CACurrentMediaTime() - start) * 1000.0;
            if (completed.status == MTLCommandBufferStatusCompleted) {
                self.generatedFrames += sequenceSubframes;
                dispatch_queue_t queue = self.displayQueue;
                void (^markReady)(void) = ^{
                    if (baseTexture != nil) {
                        self.displayCurrentTexture = baseTexture;
                    }
                    self.displayMidTexture = midTexture;
                    self.displayLateTexture = sequenceSubframes >= 2 ? lateTexture : nil;
                    self.displaySubframeTextures = subframeTextures.copy;
                    self.displayNextTexture = nextTexture;
                    self.sequenceDuration = sourceDuration;
                    self.sequenceSubframeCount = sequenceSubframes;
                    self.sequenceShowsNextFrame = sequenceSubframes >= 2 ? cadencePairShowsNext : YES;
                    self.sequenceStartTime = CACurrentMediaTime();
                    self.sequenceReady = YES;
                };
                if (queue != nil) {
                    dispatch_async(queue, markReady);
                } else {
                    markReady();
                }
            } else {
                self.droppedFrames += 1;
            }
        }
        CFRelease(previousRef);
        CFRelease(currentRef);
    }];
    [commandBuffer commit];
}

- (void)rebuildGraphSummaryForWidth:(uint32_t)width height:(uint32_t)height {
    RenderGraph graph;
    RIFEModelBackend modelBackend(SMRIFEModelPath());
    MotionVFIPipeline pipeline(&modelBackend);
    VFIJob job;
    job.f0.width = width;
    job.f0.height = height;
    job.f1.width = width;
    job.f1.height = height;
    job.profile = ContentProfile::Anime;
    job.quality = height >= 2160 ? QualityMode::Q2_720Flow : QualityMode::Q3_1080Flow;

    MotionQualitySettings settings;
    settings.targetFps = self.targetFPS;
    settings.frameMultiplier = self.frameMultiple;
    settings.flowInputHeight = self.flowHeight;
    settings.edgeAwareFlowUpscale = true;
    settings.lineArtProtect = true;
    settings.subtitleProtect = true;
    settings.refineEnabled = true;

    VFIPipelineDiagnostics diagnostics = pipeline.BuildGraph(graph, job, settings);
    const bool ready = graph.Compile();
    NSString* modelState = [NSString stringWithFormat:@"%s %s",
                             diagnostics.modelBackendReady ? "RIFE ready" : "RIFE unavailable",
                             diagnostics.modelBackendDiagnostics.c_str()];
    self.graphSummary = [NSString stringWithFormat:@"SCK -> IOSurface -> RenderGraph(%lu pass %@) -> %@ -> fused online present",
                         static_cast<unsigned long>(diagnostics.passNames.size()),
                         ready ? @"ready" : @"blocked",
                         modelState];
}

- (void)reportCaptureStatusWithBuffer:(CVPixelBufferRef)buffer now:(CFTimeInterval)now {
    const double elapsed = MAX(0.001, now - self.startTime);
    const double inputFPS = static_cast<double>(self.inputFrames) / elapsed;
    const double generatedFPS = static_cast<double>(self.generatedFrames) / elapsed;
    const BOOL localPlayback = self.localVideoOutput != nil;
    [self emit:@{
        @"state": localPlayback ? @"local_playback" : @"capturing",
        @"message": localPlayback ? @"本地视频实时增强中" : @"在线插帧捕获中",
        @"inputFrames": @(self.inputFrames),
        @"generatedFrames": @(self.generatedFrames),
        @"enhancedActive": @(self.generatedFrames > 0),
        @"rifeFrames": @(self.rifeFrames),
        @"droppedFrames": @(self.droppedFrames),
        @"repeatedFrames": @(self.repeatedFrames),
        @"inputFPS": @(inputFPS),
        @"generatedFPS": @(generatedFPS),
        @"gpuMs": @(self.lastGpuMs),
        @"width": @(CVPixelBufferGetWidth(buffer)),
        @"height": @(CVPixelBufferGetHeight(buffer)),
        @"queueDepth": localPlayback ? @2 : @3,
        @"settings": self.settingsSummary ?: @"",
        @"pipeline": self.graphSummary ?: @"SCK -> Metal fused VFI"
    }];
}

- (void)emit:(NSDictionary<NSString*, id>*)status {
    SMMotionOnlineProgressHandler handler = self.progress;
    if (handler == nil) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(status);
    });
}

@end
