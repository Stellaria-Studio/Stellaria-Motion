#include "VFI/RIFEMetal4BitRunner.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cassert>
#include <cmath>
#include <filesystem>
#include <iostream>
#include <vector>

namespace {

std::filesystem::path ModelPath() {
    std::filesystem::path path = std::filesystem::current_path() / "Models/RIFE-safetensors/flownet.safetensors";
    if (!std::filesystem::exists(path)) {
        path = std::filesystem::current_path().parent_path() / "Models/RIFE-safetensors/flownet.safetensors";
    }
    return path;
}

id<MTLTexture> Texture(id<MTLDevice> device, NSUInteger width, NSUInteger height, const std::vector<uint8_t>* pixels) {
    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:width
                                                                                         height:height
                                                                                      mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    if (pixels != nullptr) {
        [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                    mipmapLevel:0
                      withBytes:pixels->data()
                    bytesPerRow:width * 4];
    }
    return texture;
}

} // namespace

int main() {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        assert(device != nil);
        id<MTLCommandQueue> queue = [device newCommandQueue];
        assert(queue != nil);

        constexpr NSUInteger width = 320;
        constexpr NSUInteger height = 180;
        std::vector<uint8_t> previous(width * height * 4);
        std::vector<uint8_t> current(width * height * 4);
        for (NSUInteger y = 0; y < height; ++y) {
            for (NSUInteger x = 0; x < width; ++x) {
                const NSUInteger o = (y * width + x) * 4;
                previous[o + 0] = static_cast<uint8_t>((x + y) & 255U);
                previous[o + 1] = static_cast<uint8_t>((x * 2U) & 255U);
                previous[o + 2] = static_cast<uint8_t>((y * 2U) & 255U);
                previous[o + 3] = 255;
                current[o + 0] = static_cast<uint8_t>((x + y + 12U) & 255U);
                current[o + 1] = static_cast<uint8_t>(((x + 8U) * 2U) & 255U);
                current[o + 2] = static_cast<uint8_t>(((y + 4U) * 2U) & 255U);
                current[o + 3] = 255;
            }
        }

        id<MTLTexture> previousTexture = Texture(device, width, height, &previous);
        id<MTLTexture> currentTexture = Texture(device, width, height, &current);
        id<MTLTexture> outputTexture = Texture(device, width, height, nullptr);
        id<MTLTexture> outputLateTexture = Texture(device, width, height, nullptr);
        assert(previousTexture != nil && currentTexture != nil && outputTexture != nil && outputLateTexture != nil);

        Stellaria::Motion::RIFEMetal4BitRunner runner;
        runner.SetCommandQueue((__bridge void*)queue);
        const std::filesystem::path model = ModelPath();
        assert(runner.Load(model.string(), 256, 144));
        Stellaria::Motion::RIFEMetal4BitRunResult result =
            runner.RunTextures((__bridge void*)previousTexture,
                               (__bridge void*)currentTexture,
                               (__bridge void*)outputTexture,
                               width,
                               height);
        assert(result.ok);
        Stellaria::Motion::RIFEMetal4BitRunResult lateResult =
            runner.RunTexturesAtT((__bridge void*)previousTexture,
                                  (__bridge void*)currentTexture,
                                  (__bridge void*)outputLateTexture,
                                  width,
                                  height,
                                  0.8f);
        assert(lateResult.ok);

        std::vector<uint8_t> output(width * height * 4);
        [outputTexture getBytes:output.data()
                    bytesPerRow:width * 4
                     fromRegion:MTLRegionMake2D(0, 0, width, height)
                    mipmapLevel:0];
        uint64_t sum = 0;
        for (uint8_t value : output) {
            sum += value;
        }
        assert(sum > width * height);
        assert(std::isfinite(result.elapsedMs));
        std::cout << "RIFE Metal INT4 smoke " << result.modelWidth << "x" << result.modelHeight
                  << " " << result.elapsedMs << "ms " << runner.Diagnostics() << "\n";
    }
    return 0;
}
