#include "VFI/RIFEMetal4BitRunner.h"
#include "VFI/RIFESP4Runner.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <numeric>
#include <string>
#include <vector>

namespace {

struct Options {
    std::filesystem::path videoPath;
    std::string backend = "sp4";
    int framePairs = 60;
    uint32_t modelHeight = 360;
    bool samplePower = false;
    bool fullVideo = false;
    bool multiT = false;
    double targetFPS = 60.0;
};

struct Metrics {
    int sourceFrames = 0;
    int presentedFrames = 0;
    int generated = 0;
    int failed = 0;
    double elapsedTotalMs = 0.0;
    std::vector<double> gpuMs;
    double madPrev = 0.0;
    double madCurr = 0.0;
    double madLinear = 0.0;
    double madSource = 0.0;
};

std::filesystem::path ExistingPath(std::initializer_list<std::filesystem::path> candidates) {
    for (const std::filesystem::path& path : candidates) {
        if (std::filesystem::exists(path)) {
            return path;
        }
    }
    return {};
}

std::filesystem::path DefaultVideoPath() {
    return ExistingPath({
        std::filesystem::current_path() / "Tests/Media/test.mov",
        std::filesystem::current_path().parent_path() / "Tests/Media/test.mov",
        std::filesystem::current_path() / "tools/test_video.mp4",
        std::filesystem::current_path().parent_path() / "tools/test_video.mp4",
    });
}

std::filesystem::path ModelPath() {
    return ExistingPath({
        std::filesystem::current_path() / "Models/RIFE-safetensors/flownet.safetensors",
        std::filesystem::current_path().parent_path() / "Models/RIFE-safetensors/flownet.safetensors",
    });
}

uint32_t Align16(uint32_t value) {
    return (value + 15U) & ~15U;
}

uint32_t WidthForHeight(uint32_t sourceWidth, uint32_t sourceHeight, uint32_t modelHeight) {
    if (sourceWidth == 0 || sourceHeight == 0 || modelHeight == 0) {
        return 16;
    }
    const double width = static_cast<double>(modelHeight) * static_cast<double>(sourceWidth) / static_cast<double>(sourceHeight);
    return Align16(static_cast<uint32_t>(std::max(16.0, static_cast<double>(std::llround(width)))));
}

void PrintUsage(const char* argv0) {
    std::cout << "Usage: " << argv0
              << " [--video path] [--backend sp4|int4] [--frames N|--full-video] [--model-height H] [--multi-t] [--target-fps FPS] [--sample-power]\n";
}

Options ParseOptions(int argc, const char* argv[]) {
    Options options;
    options.videoPath = DefaultVideoPath();
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--help" || arg == "-h") {
            PrintUsage(argv[0]);
            std::exit(0);
        } else if (arg == "--video" && i + 1 < argc) {
            options.videoPath = argv[++i];
        } else if (arg == "--backend" && i + 1 < argc) {
            options.backend = argv[++i];
        } else if (arg == "--frames" && i + 1 < argc) {
            options.framePairs = std::atoi(argv[++i]);
            if (options.framePairs <= 0) {
                options.fullVideo = true;
                options.framePairs = 0;
            }
        } else if (arg == "--model-height" && i + 1 < argc) {
            options.modelHeight = Align16(static_cast<uint32_t>(std::max(128, std::atoi(argv[++i]))));
        } else if (arg == "--sample-power") {
            options.samplePower = true;
        } else if (arg == "--full-video") {
            options.fullVideo = true;
        } else if (arg == "--multi-t") {
            options.multiT = true;
        } else if (arg == "--target-fps" && i + 1 < argc) {
            options.targetFPS = std::max(24.0, std::atof(argv[++i]));
        } else {
            std::cerr << "Unknown argument: " << arg << "\n";
            PrintUsage(argv[0]);
            std::exit(2);
        }
    }
    return options;
}

