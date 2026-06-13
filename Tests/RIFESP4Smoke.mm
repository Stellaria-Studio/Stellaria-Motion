#include "VFI/RIFESP4Runner.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <cassert>
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
            pixels[o + 1] = static_cast<uint8_t>((y * 2U + seed) & 255U);
            pixels[o + 2] = static_cast<uint8_t>((x + y + seed * 5U) & 255U);
            pixels[o + 3] = 255;
        }
    }
    [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                mipmapLevel:0
                  withBytes:pixels.data()
                bytesPerRow:width * 4];
    return texture;
}

} // namespace

int main() {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        assert(device != nil);
        id<MTLCommandQueue> queue = [device newCommandQueue];
        assert(queue != nil);

        id<MTLTexture> previous = Texture(device, 640, 360, 9);
        id<MTLTexture> current = Texture(device, 640, 360, 21);
        id<MTLTexture> output = Texture(device, 640, 360, 0);
        id<MTLTexture> lateOutput = Texture(device, 640, 360, 0);

        Stellaria::Motion::RIFESP4Runner runner;
        runner.SetCommandQueue((__bridge void*)queue);
        assert(runner.Load(ModelPath().string(), 256, 144));
        Stellaria::Motion::RIFESP4RunResult result =
            runner.RunTextures((__bridge void*)previous,
                               (__bridge void*)current,
                               (__bridge void*)output,
                               640,
                               360);
        assert(result.ok);
        Stellaria::Motion::RIFESP4RunResult lateResult =
            runner.RunTexturesAtT((__bridge void*)previous,
                                  (__bridge void*)current,
                                  (__bridge void*)lateOutput,
                                  640,
                                  360,
                                  0.8f);
        assert(lateResult.ok);
        std::cout << "RIFE SP4 smoke " << result.modelWidth << "x" << result.modelHeight
                  << " -> " << result.width << "x" << result.height
                  << " elapsed=" << result.elapsedMs << "ms\n";
    }
    return 0;
}
