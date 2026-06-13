#include "Core/MotionProfiler.h"

#include <algorithm>

namespace Stellaria::Motion {

void MotionProfiler::BeginPass(std::string_view name) {
    active_[std::string(name)] = std::chrono::steady_clock::now();
}

void MotionProfiler::EndPass(std::string_view name) {
    const std::string key(name);
    const auto found = active_.find(key);
    if (found == active_.end()) {
        return;
    }

    const auto end = std::chrono::steady_clock::now();
    const double elapsedMs = std::chrono::duration<double, std::milli>(end - found->second).count();
    records_.push_back(PassProfileRecord{.name = key, .elapsedMs = elapsedMs});
    active_.erase(found);
}

void MotionProfiler::AddRecord(PassProfileRecord record) {
    records_.push_back(std::move(record));
}

std::vector<PassProfileRecord> MotionProfiler::Snapshot() const {
    return records_;
}

double MotionProfiler::TotalMs() const {
    double total = 0.0;
    for (const auto& record : records_) {
        total += std::max(0.0, record.elapsedMs);
    }
    return total;
}

void MotionProfiler::Reset() {
    active_.clear();
    records_.clear();
}

} // namespace Stellaria::Motion

