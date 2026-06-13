#include "Video/MotionOfflineProcessor.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

namespace {

CGSize SMNaturalVideoSize(AVAssetTrack* track) {
    CGSize naturalSize = CGSizeApplyAffineTransform(track.naturalSize, track.preferredTransform);
    naturalSize.width = fabs(naturalSize.width);
    naturalSize.height = fabs(naturalSize.height);
    if (naturalSize.width < 1.0 || naturalSize.height < 1.0) {
        return track.naturalSize;
    }
    return naturalSize;
}

CIImage* SMUpscaleImage(CIImage* image, double upscale, CGRect outputExtent) {
    if (upscale <= 1.01) {
        return [image imageByCroppingToRect:outputExtent];
    }

    CIFilter* lanczos = [CIFilter filterWithName:@"CILanczosScaleTransform"];
    [lanczos setValue:image forKey:kCIInputImageKey];
    [lanczos setValue:@(upscale) forKey:kCIInputScaleKey];
    [lanczos setValue:@1.0 forKey:kCIInputAspectRatioKey];
    CIImage* output = lanczos.outputImage ?: [image imageByApplyingTransform:CGAffineTransformMakeScale(upscale, upscale)];
    return [output imageByCroppingToRect:outputExtent];
}

CIImage* SMMixFrames(CIImage* previous, CIImage* current, double t, CGRect extent) {
    if (t <= 0.001) {
        return [previous imageByCroppingToRect:extent];
    }
    if (t >= 0.999) {
        return [current imageByCroppingToRect:extent];
    }

    CIImage* mask = [[CIImage imageWithColor:[CIColor colorWithRed:t green:t blue:t alpha:1.0]] imageByCroppingToRect:extent];
    CIFilter* blend = [CIFilter filterWithName:@"CIBlendWithMask"];
    [blend setValue:[current imageByCroppingToRect:extent] forKey:kCIInputImageKey];
    [blend setValue:[previous imageByCroppingToRect:extent] forKey:kCIInputBackgroundImageKey];
    [blend setValue:mask forKey:kCIInputMaskImageKey];
    return blend.outputImage ?: [previous imageByCroppingToRect:extent];
}

NSString* SMStatus(NSString* phase, int64_t frameIndex, double progress) {
    return [NSString stringWithFormat:@"%@ · frame %lld · %.0f%%", phase, frameIndex, progress * 100.0];
}

struct SMBGRAInterpolateParams {
    uint32_t outWidth;
    uint32_t outHeight;
    simd_float2 inverseUpscale;
    float t;
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

BOOL SMCreateTexture(CVMetalTextureCacheRef cache,
                     CVPixelBufferRef buffer,
                     MTLPixelFormat pixelFormat,
                     id<MTLTexture>* textureOut,
                     CVMetalTextureRef* textureRefOut) {
    const size_t width = CVPixelBufferGetWidth(buffer);
    const size_t height = CVPixelBufferGetHeight(buffer);
    CVMetalTextureRef textureRef = nullptr;
    const CVReturn result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                      cache,
                                                                      buffer,
                                                                      nullptr,
                                                                      pixelFormat,
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

BOOL SMSafeAppendPixelBuffer(AVAssetWriterInputPixelBufferAdaptor* adaptor,
                             CVPixelBufferRef buffer,
                             CMTime pts,
                             AVAssetWriter* writer,
                             NSString** message) {
    @try {
        if ([adaptor appendPixelBuffer:buffer withPresentationTime:pts]) {
            return YES;
        }
        if (message != nullptr) {
            *message = writer.error.localizedDescription ?: @"写入视频帧失败";
        }
        return NO;
    } @catch (NSException* exception) {
        if (message != nullptr) {
            *message = [NSString stringWithFormat:@"写入视频帧异常：%@", exception.reason ?: exception.name];
        }
        return NO;
    }
}

BOOL SMSafeAppendSampleBuffer(AVAssetWriterInput* input,
                              CMSampleBufferRef sample,
                              AVAssetWriter* writer,
                              NSString** message) {
    @try {
        if ([input appendSampleBuffer:sample]) {
            return YES;
        }
        if (message != nullptr) {
            *message = writer.error.localizedDescription ?: @"写入音频失败";
        }
        return NO;
    } @catch (NSException* exception) {
        if (message != nullptr) {
            *message = [NSString stringWithFormat:@"写入音频异常：%@", exception.reason ?: exception.name];
        }
        return NO;
    }
}

BOOL SMWaitForWriterInputReady(AVAssetWriterInput* input,
                               AVAssetWriter* writer,
                               BOOL (^cancelled)(void),
                               NSString** message) {
    const CFTimeInterval start = CACurrentMediaTime();
    while (!input.readyForMoreMediaData) {
        if (cancelled != nil && cancelled()) {
            return NO;
        }
        if (writer.status != AVAssetWriterStatusWriting) {
            if (message != nullptr) {
                *message = writer.error.localizedDescription ?: @"writer 已停止";
            }
            return NO;
        }
        if (CACurrentMediaTime() - start > 10.0) {
            if (message != nullptr) {
                *message = @"writer 背压超时，已中止避免卡死";
            }
            return NO;
        }
        [NSThread sleepForTimeInterval:0.002];
    }
    return YES;
}

} // namespace

@implementation SMMotionOfflineProcessor

- (void)cancel {
    self.cancelled = YES;
}

- (void)startExportFromURL:(NSURL*)inputURL
                     toURL:(NSURL*)outputURL
                   upscale:(double)upscale
                 targetFPS:(double)targetFPS
                  progress:(SMMotionOfflineProgressHandler)progress
                completion:(SMMotionOfflineCompletionHandler)completion {
    self.cancelled = NO;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError* removeError = nil;
        if ([[NSFileManager defaultManager] fileExistsAtPath:outputURL.path]) {
            [[NSFileManager defaultManager] removeItemAtURL:outputURL error:&removeError];
        }
        if (removeError != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, [NSString stringWithFormat:@"无法覆盖输出文件：%@", removeError.localizedDescription]);
            });
            return;
        }

        AVURLAsset* asset = [AVURLAsset URLAssetWithURL:inputURL options:nil];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        AVAssetTrack* videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
        AVAssetTrack* audioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
