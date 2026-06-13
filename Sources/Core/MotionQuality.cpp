#include "Core/MotionQuality.h"

#include <algorithm>

namespace Stellaria::Motion {

double QualityController::FrameBudgetMs(double fps) {
    return fps > 1.0 ? 1000.0 / fps : 16.667;
}

QualityMode QualityController::ResolveMode(const QualityInput& input) const {
    if (input.offlineExport) {
        return QualityMode::Q4_OfflineHQ;
    }

    if (input.sceneCut || input.duplicateFrame) {
        return QualityMode::Q0_RepeatBlend;
    }

    const double budget = FrameBudgetMs(input.targetFps);
    const bool is4K = input.sourceWidth >= 3840 || input.sourceHeight >= 2160;
    const bool overloaded = input.lastGpuTotalMs > budget * 0.92 || input.displayMissCount >= 2;

    if (input.thermalPressure || (input.onBattery && overloaded)) {
        return QualityMode::Q1_540Flow;
    }

    if (overloaded) {
        return is4K ? QualityMode::Q1_540Flow : QualityMode::Q2_720Flow;
    }

    if (is4K) {
        return QualityMode::Q2_720Flow;
    }

    return QualityMode::Q3_1080Flow;
}

MotionQualitySettings QualityController::ResolveSettings(const QualityInput& input) const {
    const QualityMode mode = ResolveMode(input);

    MotionQualitySettings settings;
    settings.targetFps = std::clamp(input.targetFps, 24.0, 240.0);
    settings.frameMultiplier = std::clamp(input.requestedMultiplier, 1.0, 8.0);
    settings.lineArtProtect = input.profile == ContentProfile::Anime;
    settings.subtitleProtect = input.profile == ContentProfile::Anime;
    settings.edgeAwareFlowUpscale = true;
    settings.refineEnabled = true;

    switch (mode) {
        case QualityMode::Q0_RepeatBlend:
            settings.flowInputHeight = 0;
            settings.edgeAwareFlowUpscale = false;
            settings.lineArtProtect = false;
            settings.subtitleProtect = false;
            settings.refineEnabled = false;
            break;
        case QualityMode::Q1_540Flow:
            settings.flowInputHeight = 540;
            settings.refineEnabled = false;
            break;
        case QualityMode::Q2_720Flow:
            settings.flowInputHeight = 720;
            settings.refineEnabled = input.profile == ContentProfile::Anime;
            break;
        case QualityMode::Q3_1080Flow:
            settings.flowInputHeight = 1080;
            break;
        case QualityMode::Q4_OfflineHQ:
            settings.flowInputHeight = input.sourceHeight >= 2160 ? 1440 : 1080;
            settings.offlineHighestQuality = true;
            settings.lineArtProtect = input.profile == ContentProfile::Anime;
            settings.subtitleProtect = true;
            settings.refineEnabled = true;
            break;
    }

    return settings;
}

} // namespace Stellaria::Motion

