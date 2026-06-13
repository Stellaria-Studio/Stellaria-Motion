#pragma once

#include <chrono>
#include <cstdint>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace Stellaria::Motion {

struct PassProfileRecord {
    std::string name;
    double elapsedMs = 0.0;
    uint32_t inputWidth = 0;
    uint32_t inputHeight = 0;
    uint32_t outputWidth = 0;
    uint32_t outputHeight = 0;
    std::string textureFormat;
    std::string dispatchSize;
};

class MotionProfiler {
public:
    void BeginPass(std::string_view name);
    void EndPass(std::string_view name);
    void AddRecord(PassProfileRecord record);
    [[nodiscard]] std::vector<PassProfileRecord> Snapshot() const;
    [[nodiscard]] double TotalMs() const;
    void Reset();

private:
    std::unordered_map<std::string, std::chrono::steady_clock::time_point> active_;
    std::vector<PassProfileRecord> records_;
};

} // namespace Stellaria::Motion

