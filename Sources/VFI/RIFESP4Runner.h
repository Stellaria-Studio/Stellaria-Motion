#pragma once

#include "VFI/RIFEMetal4BitRunner.h"

#include <cstdint>
#include <string>

namespace Stellaria::Motion {

using RIFESP4RunResult = RIFEMetal4BitRunResult;

class RIFESP4Runner {
public:
    RIFESP4Runner();
    ~RIFESP4Runner();

    RIFESP4Runner(const RIFESP4Runner&) = delete;
    RIFESP4Runner& operator=(const RIFESP4Runner&) = delete;

    void SetCommandQueue(void* commandQueue);
    bool Load(const std::string& modelPath, uint32_t modelWidth, uint32_t modelHeight);
    [[nodiscard]] bool IsReady() const;
    [[nodiscard]] std::string Diagnostics() const;

    RIFESP4RunResult RunTextures(void* previousTexture,
                                 void* currentTexture,
                                 void* outputTexture,
                                 uint32_t sourceWidth,
                                 uint32_t sourceHeight);
    RIFESP4RunResult RunTexturesAtT(void* previousTexture,
                                    void* currentTexture,
                                    void* outputTexture,
                                    uint32_t sourceWidth,
                                    uint32_t sourceHeight,
                                    float t);
    RIFESP4RunResult RunTexturesAtTValues(void* previousTexture,
                                          void* currentTexture,
                                          void* const* outputTextures,
                                          const float* tValues,
                                          uint32_t outputCount,
                                          uint32_t sourceWidth,
                                          uint32_t sourceHeight);

private:
    void* impl_ = nullptr;
};

} // namespace Stellaria::Motion
