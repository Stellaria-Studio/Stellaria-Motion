#pragma once

#include "Core/MotionTypes.h"

namespace Stellaria::Motion {

struct QualityInput {
    MotionEntryMode entryMode = MotionEntryMode::LocalPlayback;
    ContentProfile profile = ContentProfile::Anime;
    uint32_t sourceWidth = 1920;
    uint32_t sourceHeight = 1080;
    double targetFps = 60.0;
    double requestedMultiplier = 2.0;
    double lastGpuTotalMs = 0.0;
    uint32_t displayMissCount = 0;
    bool offlineExport = false;
    bool sceneCut = false;
    bool duplicateFrame = false;
    bool thermalPressure = false;
    bool onBattery = false;
};

class QualityController {
public:
    MotionQualitySettings ResolveSettings(const QualityInput& input) const;
    QualityMode ResolveMode(const QualityInput& input) const;

private:
    static double FrameBudgetMs(double fps);
};

} // namespace Stellaria::Motion

