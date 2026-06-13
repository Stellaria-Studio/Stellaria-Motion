#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace Stellaria::Motion {

struct RIFEMPSGraphRunResult {
    bool ok = false;
    std::string message;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t outputChannels = 0;
    double elapsedMs = 0.0;
};

class RIFEMPSGraphRunner {
public:
    RIFEMPSGraphRunner();
    ~RIFEMPSGraphRunner();

    RIFEMPSGraphRunner(const RIFEMPSGraphRunner&) = delete;
    RIFEMPSGraphRunner& operator=(const RIFEMPSGraphRunner&) = delete;

    bool Load(const std::string& modelPath, uint32_t width, uint32_t height);
    [[nodiscard]] bool IsReady() const;
    [[nodiscard]] std::string Diagnostics() const;
    [[nodiscard]] bool HasMetal4MachineLearningAPI() const;

    void SetCommandQueue(void* commandQueue);
    RIFEMPSGraphRunResult RunZeroInput();
    RIFEMPSGraphRunResult RunWithBuffers(void* inputMTLBuffer, void* outputMTLBuffer);

private:
    void* impl_ = nullptr;
};

} // namespace Stellaria::Motion
