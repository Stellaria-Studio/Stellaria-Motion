#include "Video/MotionVideoSource.h"

#import <AVFoundation/AVFoundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

namespace Stellaria::Motion::Video {

SourceProbe ProbeLocalFile(const std::string& path) {
    NSString* nsPath = [NSString stringWithUTF8String:path.c_str()];
    NSURL* url = [NSURL fileURLWithPath:nsPath];
    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:url options:nil];

    SourceProbe probe;
    probe.kind = SourceKind::LocalFile;
    probe.supported = asset != nil;
    probe.reason = probe.supported ? "supported" : "failed to create AVURLAsset";
    return probe;
}

SourceProbe ProbeBrowserSource(const std::string& url, const std::string& src, bool protectedContent) {
    SourceProbe probe;
    probe.kind = SourceKind::ScreenCapture;
    probe.protectedContent = protectedContent;
    (void)url;

    if (protectedContent) {
        probe.supported = false;
        probe.reason = "DRM/protected media is unsupported";
        return probe;
    }

    const bool directMediaUrl = src.rfind("http://", 0) == 0 ||
                                src.rfind("https://", 0) == 0;
    const bool looksLikeManifest = src.find(".m3u8") != std::string::npos ||
                                   src.find(".mpd") != std::string::npos ||
                                   src.find(".mp4") != std::string::npos ||
                                   src.find(".mov") != std::string::npos;
    if (directMediaUrl && looksLikeManifest) {
        probe.kind = SourceKind::BrowserUrl;
        probe.supported = true;
        probe.reason = "candidate for native URL takeover";
        return probe;
    }
    probe.supported = ScreenCaptureAvailable();
    probe.reason = probe.supported ? "requires ScreenCaptureKit fallback" : "ScreenCaptureKit unavailable";
    return probe;
}

bool ScreenCaptureAvailable() {
    return NSClassFromString(@"SCStream") != nil;
}

} // namespace Stellaria::Motion::Video
