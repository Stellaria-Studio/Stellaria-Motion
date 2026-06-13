#pragma once

#include "VFI/RIFEMPSGraphRunner.h"

#include <cstdint>
#include <string>

namespace Stellaria::Motion {

class RIFECoreMLRunner {
public:
    RIFECoreMLRunner();
    ~RIFECoreMLRunner();

    RIFECoreMLRunner(const RIFECoreMLRunner&) = delete;
    RIFECoreMLRunner& operator=(const RIFECoreMLRunner&) = delete;

    bool Load(const std::string& modelPath, uint32_t width, uint32_t height);
    [[nodiscard]] bool IsReady() const;
    [[nodiscard]] std::string Diagnostics() const;

    RIFEMPSGraphRunResult RunWithBuffers(void* inputMTLBuffer, void* outputMTLBuffer);

private:
    void* impl_ = nullptr;
};

class RIFECoreMLBlockRunner {
public:
    RIFECoreMLBlockRunner();
    ~RIFECoreMLBlockRunner();

    RIFECoreMLBlockRunner(const RIFECoreMLBlockRunner&) = delete;
    RIFECoreMLBlockRunner& operator=(const RIFECoreMLBlockRunner&) = delete;

    bool Load(const std::string& modelPath, uint32_t width, uint32_t height);
    [[nodiscard]] bool IsReady() const;
    [[nodiscard]] std::string Diagnostics() const;

    RIFEMPSGraphRunResult RunWithBuffers(void* xMTLBuffer, void* flowMTLBuffer, void* outputMTLBuffer);

private:
    void* impl_ = nullptr;
};

class RIFECoreMLFlowMaskRunner {
public:
    RIFECoreMLFlowMaskRunner();
    ~RIFECoreMLFlowMaskRunner();

    RIFECoreMLFlowMaskRunner(const RIFECoreMLFlowMaskRunner&) = delete;
    RIFECoreMLFlowMaskRunner& operator=(const RIFECoreMLFlowMaskRunner&) = delete;

    bool Load(const std::string& modelPath, uint32_t width, uint32_t height);
    [[nodiscard]] bool IsReady() const;
    [[nodiscard]] std::string Diagnostics() const;

    RIFEMPSGraphRunResult RunWithBuffers(void* inputMTLBuffer, void* outputMTLBuffer);

private:
    void* impl_ = nullptr;
};

} // namespace Stellaria::Motion