#pragma clang diagnostic pop
        if (videoTrack == nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"未找到视频轨道");
            });
            return;
        }

        const CGSize inputSize = SMNaturalVideoSize(videoTrack);
        double effectiveUpscale = upscale;
        if (inputSize.width * effectiveUpscale > 7680.0 || inputSize.height * effectiveUpscale > 4320.0) {
            effectiveUpscale = MIN(7680.0 / inputSize.width, 4320.0 / inputSize.height);
        }
        int outputWidth = static_cast<int>(ceil(inputSize.width * effectiveUpscale));
        int outputHeight = static_cast<int>(ceil(inputSize.height * effectiveUpscale));
        outputWidth += outputWidth % 2;
        outputHeight += outputHeight % 2;
        const CGSize outputSize = CGSizeMake(outputWidth, outputHeight);
        const double safeTargetFPS = targetFPS > 1.0 ? targetFPS : 60.0;
        const CMTime frameDuration = CMTimeMake(1000, static_cast<int32_t>(llround(safeTargetFPS * 1000.0)));
        const CGRect sourceExtent = CGRectMake(0.0, 0.0, inputSize.width, inputSize.height);
        const CGRect outputExtent = CGRectMake(0.0, 0.0, outputSize.width, outputSize.height);
        const CMTime maxOutputTime = self.maxDurationSeconds > 0.0 ? CMTimeMakeWithSeconds(self.maxDurationSeconds, 600) : asset.duration;

        NSError* readerError = nil;
        AVAssetReader* reader = [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
        if (reader == nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, [NSString stringWithFormat:@"AVAssetReader 创建失败：%@", readerError.localizedDescription ?: @"未知错误"]);
            });
            return;
        }

        NSDictionary* readerSettings = @{
            (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (NSString*)kCVPixelBufferMetalCompatibilityKey: @YES,
            (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        AVAssetReaderTrackOutput* videoOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:readerSettings];
        videoOutput.alwaysCopiesSampleData = NO;
        if (![reader canAddOutput:videoOutput]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"AVAssetReader 无法添加视频输出");
            });
            return;
        }
        [reader addOutput:videoOutput];

        AVAssetReaderTrackOutput* audioOutput = nil;
        if (self.includeAudio && audioTrack != nil) {
            audioOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:audioTrack outputSettings:nil];
            audioOutput.alwaysCopiesSampleData = NO;
            if ([reader canAddOutput:audioOutput]) {
                [reader addOutput:audioOutput];
            } else {
                audioOutput = nil;
            }
        }

        NSError* writerError = nil;
        AVAssetWriter* writer = [[AVAssetWriter alloc] initWithURL:outputURL fileType:AVFileTypeMPEG4 error:&writerError];
        if (writer == nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, [NSString stringWithFormat:@"AVAssetWriter 创建失败：%@", writerError.localizedDescription ?: @"未知错误"]);
            });
            return;
        }

        NSArray<AVVideoCodecType>* codecCandidates = @[(AVVideoCodecType)@"av01", AVVideoCodecTypeHEVC, AVVideoCodecTypeH264];
        AVAssetWriterInput* videoInput = nil;
        for (AVVideoCodecType codec in codecCandidates) {
            NSMutableDictionary* compression = [@{
                AVVideoAverageBitRateKey: @(MAX(8'000'000, static_cast<int>(outputSize.width * outputSize.height * 6.0))),
            } mutableCopy];
            if ([codec isEqualToString:AVVideoCodecTypeH264]) {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel;
            }
            NSDictionary* writerSettings = @{
                AVVideoCodecKey: codec,
                AVVideoWidthKey: @(outputWidth),
                AVVideoHeightKey: @(outputHeight),
                AVVideoCompressionPropertiesKey: compression,
            };
            AVAssetWriterInput* candidateInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:writerSettings];
            candidateInput.expectsMediaDataInRealTime = NO;
            if ([writer canAddInput:candidateInput]) {
                videoInput = candidateInput;
                break;
            }
        }
        if (videoInput == nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"AVAssetWriter 无法添加 AV1/HEVC/H.264 视频输入");
            });
            return;
        }
        NSDictionary* adaptorAttrs = @{
            (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (NSString*)kCVPixelBufferWidthKey: @(outputWidth),
            (NSString*)kCVPixelBufferHeightKey: @(outputHeight),
            (NSString*)kCVPixelBufferMetalCompatibilityKey: @YES,
            (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        AVAssetWriterInputPixelBufferAdaptor* adaptor =
            [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:videoInput
                                                                              sourcePixelBufferAttributes:adaptorAttrs];
        [writer addInput:videoInput];

        AVAssetWriterInput* audioInput = nil;
        if (self.includeAudio && audioTrack != nil && audioOutput != nil) {
            CMFormatDescriptionRef audioFormat = nullptr;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            if (audioTrack.formatDescriptions.count > 0) {
                audioFormat = (__bridge CMFormatDescriptionRef)audioTrack.formatDescriptions.firstObject;
            }
#pragma clang diagnostic pop
            audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                            outputSettings:nil
                                                          sourceFormatHint:audioFormat];
            audioInput.expectsMediaDataInRealTime = NO;
            if ([writer canAddInput:audioInput]) {
                [writer addInput:audioInput];
            } else {
                audioInput = nil;
            }
        }

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> commandQueue = device != nil ? [device newCommandQueue] : nil;
        CVMetalTextureCacheRef textureCache = nullptr;
        if (device != nil) {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, device, nullptr, &textureCache);
        }
        id<MTLComputePipelineState> interpolatePipeline = nil;
        if (device != nil && commandQueue != nil && textureCache != nullptr) {
            NSURL* libraryURL = SMMotionKernelLibraryURL();
            if (libraryURL != nil) {
                NSError* metalError = nil;
                id<MTLLibrary> library = [device newLibraryWithURL:libraryURL error:&metalError];
                id<MTLFunction> function = [library newFunctionWithName:@"fused_bgra_interpolate_lanczos_present"];
                if (function != nil) {
                    interpolatePipeline = [device newComputePipelineStateWithFunction:function error:&metalError];
                }
            }
        }

        CIContext* ciContext = device != nil
            ? [CIContext contextWithMTLDevice:device options:@{kCIContextWorkingColorSpace: [NSNull null]}]
            : [CIContext contextWithOptions:@{kCIContextWorkingColorSpace: [NSNull null]}];
        CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);

        if (![reader startReading] || ![writer startWriting]) {
            NSString* message = reader.error.localizedDescription ?: writer.error.localizedDescription ?: @"读写器启动失败";
            if (colorSpace != nil) {
                CGColorSpaceRelease(colorSpace);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, message);
            });
            return;
        }
        [writer startSessionAtSourceTime:kCMTimeZero];

        CMSampleBufferRef previousSample = nullptr;
        CIImage* previousImage = nil;
        CMTime previousPTS = kCMTimeInvalid;
        CMTime nextOutputPTS = kCMTimeZero;
        int64_t outputFrameIndex = 0;
        const double durationSeconds = CMTimeGetSeconds(asset.duration);
        BOOL failed = NO;
        NSString* failureMessage = nil;

        while (!self.cancelled) {
            CMSampleBufferRef currentSample = [videoOutput copyNextSampleBuffer];
            if (currentSample == nullptr) {
                break;
            }

            CVPixelBufferRef currentBuffer = CMSampleBufferGetImageBuffer(currentSample);
            CMTime currentPTS = CMSampleBufferGetPresentationTimeStamp(currentSample);
            if (CMTimeCompare(currentPTS, maxOutputTime) > 0) {
                CFRelease(currentSample);
                break;
            }
            CIImage* currentImage = [CIImage imageWithCVPixelBuffer:currentBuffer];

            if (previousSample == nullptr) {
                previousSample = currentSample;
                previousImage = currentImage;
                previousPTS = currentPTS;
                nextOutputPTS = CMTimeCompare(currentPTS, kCMTimeZero) > 0 ? currentPTS : kCMTimeZero;
                continue;
            }

            while (!self.cancelled &&
                   CMTimeCompare(nextOutputPTS, currentPTS) < 0 &&
                   writer.status == AVAssetWriterStatusWriting) {
                @autoreleasepool {
                    NSString* waitMessage = nil;
                    if (!SMWaitForWriterInputReady(videoInput, writer, ^BOOL{
                        return self.cancelled;
                    }, &waitMessage)) {
                        failed = !self.cancelled;
                        failureMessage = waitMessage ?: @"视频 writer 等待失败";
                        break;
                    }

                    const double interval = MAX(CMTimeGetSeconds(CMTimeSubtract(currentPTS, previousPTS)), 1.0 / safeTargetFPS);
                    const double offset = MAX(CMTimeGetSeconds(CMTimeSubtract(nextOutputPTS, previousPTS)), 0.0);
                    const double t = MIN(MAX(offset / interval, 0.0), 1.0);
                    CVPixelBufferRef outputBuffer = nullptr;
                    CVReturn poolResult = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool, &outputBuffer);
                    if (poolResult != kCVReturnSuccess || outputBuffer == nullptr) {
                        failed = YES;
                        failureMessage = @"无法从 writer pool 获取输出 pixel buffer";
                        break;
                    }

                    BOOL renderedWithMetal = NO;
                    if (interpolatePipeline != nil && textureCache != nullptr) {
                        CVPixelBufferRef previousBuffer = CMSampleBufferGetImageBuffer(previousSample);
                        CVPixelBufferRef currentPixelBuffer = CMSampleBufferGetImageBuffer(currentSample);
                        id<MTLTexture> previousTexture = nil;
                        id<MTLTexture> currentTexture = nil;
                        id<MTLTexture> outputTexture = nil;
                        CVMetalTextureRef previousTextureRef = nullptr;
                        CVMetalTextureRef currentTextureRef = nullptr;
                        CVMetalTextureRef outputTextureRef = nullptr;
                        if (SMCreateTexture(textureCache, previousBuffer, MTLPixelFormatBGRA8Unorm, &previousTexture, &previousTextureRef) &&
                            SMCreateTexture(textureCache, currentPixelBuffer, MTLPixelFormatBGRA8Unorm, &currentTexture, &currentTextureRef) &&
                            SMCreateTexture(textureCache, outputBuffer, MTLPixelFormatBGRA8Unorm, &outputTexture, &outputTextureRef)) {
                            SMBGRAInterpolateParams params{
                                .outWidth = static_cast<uint32_t>(outputSize.width),
                                .outHeight = static_cast<uint32_t>(outputSize.height),
                                .inverseUpscale = simd_make_float2(static_cast<float>(1.0 / effectiveUpscale), static_cast<float>(1.0 / effectiveUpscale)),
                                .t = static_cast<float>(t),
                            };
                            id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
                            id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
                            [encoder setComputePipelineState:interpolatePipeline];
                            [encoder setTexture:previousTexture atIndex:0];
                            [encoder setTexture:currentTexture atIndex:1];
                            [encoder setTexture:outputTexture atIndex:2];
                            [encoder setBytes:&params length:sizeof(params) atIndex:0];
                            const NSUInteger threadsWide = interpolatePipeline.threadExecutionWidth;
                            const NSUInteger threadsHigh = MAX(1, interpolatePipeline.maxTotalThreadsPerThreadgroup / threadsWide);
                            [encoder dispatchThreads:MTLSizeMake(static_cast<NSUInteger>(outputSize.width),
                                                                  static_cast<NSUInteger>(outputSize.height),
                                                                  1)
                                 threadsPerThreadgroup:MTLSizeMake(threadsWide, threadsHigh, 1)];
                            [encoder endEncoding];
                            [commandBuffer commit];
                            [commandBuffer waitUntilCompleted];
                            renderedWithMetal = commandBuffer.status == MTLCommandBufferStatusCompleted;
                        }
                        if (previousTextureRef != nullptr) {
                            CFRelease(previousTextureRef);
                        }
                        if (currentTextureRef != nullptr) {
                            CFRelease(currentTextureRef);
                        }
                        if (outputTextureRef != nullptr) {
                            CFRelease(outputTextureRef);
                        }
                    }

                    if (!renderedWithMetal) {
                        CIImage* mixed = SMMixFrames(previousImage, currentImage, t, sourceExtent);
                        CIImage* output = SMUpscaleImage(mixed, effectiveUpscale, outputExtent);
                        [ciContext render:output toCVPixelBuffer:outputBuffer bounds:outputExtent colorSpace:colorSpace];
                    }

                    NSString* appendMessage = nil;
                    if (!SMSafeAppendPixelBuffer(adaptor, outputBuffer, nextOutputPTS, writer, &appendMessage)) {
                        failed = YES;
                        failureMessage = appendMessage ?: @"写入插帧帧失败";
                        CVPixelBufferRelease(outputBuffer);
                        break;
                    }
                    CVPixelBufferRelease(outputBuffer);

                    outputFrameIndex++;
                    const double outputSeconds = CMTimeGetSeconds(nextOutputPTS);
                    const double normalized = durationSeconds > 0.0 ? MIN(outputSeconds / durationSeconds, 0.995) : 0.0;
                    if (outputFrameIndex % 8 == 0) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            progress(normalized, SMStatus(@"Offline VFI + 2x SR", outputFrameIndex, normalized));
                        });
                    }
                    nextOutputPTS = CMTimeAdd(nextOutputPTS, frameDuration);
                }
                if (failed) {
                    break;
                }
            }

            if (failed) {
                CFRelease(currentSample);
                break;
            }

            if (previousSample != nullptr) {
                CFRelease(previousSample);
            }
            previousSample = currentSample;
            previousImage = currentImage;
            previousPTS = currentPTS;
        }

        if (!failed && !self.cancelled && previousImage != nil) {
            const CMTime endTime = asset.duration.value > 0 ? maxOutputTime : previousPTS;
            while (CMTimeCompare(nextOutputPTS, endTime) < 0 && writer.status == AVAssetWriterStatusWriting) {
                @autoreleasepool {
                    if (self.cancelled) {
                        break;
                    }
                    NSString* waitMessage = nil;
                    if (!SMWaitForWriterInputReady(videoInput, writer, ^BOOL{
                        return self.cancelled;
                    }, &waitMessage)) {
                        failed = !self.cancelled;
                        failureMessage = waitMessage ?: @"末帧 writer 等待失败";
                        break;
                    }
                    CVPixelBufferRef outputBuffer = nullptr;
                    CVReturn poolResult = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool, &outputBuffer);
                    if (poolResult != kCVReturnSuccess || outputBuffer == nullptr) {
                        failed = YES;
                        failureMessage = @"无法从 writer pool 获取末帧 pixel buffer";
                        break;
                    }

                    BOOL renderedWithMetal = NO;
                    if (interpolatePipeline != nil && textureCache != nullptr && previousSample != nullptr) {
                        CVPixelBufferRef previousBuffer = CMSampleBufferGetImageBuffer(previousSample);
                        id<MTLTexture> previousTexture = nil;
                        id<MTLTexture> outputTexture = nil;
                        CVMetalTextureRef previousTextureRef = nullptr;
                        CVMetalTextureRef outputTextureRef = nullptr;
                        if (SMCreateTexture(textureCache, previousBuffer, MTLPixelFormatBGRA8Unorm, &previousTexture, &previousTextureRef) &&
                            SMCreateTexture(textureCache, outputBuffer, MTLPixelFormatBGRA8Unorm, &outputTexture, &outputTextureRef)) {
                            SMBGRAInterpolateParams params{
                                .outWidth = static_cast<uint32_t>(outputSize.width),
                                .outHeight = static_cast<uint32_t>(outputSize.height),
                                .inverseUpscale = simd_make_float2(static_cast<float>(1.0 / effectiveUpscale), static_cast<float>(1.0 / effectiveUpscale)),
                                .t = 0.0f,
                            };
                            id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
                            id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
                            [encoder setComputePipelineState:interpolatePipeline];
                            [encoder setTexture:previousTexture atIndex:0];
                            [encoder setTexture:previousTexture atIndex:1];
                            [encoder setTexture:outputTexture atIndex:2];
                            [encoder setBytes:&params length:sizeof(params) atIndex:0];
                            const NSUInteger threadsWide = interpolatePipeline.threadExecutionWidth;
                            const NSUInteger threadsHigh = MAX(1, interpolatePipeline.maxTotalThreadsPerThreadgroup / threadsWide);
                            [encoder dispatchThreads:MTLSizeMake(static_cast<NSUInteger>(outputSize.width),
                                                                  static_cast<NSUInteger>(outputSize.height),
                                                                  1)
                                 threadsPerThreadgroup:MTLSizeMake(threadsWide, threadsHigh, 1)];
                            [encoder endEncoding];
                            [commandBuffer commit];
                            [commandBuffer waitUntilCompleted];
                            renderedWithMetal = commandBuffer.status == MTLCommandBufferStatusCompleted;
                        }
                        if (previousTextureRef != nullptr) {
                            CFRelease(previousTextureRef);
                        }
                        if (outputTextureRef != nullptr) {
                            CFRelease(outputTextureRef);
                        }
                    }
                    if (!renderedWithMetal) {
                        CIImage* output = SMUpscaleImage(previousImage, effectiveUpscale, outputExtent);
                        [ciContext render:output toCVPixelBuffer:outputBuffer bounds:outputExtent colorSpace:colorSpace];
                    }

                    NSString* appendMessage = nil;
                    if (!SMSafeAppendPixelBuffer(adaptor, outputBuffer, nextOutputPTS, writer, &appendMessage)) {
                        failed = YES;
                        failureMessage = appendMessage ?: @"写入末帧失败";
                        CVPixelBufferRelease(outputBuffer);
                        break;
                    }
                    CVPixelBufferRelease(outputBuffer);
                    outputFrameIndex++;
                    nextOutputPTS = CMTimeAdd(nextOutputPTS, frameDuration);
                }
            }
        }

        if (!failed && !self.cancelled && audioInput != nil && audioOutput != nil) {
            CMSampleBufferRef audioSample = nullptr;
            while (!self.cancelled && writer.status == AVAssetWriterStatusWriting) {
                audioSample = [audioOutput copyNextSampleBuffer];
                if (audioSample == nullptr) {
                    break;
                }
                if (CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(audioSample), maxOutputTime) > 0) {
                    CFRelease(audioSample);
                    break;
                }
                if (self.cancelled) {
                    CFRelease(audioSample);
                    break;
                }
                NSString* waitMessage = nil;
                if (!SMWaitForWriterInputReady(audioInput, writer, ^BOOL{
                    return self.cancelled;
                }, &waitMessage)) {
                    failed = !self.cancelled;
                    failureMessage = waitMessage ?: @"音频 writer 等待失败";
                    CFRelease(audioSample);
                    break;
                }
                NSString* appendMessage = nil;
                if (!SMSafeAppendSampleBuffer(audioInput, audioSample, writer, &appendMessage)) {
                    failed = YES;
                    failureMessage = appendMessage ?: @"写入音频失败";
                    CFRelease(audioSample);
                    break;
                }
                CFRelease(audioSample);
            }
        }

        if (previousSample != nullptr) {
            CFRelease(previousSample);
        }
        if (colorSpace != nil) {
            CGColorSpaceRelease(colorSpace);
        }
        if (textureCache != nullptr) {
            CFRelease(textureCache);
        }

        if (self.cancelled) {
            [reader cancelReading];
            [writer cancelWriting];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"导出已取消");
            });
            return;
        }

        if (failed) {
            [reader cancelReading];
            [writer cancelWriting];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, failureMessage ?: @"离线处理失败");
            });
            return;
        }

        [videoInput markAsFinished];
        if (audioInput != nil) {
            [audioInput markAsFinished];
        }
        [writer finishWritingWithCompletionHandler:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                if (writer.status == AVAssetWriterStatusCompleted) {
                    progress(1.0, @"Offline VFI + 2x SR · 100%");
                    completion(YES, [NSString stringWithFormat:@"导出完成：%@", outputURL.lastPathComponent]);
                } else {
                    completion(NO, writer.error.localizedDescription ?: @"writer 未完成");
                }
            });
        }];
    });
}

@end
