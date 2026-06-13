#include "Video/MotionVideoSource.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>

#include <cassert>
#include <filesystem>
#include <iostream>

namespace {

std::filesystem::path TestVideoPath() {
    std::filesystem::path path = std::filesystem::current_path() / "tools/test_video.mp4";
    if (!std::filesystem::exists(path)) {
        path = std::filesystem::current_path().parent_path() / "tools/test_video.mp4";
    }
    return path;
}

} // namespace

int main() {
    @autoreleasepool {
        const std::filesystem::path path = TestVideoPath();
        assert(std::filesystem::exists(path));

        const Stellaria::Motion::Video::SourceProbe probe =
            Stellaria::Motion::Video::ProbeLocalFile(path.string());
        assert(probe.supported);

        NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.string().c_str()]];
        AVURLAsset* asset = [AVURLAsset URLAssetWithURL:url options:nil];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        AVAssetTrack* track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
#pragma clang diagnostic pop
        assert(track != nil);

        AVPlayerItem* item = [AVPlayerItem playerItemWithAsset:asset];
        NSDictionary* outputAttributes = @{
            (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (NSString*)kCVPixelBufferMetalCompatibilityKey: @YES,
            (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        AVPlayerItemVideoOutput* output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:outputAttributes];
        assert(output != nil);
        [item addOutput:output];
        assert([item.outputs containsObject:output]);

        AVPlayer* player = [AVPlayer playerWithPlayerItem:item];
        assert(player.currentItem == item);
        [player pause];

        std::cout << "Local AVPlayerItemVideoOutput ready for " << path.filename().string() << "\n";
    }
    return 0;
}
