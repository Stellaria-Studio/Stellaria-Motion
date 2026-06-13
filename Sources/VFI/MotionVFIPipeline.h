#pragma once

#include "Core/MotionQuality.h"
#include "Core/RenderGraph.h"

#include <string>
#include <vector>

namespace Stellaria::Motion {

struct VFIPipelineDiagnostics {
    std::vector<std::string> passNames;
    std::vector<std::string> kernelNames;
    std::string modelBackendName;
    std::string modelBackendDiagnostics;
    QualityMode quality = QualityMode::Q2_720Flow;
    bool usedModelBackend = false;
    bool modelBackendReady = false;
    bool drmRejected = false;
};

class IMFBackend {
public:
    virtual ~IMFBackend() = default;
    [[nodiscard]] virtual std::string Name() const = 0;
    [[nodiscard]] virtual bool IsReady() const = 0;
    [[nodiscard]] virtual std::string Diagnostics() const = 0;
    virtual void EnqueueFlowInference(const VFIJob& job) = 0;
};

class NullModelBackend final : public IMFBackend {
public:
    [[nodiscard]] std::string Name() const override;
    [[nodiscard]] bool IsReady() const override;
    [[nodiscard]] std::string Diagnostics() const override;
    void EnqueueFlowInference(const VFIJob& job) override;
};

class MotionVFIPipeline {
public:
    explicit MotionVFIPipeline(IMFBackend* backend = nullptr);

    VFIPipelineDiagnostics BuildGraph(RenderGraph& graph,
                                      const VFIJob& job,
                                      const MotionQualitySettings& settings);

private:
    IMFBackend* backend_ = nullptr;
    NullModelBackend nullBackend_;
};

} // namespace Stellaria::Motion
