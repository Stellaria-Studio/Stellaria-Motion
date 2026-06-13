#pragma once

#include <string>

namespace Stellaria::Motion::Video {

enum class SourceKind {
    LocalFile,
    BrowserUrl,
    ScreenCapture
};

struct SourceProbe {
    bool supported = false;
    bool protectedContent = false;
    SourceKind kind = SourceKind::LocalFile;
    std::string reason;
};

SourceProbe ProbeLocalFile(const std::string& path);
SourceProbe ProbeBrowserSource(const std::string& url, const std::string& src, bool protectedContent);
bool ScreenCaptureAvailable();

} // namespace Stellaria::Motion::Video

