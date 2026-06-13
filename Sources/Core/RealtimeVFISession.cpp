#include "Core/RealtimeVFISession.h"

#include <algorithm>
#include <cmath>
#include <sstream>

namespace Stellaria::Motion {

namespace {

double ClampFPS(double fps) {
    if (!std::isfinite(fps)) {
        return 60.0;
    }
    return std::clamp(fps, 24.0, 240.0);
}

double ClampPreroll(double seconds) {
    if (!std::isfinite(seconds)) {
        return 0.12;
    }
    return std::clamp(seconds, 0.0, 0.5);
}

double ClampGap(double ms) {
    if (!std::isfinite(ms)) {
        return 16.67;
    }
    return std::clamp(ms, 4.0, 100.0);
}

} // namespace

RealtimeVFISession::RealtimeVFISession(RealtimeVFIConfig config) {
    Configure(config);
}

void RealtimeVFISession::Configure(const RealtimeVFIConfig& config) {
    config_ = config;
    config_.targetFPS = ClampFPS(config_.targetFPS);
    config_.prerollSeconds = ClampPreroll(config_.prerollSeconds);
    config_.maxVisibleFrameGapMs = ClampGap(config_.maxVisibleFrameGapMs);
    config_.maxPipelineLatencyMs = ClampGap(config_.maxPipelineLatencyMs);
    if (config_.flowInputHeight < 180) {
        config_.flowInputHeight = 180;
    }
    ResetClock();
}

const RealtimeVFIConfig& RealtimeVFISession::Config() const {
    return config_;
}

void RealtimeVFISession::ResetClock() {
    diagnostics_ = {};
    diagnostics_.browserStreamState = "idle";
    firstOutputTime_ = 0.0;
    lastOutputTime_ = 0.0;
    nextSendTime_ = 0.0;
    totalGapMs_ = 0.0;
    gapSamples_ = 0;
}

void RealtimeVFISession::NoteQueueDepth(uint32_t queuedFrames) {
    diagnostics_.queueSeconds = static_cast<double>(queuedFrames) / ClampFPS(config_.targetFPS);
}

void RealtimeVFISession::NotePipelineTiming(double rifeMs, double encodeMs) {
    if (std::isfinite(rifeMs) && rifeMs >= 0.0) {
        diagnostics_.rifeMs = rifeMs;
    }
    if (std::isfinite(encodeMs) && encodeMs >= 0.0) {
        diagnostics_.encodeMs = encodeMs;
    }
    diagnostics_.pipelineLatencyMs = diagnostics_.rifeMs + diagnostics_.encodeMs;
    diagnostics_.latencyStable = diagnostics_.pipelineLatencyMs <= config_.maxPipelineLatencyMs;
}

void RealtimeVFISession::NoteBrowserStreamState(const std::string& state) {
    diagnostics_.browserStreamState = state;
}

void RealtimeVFISession::NoteOutputFrame(double monotonicSeconds) {
    if (!std::isfinite(monotonicSeconds) || monotonicSeconds <= 0.0) {
        return;
    }
    if (firstOutputTime_ <= 0.0) {
        firstOutputTime_ = monotonicSeconds;
        lastOutputTime_ = monotonicSeconds;
        nextSendTime_ = monotonicSeconds + FrameIntervalSeconds();
        diagnostics_.outputFrames = 1;
        diagnostics_.cadenceStable = true;
        return;
    }

    const double gapMs = std::max(0.0, (monotonicSeconds - lastOutputTime_) * 1000.0);
    lastOutputTime_ = monotonicSeconds;
    diagnostics_.outputFrames += 1;
    diagnostics_.maxFrameGapMs = std::max(diagnostics_.maxFrameGapMs, gapMs);
    totalGapMs_ += gapMs;
    gapSamples_ += 1;
    diagnostics_.averageFrameGapMs = gapSamples_ > 0 ? totalGapMs_ / static_cast<double>(gapSamples_) : 0.0;
    const double elapsed = std::max(0.0001, monotonicSeconds - firstOutputTime_);
    diagnostics_.outputFPS = static_cast<double>(diagnostics_.outputFrames - 1) / elapsed;
    diagnostics_.cadenceStable = diagnostics_.maxFrameGapMs <= config_.maxVisibleFrameGapMs;
    nextSendTime_ = std::max(nextSendTime_ + FrameIntervalSeconds(), monotonicSeconds + FrameIntervalSeconds());
}

double RealtimeVFISession::FrameIntervalSeconds() const {
    return 1.0 / ClampFPS(config_.targetFPS);
}

bool RealtimeVFISession::HasEnoughPreroll() const {
    return diagnostics_.queueSeconds + 1.0e-6 >= config_.prerollSeconds;
}

double RealtimeVFISession::NextSendTime(double nowSeconds) const {
    if (nextSendTime_ <= 0.0) {
        return nowSeconds;
    }
    return nextSendTime_;
}

RealtimeVFIDiagnostics RealtimeVFISession::Diagnostics() const {
    return diagnostics_;
}

std::string RealtimeVFISession::Summary() const {
    std::ostringstream out;
    out << ToString(config_.backend)
        << " · " << ToString(config_.inputSource)
        << " · " << config_.targetFPS << "fps"
        << " · flow " << config_.flowInputHeight << "p"
        << " · queue " << diagnostics_.queueSeconds << "s"
        << " · gap " << diagnostics_.maxFrameGapMs << "ms"
        << " · latency " << diagnostics_.pipelineLatencyMs << "ms";
    return out.str();
}

const char* ToString(RealtimeInputSource source) {
    switch (source) {
        case RealtimeInputSource::LocalFile: return "local";
        case RealtimeInputSource::BrowserStream: return "browser-stream";
    }
    return "unknown";
}

const char* ToString(RealtimeRIFEBackend backend) {
    switch (backend) {
        case RealtimeRIFEBackend::MPSGraphFP16: return "MPSGraph FP16";
        case RealtimeRIFEBackend::MPSGraphFP32Debug: return "MPSGraph FP32 Debug";
        case RealtimeRIFEBackend::MetalInt4Experimental: return "Metal INT4 Experimental";
        case RealtimeRIFEBackend::StellariaSP4A1P: return "Stellaria SP4 A1P";
    }
    return "unknown";
}

const char* ToString(RealtimePowerTier tier) {
    switch (tier) {
        case RealtimePowerTier::Quiet: return "quiet";
        case RealtimePowerTier::Balanced: return "balanced";
        case RealtimePowerTier::Quality: return "quality";
        case RealtimePowerTier::Ultimate: return "ultimate";
    }
    return "unknown";
}

} // namespace Stellaria::Motion
