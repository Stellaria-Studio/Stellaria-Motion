#pragma once

#include <cstdint>
#include <string>

namespace Stellaria::Motion {

enum class RealtimeInputSource : uint8_t {
    LocalFile,
    BrowserStream
};

enum class RealtimeRIFEBackend : uint8_t {
    MPSGraphFP16,
    MPSGraphFP32Debug,
    MetalInt4Experimental,
    StellariaSP4A1P
};

enum class RealtimePowerTier : uint8_t {
    Quiet,
    Balanced,
    Quality,
    Ultimate
};

struct RealtimeVFIConfig {
    RealtimeInputSource inputSource = RealtimeInputSource::LocalFile;
    RealtimeRIFEBackend backend = RealtimeRIFEBackend::MPSGraphFP16;
    RealtimePowerTier powerTier = RealtimePowerTier::Balanced;
    double targetFPS = 60.0;
    uint32_t flowInputHeight = 540;
    double prerollSeconds = 0.12;
    double maxVisibleFrameGapMs = 16.67;
    double maxPipelineLatencyMs = 16.67;
};

struct RealtimeVFIDiagnostics {
    double outputFPS = 0.0;
    double maxFrameGapMs = 0.0;
    double averageFrameGapMs = 0.0;
    double queueSeconds = 0.0;
    double rifeMs = 0.0;
    double encodeMs = 0.0;
    double pipelineLatencyMs = 0.0;
    uint64_t outputFrames = 0;
    bool cadenceStable = false;
    bool latencyStable = true;
    std::string browserStreamState;
};

class RealtimeVFISession {
public:
    explicit RealtimeVFISession(RealtimeVFIConfig config = {});

    void Configure(const RealtimeVFIConfig& config);
    [[nodiscard]] const RealtimeVFIConfig& Config() const;

    void ResetClock();
    void NoteQueueDepth(uint32_t queuedFrames);
    void NotePipelineTiming(double rifeMs, double encodeMs);
    void NoteBrowserStreamState(const std::string& state);
    void NoteOutputFrame(double monotonicSeconds);

    [[nodiscard]] double FrameIntervalSeconds() const;
    [[nodiscard]] bool HasEnoughPreroll() const;
    [[nodiscard]] double NextSendTime(double nowSeconds) const;
    [[nodiscard]] RealtimeVFIDiagnostics Diagnostics() const;
    [[nodiscard]] std::string Summary() const;

private:
    RealtimeVFIConfig config_;
    RealtimeVFIDiagnostics diagnostics_;
    double firstOutputTime_ = 0.0;
    double lastOutputTime_ = 0.0;
    double nextSendTime_ = 0.0;
    double totalGapMs_ = 0.0;
    uint64_t gapSamples_ = 0;
};

const char* ToString(RealtimeInputSource source);
const char* ToString(RealtimeRIFEBackend backend);
const char* ToString(RealtimePowerTier tier);

} // namespace Stellaria::Motion
