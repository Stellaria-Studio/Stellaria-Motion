#include "Metal/MotionMetalRuntime.h"

#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>

#include <sstream>
#include <vector>

namespace Stellaria::Motion::Metal {

Runtime::Runtime() {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    device_ = (__bridge_retained void*)device;

    if (device != nil) {
        id<MTLCommandQueue> queue = [device newCommandQueue];
        commandQueue_ = (__bridge_retained void*)queue;

        CVMetalTextureCacheRef cache = nullptr;
        if (CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, device, nullptr, &cache) == kCVReturnSuccess) {
            textureCache_ = cache;
        }
    }
}

bool Runtime::IsAvailable() const {
    return device_ != nullptr && commandQueue_ != nullptr;
}

std::string Runtime::DeviceName() const {
    id<MTLDevice> device = (__bridge id<MTLDevice>)device_;
    if (device == nil) {
        return "unavailable";
    }
    return std::string([[device name] UTF8String]);
}

bool Runtime::HasTextureCache() const {
    return textureCache_ != nullptr;
}

std::string Runtime::OSVersionString() const {
    NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    std::ostringstream out;
    out << version.majorVersion << "." << version.minorVersion << "." << version.patchVersion;
    return out.str();
}

std::string Runtime::FeatureSummary() const {
    id<MTLDevice> device = (__bridge id<MTLDevice>)device_;
    if (device == nil) {
        return "Metal unavailable";
    }

    std::vector<std::string> features;
    auto hasFamily = [&](MTLGPUFamily family) -> bool {
        if (![device respondsToSelector:@selector(supportsFamily:)]) {
            return false;
        }
        return [device supportsFamily:family];
    };
    auto boolSelector = [&](NSString* name) -> bool {
        SEL selector = NSSelectorFromString(name);
        if (![device respondsToSelector:selector]) {
            return false;
        }
        using MsgSendBool = BOOL (*)(id, SEL);
        return reinterpret_cast<MsgSendBool>(objc_msgSend)(device, selector);
    };

    if (hasFamily(MTLGPUFamilyApple7)) {
        features.push_back("Apple7+");
    }
    if (hasFamily(MTLGPUFamilyMac2)) {
        features.push_back("Mac2+");
    }
    if (hasFamily(MTLGPUFamilyCommon3)) {
        features.push_back("Common3+");
    }
    if (boolSelector(@"supportsRaytracing")) {
        features.push_back("raytracing");
    }
    if (boolSelector(@"supportsFunctionPointers")) {
        features.push_back("function-pointers");
    }
    if (boolSelector(@"supportsDynamicLibraries")) {
        features.push_back("dynamic-libraries");
    }
    if (boolSelector(@"supportsSparseTextures")) {
        features.push_back("sparse-textures");
    }

    std::ostringstream out;
    out << "macOS " << OSVersionString();
    if (!features.empty()) {
        out << " · ";
        for (size_t i = 0; i < features.size(); ++i) {
            if (i > 0) {
                out << ", ";
            }
            out << features[i];
        }
    }
    return out.str();
}

} // namespace Stellaria::Motion::Metal
