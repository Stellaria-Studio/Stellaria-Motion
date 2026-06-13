#include "Core/RenderGraph.h"

#include <algorithm>
#include <queue>
#include <stdexcept>

namespace Stellaria::Motion {

ResourceHandle RenderGraph::CreateTransientResource(ResourceDesc desc) {
    desc.externalPtr = nullptr;
    const ResourceHandle handle{nextResourceId_++};
    resources_.push_back(std::move(desc));
    resourceHandles_.push_back(handle);
    return handle;
}

ResourceHandle RenderGraph::ImportResource(ResourceDesc desc) {
    const ResourceHandle handle{nextResourceId_++};
    resources_.push_back(std::move(desc));
    resourceHandles_.push_back(handle);
    return handle;
}

void* RenderGraph::ExportResource(ResourceHandle handle) const {
    const ResourceDesc* desc = GetResource(handle);
    return desc != nullptr ? desc->externalPtr : nullptr;
}

void RenderGraph::AddPass(std::string name, PassDependency deps, std::function<void()> execute) {
    passes_.push_back(RenderGraphPass{
        .name = std::move(name),
        .deps = std::move(deps),
        .execute = std::move(execute)});
}

bool RenderGraph::Compile() {
    compiled_.clear();

    const size_t n = passes_.size();
    std::vector<std::vector<size_t>> edges(n);
    std::vector<uint32_t> indegree(n, 0);
    std::unordered_map<ResourceHandle, size_t> lastWriter;

    for (size_t i = 0; i < n; ++i) {
        auto addEdge = [&](size_t from, size_t to) {
            if (from == to) {
                return;
            }
            if (std::find(edges[from].begin(), edges[from].end(), to) == edges[from].end()) {
                edges[from].push_back(to);
                ++indegree[to];
            }
        };

        for (const auto read : passes_[i].deps.reads) {
            const auto writer = lastWriter.find(read);
            if (writer != lastWriter.end()) {
                addEdge(writer->second, i);
            }
        }

        for (const auto write : passes_[i].deps.writes) {
            const auto writer = lastWriter.find(write);
            if (writer != lastWriter.end()) {
                addEdge(writer->second, i);
            }
            lastWriter[write] = i;
        }
    }

    std::queue<size_t> ready;
    std::vector<uint32_t> level(n, 0);
    for (size_t i = 0; i < n; ++i) {
        if (indegree[i] == 0) {
            ready.push(i);
        }
    }

    while (!ready.empty()) {
        const size_t current = ready.front();
        ready.pop();
        compiled_.push_back(CompiledPass{.name = passes_[current].name, .executionLevel = level[current]});

        for (const size_t next : edges[current]) {
            level[next] = std::max(level[next], level[current] + 1);
            if (--indegree[next] == 0) {
                ready.push(next);
            }
        }
    }

    return compiled_.size() == passes_.size();
}

void RenderGraph::Execute(MotionProfiler* profiler) const {
    if (compiled_.size() != passes_.size()) {
        throw std::logic_error("RenderGraph must be compiled before Execute");
    }

    for (const auto& compiledPass : compiled_) {
        const auto found = std::find_if(
            passes_.begin(),
            passes_.end(),
            [&](const RenderGraphPass& pass) { return pass.name == compiledPass.name; });
        if (found == passes_.end()) {
            continue;
        }

        if (profiler != nullptr) {
            profiler->BeginPass(found->name);
        }
        if (found->execute) {
            found->execute();
        }
        if (profiler != nullptr) {
            profiler->EndPass(found->name);
        }
    }
}

void RenderGraph::Clear() {
    nextResourceId_ = 1;
    resources_.clear();
    resourceHandles_.clear();
    passes_.clear();
    compiled_.clear();
}

const std::vector<CompiledPass>& RenderGraph::CompiledPasses() const {
    return compiled_;
}

const ResourceDesc* RenderGraph::GetResource(ResourceHandle handle) const {
    for (size_t i = 0; i < resourceHandles_.size(); ++i) {
        if (resourceHandles_[i] == handle) {
            return &resources_[i];
        }
    }
    return nullptr;
}

} // namespace Stellaria::Motion

