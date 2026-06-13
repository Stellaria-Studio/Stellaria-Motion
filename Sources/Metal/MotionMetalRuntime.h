#pragma once

#include <string>

namespace Stellaria::Motion::Metal {

class Runtime {
public:
    Runtime();
    [[nodiscard]] bool IsAvailable() const;
    [[nodiscard]] std::string DeviceName() const;
    [[nodiscard]] bool HasTextureCache() const;
    [[nodiscard]] std::string OSVersionString() const;
    [[nodiscard]] std::string FeatureSummary() const;

private:
    void* device_ = nullptr;
    void* commandQueue_ = nullptr;
    void* textureCache_ = nullptr;
};

} // namespace Stellaria::Motion::Metal
