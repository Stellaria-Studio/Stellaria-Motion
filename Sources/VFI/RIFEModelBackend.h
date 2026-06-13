#pragma once

#include "VFI/MotionVFIPipeline.h"

#include <filesystem>
#include <string>

namespace Stellaria::Motion {

class RIFEModelBackend final : public IMFBackend {
public:
    explicit RIFEModelBackend(std::filesystem::path modelPath);

    [[nodiscard]] std::string Name() const override;
    [[nodiscard]] bool IsReady() const override;
    [[nodiscard]] std::string Diagnostics() const override;
    void EnqueueFlowInference(const VFIJob& job) override;

    [[nodiscard]] uint32_t TensorCount() const { return tensorCount_; }
    [[nodiscard]] uint64_t ModelBytes() const { return modelBytes_; }

private:
    void InspectSafetensors();

    std::filesystem::path modelPath_;
    std::string diagnostics_;
    uint32_t tensorCount_ = 0;
    uint64_t modelBytes_ = 0;
    bool ready_ = false;
};

} // namespace Stellaria::Motion
