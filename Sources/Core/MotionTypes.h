#pragma once

#include <cstdint>
#include <string>

#ifdef __OBJC__
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
using MotionPixelBufferRef = CVPixelBufferRef;
using MotionSurfaceRef = IOSurfaceRef;
using MotionMetalTextureRef = id<MTLTexture>;
#else
using MotionPixelBufferRef = void*;
using MotionSurfaceRef = void*;
using MotionMetalTextureRef = void*;
#endif

namespace Stellaria::Motion {

enum class MotionEntryMode : uint8_t {
    LocalPlayback,
    ChromeOverlay,
    OfflineExport
};

enum class ContentProfile : uint8_t {
    Anime,
    General
};

enum class QualityMode : uint8_t {
    Q0_RepeatBlend,
    Q1_540Flow,
    Q2_720Flow,
    Q3_1080Flow,
    Q4_OfflineHQ
};

struct FrameToken {
    int64_t ptsNs = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t pixelFormat = 0;
    MotionPixelBufferRef pixelBuffer = nullptr;
    MotionSurfaceRef surface = nullptr;
    MotionMetalTextureRef yTexture = nullptr;
    MotionMetalTextureRef uvTexture = nullptr;
};

struct VFIJob {
    FrameToken f0;
    FrameToken f1;
    double t = 0.5;
    int64_t outputPtsNs = 0;
    ContentProfile profile = ContentProfile::Anime;
    QualityMode quality = QualityMode::Q2_720Flow;
};

struct MotionQualitySettings {
    double targetFps = 60.0;
    double frameMultiplier = 2.0;
    uint32_t flowInputHeight = 720;
    bool edgeAwareFlowUpscale = true;
    bool lineArtProtect = true;
    bool subtitleProtect = true;
    bool refineEnabled = true;
    bool offlineHighestQuality = false;
};

struct RuntimeStats {
    double decodeMs = 0.0;
    double packMs = 0.0;
    double detectMs = 0.0;
    double flowMs = 0.0;
    double upscaleMs = 0.0;
    double warpMs = 0.0;
    double refineMs = 0.0;
    double presentMs = 0.0;
    double gpuTotalMs = 0.0;
    double cpuSchedulingMs = 0.0;
    double overlayDriftMs = 0.0;
    uint32_t queueDepth = 0;
    uint32_t droppedFrames = 0;
    uint32_t repeatedFrames = 0;
    bool thermalPressure = false;
    bool onBattery = false;
};

inline const char* ToString(QualityMode mode) {
    switch (mode) {
        case QualityMode::Q0_RepeatBlend: return "Q0_RepeatBlend";
        case QualityMode::Q1_540Flow: return "Q1_540Flow";
        case QualityMode::Q2_720Flow: return "Q2_720Flow";
        case QualityMode::Q3_1080Flow: return "Q3_1080Flow";
        case QualityMode::Q4_OfflineHQ: return "Q4_OfflineHQ";
    }
    return "Unknown";
}

inline const char* ToString(ContentProfile profile) {
    switch (profile) {
        case ContentProfile::Anime: return "Anime";
        case ContentProfile::General: return "General";
    }
    return "Unknown";
}

} // namespace Stellaria::Motion

