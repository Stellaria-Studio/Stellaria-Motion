#pragma once

#include <cstdint>
#include <string>

namespace Stellaria::Motion {

struct RIFEMetal4BitRunResult {
    bool ok = false;
    std::string message;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t modelWidth = 0;
    uint32_t modelHeight = 0;
    double elapsedMs = 0.0;
};

class RIFEMetal4BitRunner {
public:
    RIFEMetal4BitRunner();
    ~RIFEMetal4BitRunner();

    RIFEMetal4BitRunner(const RIFEMetal4BitRunner&) = delete;
    RIFEMetal4BitRunner& operator=(const RIFEMetal4BitRunner&) = delete;

    void SetCommandQueue(void* commandQueue);
    bool Load(const std::string& modelPath, uint32_t modelWidth, uint32_t modelHeight);
    [[nodiscard]] bool IsReady() const;
    [[nodiscard]] std::string Diagnostics() const;

    RIFEMetal4BitRunResult RunTextures(void* previousTexture,
                                       void* currentTexture,
                                       void* outputTexture,
                                       uint32_t sourceWidth,
                                       uint32_t sourceHeight);
    RIFEMetal4BitRunResult RunTexturesAtT(void* previousTexture,
                                          void* currentTexture,
                                          void* outputTexture,
                                          uint32_t sourceWidth,
                                          uint32_t sourceHeight,
                                          float t);

private:
    void* impl_ = nullptr;
};

} // namespace Stellaria::Motion