bool CreateTexture(CVMetalTextureCacheRef cache,
                   CVPixelBufferRef buffer,
                   id<MTLTexture>* textureOut,
                   CVMetalTextureRef* textureRefOut) {
    if (cache == nullptr || buffer == nullptr || textureOut == nullptr || textureRefOut == nullptr) {
        return false;
    }
    CVMetalTextureRef ref = nullptr;
    const size_t width = CVPixelBufferGetWidth(buffer);
    const size_t height = CVPixelBufferGetHeight(buffer);
    const CVReturn status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                      cache,
                                                                      buffer,
                                                                      nullptr,
                                                                      MTLPixelFormatBGRA8Unorm,
                                                                      width,
                                                                      height,
                                                                      0,
                                                                      &ref);
    if (status != kCVReturnSuccess || ref == nullptr) {
        return false;
    }
    id<MTLTexture> texture = CVMetalTextureGetTexture(ref);
    if (texture == nil) {
        CFRelease(ref);
        return false;
    }
    *textureOut = texture;
    *textureRefOut = ref;
    return true;
}

id<MTLTexture> MakeOutputTexture(id<MTLDevice> device, NSUInteger width, NSUInteger height) {
    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:width
                                                                                         height:height
                                                                                      mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    descriptor.storageMode = MTLStorageModeShared;
    return [device newTextureWithDescriptor:descriptor];
}

std::vector<uint8_t> ReadTextureBytes(id<MTLTexture> texture) {
    std::vector<uint8_t> bytes(texture.width * texture.height * 4);
    [texture getBytes:bytes.data()
          bytesPerRow:texture.width * 4
           fromRegion:MTLRegionMake2D(0, 0, texture.width, texture.height)
          mipmapLevel:0];
    return bytes;
}

std::vector<uint8_t> ReadPixelBufferBytes(CVPixelBufferRef buffer) {
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    const uint8_t* base = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(buffer));
    const size_t width = CVPixelBufferGetWidth(buffer);
    const size_t height = CVPixelBufferGetHeight(buffer);
    const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    std::vector<uint8_t> bytes(width * height * 4);
    for (size_t y = 0; y < height; ++y) {
        std::memcpy(bytes.data() + y * width * 4, base + y * stride, width * 4);
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return bytes;
}

double MeanAbsDiff(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b) {
    if (a.size() != b.size() || a.empty()) {
        return 0.0;
    }
    uint64_t total = 0;
    size_t count = 0;
    for (size_t i = 0; i + 3 < a.size(); i += 4) {
        total += static_cast<uint64_t>(std::abs(int(a[i + 0]) - int(b[i + 0])));
        total += static_cast<uint64_t>(std::abs(int(a[i + 1]) - int(b[i + 1])));
        total += static_cast<uint64_t>(std::abs(int(a[i + 2]) - int(b[i + 2])));
        count += 3;
    }
    return count > 0 ? static_cast<double>(total) / static_cast<double>(count) : 0.0;
}

double MeanAbsDiffFromLinear(const std::vector<uint8_t>& prev,
                             const std::vector<uint8_t>& curr,
                             const std::vector<uint8_t>& out) {
    if (prev.size() != curr.size() || prev.size() != out.size() || out.empty()) {
        return 0.0;
    }
    uint64_t total = 0;
    size_t count = 0;
    for (size_t i = 0; i + 3 < out.size(); i += 4) {
        for (size_t c = 0; c < 3; ++c) {
            const int linear = (int(prev[i + c]) + int(curr[i + c])) / 2;
            total += static_cast<uint64_t>(std::abs(linear - int(out[i + c])));
            ++count;
        }
    }
    return count > 0 ? static_cast<double>(total) / static_cast<double>(count) : 0.0;
}

