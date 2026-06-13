#include "Core/BrowserProtocol.h"
#include "Core/MotionQuality.h"
#include "Core/RenderGraph.h"
#include "VFI/MotionVFIPipeline.h"
#include "VFI/RIFEModelBackend.h"

#include <cassert>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

using namespace Stellaria::Motion;

namespace {

void TestRenderGraphOrdering() {
    RenderGraph graph;
    auto a = graph.CreateTransientResource({.name = "A", .sizeBytes = 4});
    auto b = graph.CreateTransientResource({.name = "B", .sizeBytes = 4});
    std::vector<std::string> order;

    graph.AddPass("write-a", {.writes = {a}}, [&] { order.push_back("write-a"); });
    graph.AddPass("read-a-write-b", {.reads = {a}, .writes = {b}}, [&] { order.push_back("read-a-write-b"); });
    graph.AddPass("read-b", {.reads = {b}}, [&] { order.push_back("read-b"); });

    assert(graph.Compile());
    MotionProfiler profiler;
    graph.Execute(&profiler);

    assert((order == std::vector<std::string>{"write-a", "read-a-write-b", "read-b"}));
    assert(profiler.Snapshot().size() == 3);
}

void TestQualityPolicy() {
    QualityController controller;

    auto realtime = controller.ResolveSettings(QualityInput{
        .sourceWidth = 1920,
        .sourceHeight = 1080,
        .targetFps = 60.0,
        .lastGpuTotalMs = 6.0});
    assert(realtime.flowInputHeight == 1080);
    assert(realtime.lineArtProtect);

    auto fourK = controller.ResolveSettings(QualityInput{
        .sourceWidth = 3840,
        .sourceHeight = 2160,
        .targetFps = 60.0,
        .lastGpuTotalMs = 8.0});
    assert(fourK.flowInputHeight == 720);

    auto sceneCut = controller.ResolveSettings(QualityInput{.sceneCut = true});
    assert(sceneCut.flowInputHeight == 0);
    assert(!sceneCut.refineEnabled);

    auto offline = controller.ResolveSettings(QualityInput{
        .sourceWidth = 3840,
        .sourceHeight = 2160,
        .offlineExport = true});
    assert(offline.offlineHighestQuality);
    assert(offline.flowInputHeight == 1440);
}

void TestBrowserProtocol() {
    BrowserVideoState state;
    state.tabId = 42;
    state.url = "https://example.test/watch";
    state.src = "https://cdn.example.test/video.m3u8";
    state.currentTime = 12.34;
    state.playbackRate = 1.25;
    state.paused = false;
    state.rect = {.x = 10, .y = 20, .width = 1280, .height = 720};
    state.fullscreen = true;

    const std::string json = SerializeBrowserVideoState(state);
    auto parsed = ParseBrowserVideoState(json);
    assert(parsed.has_value());
    assert(parsed->tabId == 42);
    assert(parsed->rect.width == 1280);
    assert(parsed->fullscreen);
    assert(!IsDrmOrProtectedSource(*parsed));

    parsed->src = "widevine://protected";
    assert(IsDrmOrProtectedSource(*parsed));
}

void TestVFIPipelineGraph() {
    RenderGraph graph;
    MotionVFIPipeline pipeline;
    VFIJob job;
    job.f0.width = 3840;
    job.f0.height = 2160;
    job.quality = QualityMode::Q2_720Flow;
    MotionQualitySettings settings;
    settings.flowInputHeight = 720;
    settings.lineArtProtect = true;
    settings.subtitleProtect = true;
    settings.refineEnabled = true;

    const auto diagnostics = pipeline.BuildGraph(graph, job, settings);
    assert(diagnostics.usedModelBackend);
    assert(!diagnostics.modelBackendReady);
    assert(diagnostics.modelBackendName == "NullModelBackend");
    assert(graph.Compile());
    assert(!diagnostics.passNames.empty());
    assert(!diagnostics.kernelNames.empty());
    assert(diagnostics.passNames.front() == "YUVPack");
    assert(diagnostics.kernelNames.front() == "fused_yuv420_to_rgb16f_resize_normalize");
    assert(diagnostics.passNames.back() == "Present");
    assert(diagnostics.kernelNames.back() == "present_stub");
}

void TestRIFEBackendDiagnostics() {
    const auto temp = std::filesystem::temp_directory_path() / "stellaria-rife-test.safetensors";
    const std::string header = R"({"block0.conv.weight":{"dtype":"F32","shape":[1],"data_offsets":[0,4]},"block3.conv.weight":{"dtype":"F32","shape":[1],"data_offsets":[4,8]}})";
    {
        std::ofstream out(temp, std::ios::binary);
        uint64_t headerBytes = header.size();
        out.write(reinterpret_cast<const char*>(&headerBytes), sizeof(headerBytes));
        out.write(header.data(), static_cast<std::streamsize>(header.size()));
        const uint64_t payload = 0;
        out.write(reinterpret_cast<const char*>(&payload), sizeof(payload));
    }

    RIFEModelBackend backend(temp);
    assert(backend.IsReady());
    assert(backend.TensorCount() == 2);
    assert(backend.Diagnostics().find("tensors=2") != std::string::npos);

    RenderGraph graph;
    MotionVFIPipeline pipeline(&backend);
    VFIJob job;
    job.f0.width = 1920;
    job.f0.height = 1080;
    MotionQualitySettings settings;
    settings.flowInputHeight = 540;
    const auto diagnostics = pipeline.BuildGraph(graph, job, settings);
    assert(diagnostics.modelBackendReady);
    assert(diagnostics.modelBackendName == "RIFEModelBackend");

    std::filesystem::remove(temp);
}

} // namespace

int main() {
    TestRenderGraphOrdering();
    TestQualityPolicy();
    TestBrowserProtocol();
    TestVFIPipelineGraph();
    TestRIFEBackendDiagnostics();
    return 0;
}
