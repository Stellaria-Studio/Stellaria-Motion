#pragma once

#include <cstdint>
#include <optional>
#include <string>

namespace Stellaria::Motion {

struct VideoRect {
    double x = 0.0;
    double y = 0.0;
    double width = 0.0;
    double height = 0.0;
};

struct BrowserVideoState {
    std::string type = "video_state";
    int64_t tabId = 0;
    std::string url;
    std::string src;
    double sentAtMs = 0.0;
    double currentTime = 0.0;
    double playbackRate = 1.0;
    bool paused = true;
    double readyState = 0.0;
    double videoWidth = 0.0;
    double videoHeight = 0.0;
    VideoRect rect;
    bool fullscreen = false;
    bool protectedContent = false;
    bool encrypted = false;
    std::string agentVersion;
    std::string overlayFrameSource;
    std::string overlayLastDrawError;
    double overlayInputFPS = 0.0;
    double overlayOutputFPS = 0.0;
    double overlayProcessedFrames = 0.0;
};

std::string SerializeBrowserVideoState(const BrowserVideoState& state);
std::optional<BrowserVideoState> ParseBrowserVideoState(const std::string& json);
bool IsDrmOrProtectedSource(const BrowserVideoState& state);

} // namespace Stellaria::Motion