NSTask* StartPowerSampler(bool enabled, NSMutableData** outputData) {
    if (!enabled || outputData == nullptr) {
        return nil;
    }
    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/powermetrics"];
    task.arguments = @[@"--samplers", @"gpu_power,cpu_power", @"-i", @"500", @"-n", @"20"];
    NSPipe* pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    NSMutableData* data = [NSMutableData data];
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle* handle) {
        NSData* chunk = [handle availableData];
        if (chunk.length > 0) {
            @synchronized(data) {
                [data appendData:chunk];
            }
        }
    };
    NSError* error = nil;
    if (![task launchAndReturnError:&error]) {
        std::cerr << "powermetrics unavailable: " << (error.localizedDescription.UTF8String ?: "launch failed") << "\n";
        return nil;
    }
    *outputData = data;
    return task;
}

void StopPowerSampler(NSTask* task) {
    if (task == nil) {
        return;
    }
    if (task.isRunning) {
        [task terminate];
    }
    [task waitUntilExit];
}

void PrintPowerSummary(NSMutableData* data) {
    if (data.length == 0) {
        std::cout << "power: unavailable (powermetrics usually requires sudo/root)\n";
        return;
    }
    NSString* text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text.length == 0 || [text localizedCaseInsensitiveContainsString:@"operation not permitted"] ||
        [text localizedCaseInsensitiveContainsString:@"must be run as root"]) {
        std::cout << "power: unavailable (rerun with sudo and --sample-power for powermetrics)\n";
        return;
    }
    __block double gpuTotal = 0.0;
    __block double cpuTotal = 0.0;
    __block NSUInteger gpuCount = 0;
    __block NSUInteger cpuCount = 0;
    NSRegularExpression* regex = [NSRegularExpression regularExpressionWithPattern:@"(GPU|CPU) Power:\\s+([0-9.]+)\\s+mW"
                                                                           options:NSRegularExpressionCaseInsensitive
                                                                             error:nil];
    [regex enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length) usingBlock:^(NSTextCheckingResult* result, NSMatchingFlags, BOOL*) {
        if (result.numberOfRanges < 3) {
            return;
        }
        NSString* kind = [text substringWithRange:[result rangeAtIndex:1]];
        double valueW = [[text substringWithRange:[result rangeAtIndex:2]] doubleValue] / 1000.0;
        if ([kind localizedCaseInsensitiveContainsString:@"GPU"]) {
            gpuTotal += valueW;
            gpuCount += 1;
        } else {
            cpuTotal += valueW;
            cpuCount += 1;
        }
    }];
    if (gpuCount == 0 && cpuCount == 0) {
        std::cout << "power: powermetrics ran, but no GPU/CPU power samples were parsed\n";
        return;
    }
    std::cout << "power:";
    if (gpuCount > 0) {
        std::cout << " gpu_avg=" << (gpuTotal / static_cast<double>(gpuCount)) << "W";
    }
    if (cpuCount > 0) {
        std::cout << " cpu_avg=" << (cpuTotal / static_cast<double>(cpuCount)) << "W";
    }
    std::cout << "\n";
}

} // namespace

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        Options options = ParseOptions(argc, argv);
        if (options.videoPath.empty() || !std::filesystem::exists(options.videoPath)) {
            std::cerr << "Video file missing. Pass --video /path/to/file.mov\n";
            return 2;
        }
        if (options.backend != "sp4" && options.backend != "int4") {
            std::cerr << "Unsupported backend. Use --backend sp4 or --backend int4\n";
            return 2;
        }
        const std::filesystem::path modelPath = ModelPath();
        if (modelPath.empty()) {
            std::cerr << "RIFE model missing under Models/RIFE-safetensors/flownet.safetensors\n";
            return 2;
        }

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = device != nil ? [device newCommandQueue] : nil;
        if (device == nil || queue == nil) {
            std::cerr << "Metal device/queue unavailable\n";
            return 2;
        }

        NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:options.videoPath.string().c_str()]];
        AVURLAsset* asset = [AVURLAsset URLAssetWithURL:url options:nil];
        NSError* readerError = nil;
        AVAssetReader* reader = [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
        if (reader == nil) {
            std::cerr << "AVAssetReader failed: " << (readerError.localizedDescription.UTF8String ?: "unknown") << "\n";
            return 2;
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        AVAssetTrack* track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
#pragma clang diagnostic pop
        if (track == nil) {
            std::cerr << "Video track missing\n";
            return 2;
        }
        const CMTime durationTime = asset.duration;
        const double durationSec = CMTIME_IS_NUMERIC(durationTime) ? CMTimeGetSeconds(durationTime) : 0.0;
        const double nominalSourceFps = track.nominalFrameRate > 0.0f ? static_cast<double>(track.nominalFrameRate) : 0.0;
        NSDictionary* outputSettings = @{
            (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (NSString*)kCVPixelBufferMetalCompatibilityKey: @YES,
            (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        AVAssetReaderTrackOutput* trackOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:outputSettings];
        trackOutput.alwaysCopiesSampleData = NO;
        if (![reader canAddOutput:trackOutput]) {
            std::cerr << "Reader cannot add BGRA track output\n";
            return 2;
        }
        [reader addOutput:trackOutput];
        if (![reader startReading]) {
            std::cerr << "Reader start failed: " << (reader.error.localizedDescription.UTF8String ?: "unknown") << "\n";
            return 2;
        }

        CVMetalTextureCacheRef cache = nullptr;
        if (CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, device, nullptr, &cache) != kCVReturnSuccess || cache == nullptr) {
            std::cerr << "CVMetalTextureCacheCreate failed\n";
            return 2;
        }

        NSMutableData* powerData = nil;
        NSTask* powerTask = StartPowerSampler(options.samplePower, &powerData);

        Metrics metrics;
        CMSampleBufferRef previousSample = nullptr;
        CVPixelBufferRef previousBuffer = nullptr;
        const CFTimeInterval start = CACurrentMediaTime();
        uint32_t modelWidth = 0;
        uint32_t modelHeight = options.modelHeight;
        uint64_t multiTPairIndex = 0;

        std::unique_ptr<Stellaria::Motion::RIFESP4Runner> sp4Runner;
        std::unique_ptr<Stellaria::Motion::RIFEMetal4BitRunner> int4Runner;

        while (options.fullVideo || metrics.generated + metrics.failed < options.framePairs) {
            CMSampleBufferRef sample = [trackOutput copyNextSampleBuffer];
            if (sample == nullptr) {
                break;
            }
            CVPixelBufferRef currentBuffer = CMSampleBufferGetImageBuffer(sample);
            if (currentBuffer == nullptr) {
                CFRelease(sample);
                continue;
            }
            metrics.sourceFrames += 1;
            if (previousBuffer == nullptr) {
                previousSample = sample;
                previousBuffer = CVPixelBufferRetain(currentBuffer);
                metrics.presentedFrames = std::max(metrics.presentedFrames, 1);
                continue;
            }

            const uint32_t width = static_cast<uint32_t>(CVPixelBufferGetWidth(currentBuffer));
            const uint32_t height = static_cast<uint32_t>(CVPixelBufferGetHeight(currentBuffer));
            modelWidth = WidthForHeight(width, height, modelHeight);

            id<MTLTexture> previousTexture = nil;
            id<MTLTexture> currentTexture = nil;
            CVMetalTextureRef previousRef = nullptr;
            CVMetalTextureRef currentRef = nullptr;
            const bool textureReady =
                CreateTexture(cache, previousBuffer, &previousTexture, &previousRef) &&
                CreateTexture(cache, currentBuffer, &currentTexture, &currentRef);
            id<MTLTexture> outputTexture = textureReady ? MakeOutputTexture(device, width, height) : nil;
            bool ok = false;
            double elapsedMs = 0.0;
            int generatedThisPair = 1;
            double pairDurationSec = 0.0;
            const CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
            if (previousSample != nullptr && CMTIME_IS_NUMERIC(pts)) {
                const CMTime previousPTS = CMSampleBufferGetPresentationTimeStamp(previousSample);
                if (CMTIME_IS_NUMERIC(previousPTS)) {
                    pairDurationSec = CMTimeGetSeconds(CMTimeSubtract(pts, previousPTS));
                }
            }
            if (!std::isfinite(pairDurationSec) || pairDurationSec <= 0.004 || pairDurationSec > 0.25) {
                pairDurationSec = nominalSourceFps > 1.0 ? 1.0 / nominalSourceFps : 1.0 / 24.0;
            }
            const double outputSlotsForPair = options.targetFPS * pairDurationSec;
            const bool wantsHighMultiT = options.multiT && outputSlotsForPair >= 3.25;
            int requestedSubframes = 1;
            if (wantsHighMultiT) {
                requestedSubframes = static_cast<int>(std::min(4.0, std::max(1.0, std::round(outputSlotsForPair) - 1.0)));
            } else if (options.multiT && outputSlotsForPair > 2.15) {
                requestedSubframes = 2;
            }
            const bool wantsMultiTForPair = requestedSubframes >= 2;
            const bool cadence24To60 = wantsMultiTForPair && !wantsHighMultiT && std::fabs(outputSlotsForPair - 2.5) < 0.18;
            const uint64_t cadencePairIndex = multiTPairIndex++;
            const bool cadencePairShowsNext = wantsHighMultiT || !cadence24To60 || ((cadencePairIndex & 1ULL) != 0ULL);
            std::vector<float> tValues;
            tValues.reserve(static_cast<size_t>(requestedSubframes));
            if (wantsMultiTForPair && cadence24To60) {
                tValues.push_back(cadencePairShowsNext ? 0.2f : 0.4f);
                tValues.push_back(cadencePairShowsNext ? 0.6f : 0.8f);
            } else {
                for (int i = 0; i < requestedSubframes; ++i) {
                    tValues.push_back(static_cast<float>(static_cast<double>(i + 1) /
                                                         static_cast<double>(requestedSubframes + 1)));
                }
            }

            if (textureReady && outputTexture != nil) {
                if (options.backend == "int4") {
                    if (!int4Runner) {
                        int4Runner = std::make_unique<Stellaria::Motion::RIFEMetal4BitRunner>();
                        int4Runner->SetCommandQueue((__bridge void*)queue);
                        if (!int4Runner->Load(modelPath.string(), modelWidth, modelHeight)) {
                            std::cerr << "INT4 load failed: " << int4Runner->Diagnostics() << "\n";
                            break;
                        }
                    }
                    Stellaria::Motion::RIFEMetal4BitRunResult result =
                        wantsMultiTForPair
                        ? int4Runner->RunTexturesAtT((__bridge void*)previousTexture,
                                                     (__bridge void*)currentTexture,
                                                     (__bridge void*)outputTexture,
                                                     width,
                                                     height,
                                                     tValues.empty() ? 0.5f : tValues[0])
                        : int4Runner->RunTextures((__bridge void*)previousTexture,
                                                  (__bridge void*)currentTexture,
                                                  (__bridge void*)outputTexture,
                                                  width,
                                                  height);
                    ok = result.ok;
                    elapsedMs = result.elapsedMs;
                    if (ok && wantsMultiTForPair) {
                        generatedThisPair = 1;
                        for (size_t i = 1; i < tValues.size(); ++i) {
                            id<MTLTexture> lateTexture = MakeOutputTexture(device, width, height);
                            Stellaria::Motion::RIFEMetal4BitRunResult lateResult =
                                int4Runner->RunTexturesAtT((__bridge void*)previousTexture,
                                                           (__bridge void*)currentTexture,
                                                           (__bridge void*)lateTexture,
                                                           width,
                                                           height,
                                                           tValues[i]);
                            ok = lateResult.ok;
                            elapsedMs += lateResult.elapsedMs;
                            if (!ok) {
                                break;
                            }
                            generatedThisPair += 1;
                        }
                    }
                } else {
                    if (!sp4Runner) {
                        sp4Runner = std::make_unique<Stellaria::Motion::RIFESP4Runner>();
                        sp4Runner->SetCommandQueue((__bridge void*)queue);
                        if (!sp4Runner->Load(modelPath.string(), modelWidth, modelHeight)) {
                            std::cerr << "SP4 load failed: " << sp4Runner->Diagnostics() << "\n";
                            break;
                        }
                    }
                    if (wantsMultiTForPair) {
                        std::vector<id<MTLTexture>> outputTextures;
                        std::vector<void*> outputPointers;
                        outputTextures.reserve(tValues.size());
                        outputPointers.reserve(tValues.size());
                        outputTextures.push_back(outputTexture);
                        outputPointers.push_back((__bridge void*)outputTexture);
                        for (size_t i = 1; i < tValues.size(); ++i) {
                            id<MTLTexture> subframeTexture = MakeOutputTexture(device, width, height);
                            outputTextures.push_back(subframeTexture);
                            outputPointers.push_back((__bridge void*)subframeTexture);
                        }
                        Stellaria::Motion::RIFESP4RunResult result =
                            sp4Runner->RunTexturesAtTValues((__bridge void*)previousTexture,
                                                            (__bridge void*)currentTexture,
                                                            outputPointers.data(),
                                                            tValues.data(),
                                                            static_cast<uint32_t>(outputPointers.size()),
                                                            width,
                                                            height);
                        ok = result.ok;
                        elapsedMs = result.elapsedMs;
                        generatedThisPair = ok ? static_cast<int>(outputPointers.size()) : 1;
                    } else {
                        Stellaria::Motion::RIFESP4RunResult result =
                            sp4Runner->RunTextures((__bridge void*)previousTexture,
                                                   (__bridge void*)currentTexture,
                                                   (__bridge void*)outputTexture,
                                                   width,
                                                   height);
                        ok = result.ok;
                        elapsedMs = result.elapsedMs;
                    }
                }
            }

            if (ok) {
                metrics.generated += generatedThisPair;
                metrics.presentedFrames += wantsMultiTForPair
                    ? generatedThisPair + (cadencePairShowsNext ? 1 : 0)
                    : generatedThisPair + 1;
                metrics.gpuMs.push_back(elapsedMs);
                if (metrics.generated <= 6) {
                    const std::vector<uint8_t> prevBytes = ReadPixelBufferBytes(previousBuffer);
                    const std::vector<uint8_t> currBytes = ReadPixelBufferBytes(currentBuffer);
                    const std::vector<uint8_t> outBytes = ReadTextureBytes(outputTexture);
                    metrics.madSource += MeanAbsDiff(prevBytes, currBytes);
                    metrics.madPrev += MeanAbsDiff(prevBytes, outBytes);
                    metrics.madCurr += MeanAbsDiff(currBytes, outBytes);
                    metrics.madLinear += MeanAbsDiffFromLinear(prevBytes, currBytes, outBytes);
                }
            } else {
                metrics.failed += 1;
            }

            if (previousRef != nullptr) {
                CFRelease(previousRef);
            }
            if (currentRef != nullptr) {
                CFRelease(currentRef);
            }
            CVPixelBufferRelease(previousBuffer);
            if (previousSample != nullptr) {
                CFRelease(previousSample);
            }
            previousSample = sample;
            previousBuffer = CVPixelBufferRetain(currentBuffer);
        }

        metrics.elapsedTotalMs = (CACurrentMediaTime() - start) * 1000.0;
        if (previousBuffer != nullptr) {
            CVPixelBufferRelease(previousBuffer);
        }
        if (previousSample != nullptr) {
            CFRelease(previousSample);
        }
        CFRelease(cache);
        StopPowerSampler(powerTask);

        std::sort(metrics.gpuMs.begin(), metrics.gpuMs.end());
        const double median = metrics.gpuMs.empty() ? 0.0 : metrics.gpuMs[metrics.gpuMs.size() / 2];
        const double p95 = metrics.gpuMs.empty() ? 0.0 : metrics.gpuMs[std::min(metrics.gpuMs.size() - 1, metrics.gpuMs.size() * 95 / 100)];
        const double p99 = metrics.gpuMs.empty() ? 0.0 : metrics.gpuMs[std::min(metrics.gpuMs.size() - 1, metrics.gpuMs.size() * 99 / 100)];
        const double avg = metrics.gpuMs.empty()
            ? 0.0
            : std::accumulate(metrics.gpuMs.begin(), metrics.gpuMs.end(), 0.0) / static_cast<double>(metrics.gpuMs.size());
        const double samples = std::max(1, std::min(metrics.generated, 6));
        const double madPrev = metrics.madPrev / samples;
        const double madCurr = metrics.madCurr / samples;
        const double madLinear = metrics.madLinear / samples;
        const double madSource = metrics.madSource / samples;
        const bool backendExecuted = metrics.generated > 0 && avg > 0.0;
        const bool visualConfidence =
            madSource < 0.50 ||
            madPrev > 0.05 ||
            madCurr > 0.05 ||
            madLinear > 0.02;
        const double elapsedSec = metrics.elapsedTotalMs / 1000.0;
        const int expectedPairs = std::max(0, metrics.sourceFrames - 1);
        const int enhancedFrames = metrics.sourceFrames + metrics.generated;
        const int presentedFrames = metrics.presentedFrames > 0 ? metrics.presentedFrames : enhancedFrames;
        const double coverage = expectedPairs > 0 ? static_cast<double>(metrics.generated) / static_cast<double>(expectedPairs) : 0.0;
        const double sourceReadFps = elapsedSec > 0.0 ? static_cast<double>(metrics.sourceFrames) / elapsedSec : 0.0;
        const double pairProcessFps = elapsedSec > 0.0 ? static_cast<double>(metrics.generated) / elapsedSec : 0.0;
        const double enhancedThroughputFps = elapsedSec > 0.0 ? static_cast<double>(presentedFrames) / elapsedSec : 0.0;
        const double realtimeX = durationSec > 0.0 && elapsedSec > 0.0 ? durationSec / elapsedSec : 0.0;
        const double mediaSourceFps = durationSec > 0.0 ? static_cast<double>(metrics.sourceFrames) / durationSec : nominalSourceFps;
        const double mediaEnhancedFps = durationSec > 0.0 ? static_cast<double>(presentedFrames) / durationSec : nominalSourceFps * 2.0;

        std::cout << "video=" << options.videoPath << "\n";
        std::cout << "backend=" << options.backend
                  << " mode=" << (options.fullVideo ? "full_video" : "sample")
                  << " multi_t=" << (options.multiT ? "yes" : "no")
                  << " generated=" << metrics.generated
                  << " failed=" << metrics.failed
                  << " source_frames=" << metrics.sourceFrames
                  << " presented_frames=" << presentedFrames
                  << " model=" << modelWidth << "x" << modelHeight
                  << " total=" << metrics.elapsedTotalMs << "ms\n";
        std::cout << "gpu_ms median=" << median << " p95=" << p95 << " p99=" << p99 << " avg=" << avg << "\n";
        std::cout << "full_video_stats duration=" << durationSec
                  << "s nominal_source_fps=" << nominalSourceFps
                  << " measured_source_fps=" << mediaSourceFps
                  << " enhanced_media_fps=" << mediaEnhancedFps
                  << " coverage=" << coverage
                  << " realtime_x=" << realtimeX << "\n";
        std::cout << "throughput source_read_fps=" << sourceReadFps
                  << " generated_pair_fps=" << pairProcessFps
                  << " enhanced_output_fps=" << enhancedThroughputFps << "\n";
        std::cout << "interpolation_check backend_executed=" << (backendExecuted ? "yes" : "no")
                  << " visual_confidence=" << (visualConfidence ? "yes" : "low")
                  << " mad_source=" << madSource
                  << " mad_prev=" << madPrev
                  << " mad_curr=" << madCurr
                  << " mad_linear=" << madLinear << "\n";
        PrintPowerSummary(powerData);

        return backendExecuted ? 0 : 1;
    }
}
