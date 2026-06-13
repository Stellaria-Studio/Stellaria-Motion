#include "VFI/RIFEMetal4BitRunner.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <cassert>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <numeric>
#include <vector>

namespace {

std::filesystem::path ModelPath() {
    std::filesystem::path path = std::filesystem::current_path() / "Models/RIFE-safetensors/flownet.safetensors";
    if (!std::filesystem::exists(path)) {
        path = std::filesystem::current_path().parent_path() / "Models/RIFE-safetensors/flownet.safetensors";
    }
    return path;
}

id<MTLTexture> Texture(id<MTLDevice> device, NSUInteger width, NSUInteger height, uint8_t seed) {
    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:width
                                                                                         height:height
                                                                                      mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    std::vector<uint8_t> pixels(width * height * 4);
    for (NSUInteger y = 0; y < height; ++y) {
        for (NSUInteger x = 0; x < width; ++x) {
            const NSUInteger o = (y * width + x) * 4;
            pixels[o + 0] = static_cast<uint8_t>((x + seed) & 255U);
            pixels[o + 1] = static_cast<uint8_t>((y + seed * 3U) & 255U);
            pixels[o + 2] = static_cast<uint8_t>((x + y + seed * 7U) & 255U);
            pixels[o + 3] = 255;
        }
    }
    [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                mipmapLevel:0
                  withBytes:pixels.data()
                bytesPerRow:width * 4];
    return texture;
}

void RunCase(id<MTLDevice> device,
             id<MTLCommandQueue> queue,
             NSUInteger width,
             NSUInteger height,
             uint32_t modelWidth,
             uint32_t modelHeight,
             double targetMs,
             double maxMs) {
    id<MTLTexture> previous = Texture(device, width, height, 11);
    id<MTLTexture> current = Texture(device, width, height, 23);
    id<MTLTexture> output = Texture(device, width, height, 0);

    Stellaria::Motion::RIFEMetal4BitRunner runner;
    runner.SetCommandQueue((__bridge void*)queue);
    assert(runner.Load(ModelPath().string(), modelWidth, modelHeight));
    std::vector<double> samples;
    for (int i = 0; i < 18; ++i) {
        Stellaria::Motion::RIFEMetal4BitRunResult result =
            runner.RunTextures((__bridge void*)previous,
                               (__bridge void*)current,
                               (__bridge void*)output,
                               width,
                               height);
        assert(result.ok);
        if (i >= 3) {
            samples.push_back(result.elapsedMs);
        }
    }
    std::sort(samples.begin(), samples.end());
    const double median = samples[samples.size() / 2];
    const double p95 = samples[std::min(samples.size() - 1, static_cast<size_t>(samples.size() * 95 / 100))];
    const double average = std::accumulate(samples.begin(), samples.end(), 0.0) / static_cast<double>(samples.size());
    std::cout << "RIFE Metal INT4 perf " << modelWidth << "x" << modelHeight
              << " -> " << width << "x" << height
              << " median=" << median << "ms"
              << " p95=" << p95 << "ms"
              << " avg=" << average << "ms\n";
    assert(p95 <= maxMs);
    if (std::getenv("STELLARIA_MOTION_STRICT_PERF") != nullptr || width >= 1920) {
        assert(p95 <= targetMs);
    }
}

} // namespace

int main() {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        assert(device != nil);
        id<MTLCommandQueue> queue = [device newCommandQueue];
        assert(queue != nil);
        RunCase(device, queue, 640, 360, 256, 144, 16.67, 33.3);
        RunCase(device, queue, 1920, 1080, 384, 216, 16.67, 33.3);
        RunCase(device, queue, 2560, 1440, 384, 216, 33.3, 33.3);
    }
    return 0;
}
