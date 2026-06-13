#pragma once

#include "Core/MotionProfiler.h"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace Stellaria::Motion {

struct ResourceHandle {
    uint32_t id = 0;

    friend bool operator==(ResourceHandle lhs, ResourceHandle rhs) {
        return lhs.id == rhs.id;
    }
};

struct ResourceDesc {
    std::string name;
    size_t sizeBytes = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    std::string format;
    void* externalPtr = nullptr;
};

struct PassDependency {
    std::vector<ResourceHandle> reads;
    std::vector<ResourceHandle> writes;
};

struct RenderGraphPass {
    std::string name;
    PassDependency deps;
    std::function<void()> execute;
};

struct CompiledPass {
    std::string name;
    uint32_t executionLevel = 0;
};

class RenderGraph {
public:
    ResourceHandle CreateTransientResource(ResourceDesc desc);
    ResourceHandle ImportResource(ResourceDesc desc);
    void* ExportResource(ResourceHandle handle) const;

    void AddPass(std::string name, PassDependency deps, std::function<void()> execute);
    [[nodiscard]] bool Compile();
    void Execute(MotionProfiler* profiler = nullptr) const;
    void Clear();

    [[nodiscard]] const std::vector<CompiledPass>& CompiledPasses() const;
    [[nodiscard]] const ResourceDesc* GetResource(ResourceHandle handle) const;

private:
    uint32_t nextResourceId_ = 1;
    std::vector<ResourceDesc> resources_;
    std::vector<ResourceHandle> resourceHandles_;
    std::vector<RenderGraphPass> passes_;
    std::vector<CompiledPass> compiled_;
};

} // namespace Stellaria::Motion

namespace std {
template <>
struct hash<Stellaria::Motion::ResourceHandle> {
    size_t operator()(Stellaria::Motion::ResourceHandle handle) const noexcept {
        return std::hash<uint32_t>{}(handle.id);
    }
};
} // namespace std

