#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#include <cassert>

#include "Video/MotionOfflineProcessor.h"

namespace {

NSURL* SMTempURL(NSString* name) {
    NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    return [NSURL fileURLWithPath:path];
}

void SMFillPixelBuffer(CVPixelBufferRef buffer, uint8_t red, uint8_t green, uint8_t blue) {
    CVPixelBufferLockBaseAddress(buffer, 0);
    auto* base = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(buffer));
    const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    const size_t width = CVPixelBufferGetWidth(buffer);
    const size_t height = CVPixelBufferGetHeight(buffer);
    for (size_t y = 0; y < height; ++y) {
        uint8_t* row = base + y * stride;
        for (size_t x = 0; x < width; ++x) {
            row[x * 4 + 0] = blue;
            row[x * 4 + 1] = green;
            row[x * 4 + 2] = red;
            row[x * 4 + 3] = 255;
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
}

bool SMCreateSampleMovie(NSURL* url) {
    NSError* error = nil;
    AVAssetWriter* writer = [[AVAssetWriter alloc] initWithURL:url fileType:AVFileTypeMPEG4 error:&error];
    if (writer == nil) {
        return false;
    }

    NSDictionary* settings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @160,
        AVVideoHeightKey: @90,
    };
    AVAssetWriterInput* input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
    input.expectsMediaDataInRealTime = NO;
    NSDictionary* attrs = @{
        (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString*)kCVPixelBufferWidthKey: @160,
        (NSString*)kCVPixelBufferHeightKey: @90,
        (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    AVAssetWriterInputPixelBufferAdaptor* adaptor =
        [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                                                          sourcePixelBufferAttributes:attrs];
    if (![writer canAddInput:input]) {
        return false;
    }
    [writer addInput:input];
    if (![writer startWriting]) {
        return false;
    }
    [writer startSessionAtSourceTime:kCMTimeZero];

    for (int frame = 0; frame < 6; ++frame) {
        while (!input.readyForMoreMediaData) {
            [NSThread sleepForTimeInterval:0.002];
        }

        CVPixelBufferRef buffer = nullptr;
        if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool, &buffer) != kCVReturnSuccess) {
            return false;
        }
        SMFillPixelBuffer(buffer,
                          static_cast<uint8_t>(40 + frame * 28),
                          static_cast<uint8_t>(80 + frame * 15),
                          static_cast<uint8_t>(180 - frame * 18));
        const CMTime pts = CMTimeMake(frame, 12);
        const BOOL appended = [adaptor appendPixelBuffer:buffer withPresentationTime:pts];
        CVPixelBufferRelease(buffer);
        if (!appended) {
            return false;
        }
    }

    [input markAsFinished];
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    return writer.status == AVAssetWriterStatusCompleted;
}

} // namespace

int main() {
    @autoreleasepool {
        NSURL* inputURL = SMTempURL(@"stellaria-motion-offline-input.mp4");
        NSURL* outputURL = SMTempURL(@"stellaria-motion-offline-output.mp4");
        assert(SMCreateSampleMovie(inputURL));

        SMMotionOfflineProcessor* processor = [SMMotionOfflineProcessor new];
        __block BOOL completed = NO;
        __block BOOL success = NO;
        __block double lastProgress = 0.0;
        [processor startExportFromURL:inputURL
                                toURL:outputURL
                              upscale:2.0
                            targetFPS:60.0
                             progress:^(double progress, NSString*) {
                                 lastProgress = progress;
                             }
                           completion:^(BOOL didSucceed, NSString*) {
                               completed = YES;
                               success = didSucceed;
                           }];

        NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:30.0];
        while (!completed && [deadline timeIntervalSinceNow] > 0.0) {
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        }
        assert(completed);
        assert(success);
        assert(lastProgress >= 0.0);

        NSDictionary<NSFileAttributeKey, id>* attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:outputURL.path error:nil];
        assert([attrs fileSize] > 1024);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        AVURLAsset* outputAsset = [AVURLAsset URLAssetWithURL:outputURL options:nil];
        AVAssetTrack* track = [[outputAsset tracksWithMediaType:AVMediaTypeVideo] firstObject];
#pragma clang diagnostic pop
        assert(track != nil);
        assert(static_cast<int>(track.naturalSize.width) == 320);
        assert(static_cast<int>(track.naturalSize.height) == 180);
    }
    return 0;
}
