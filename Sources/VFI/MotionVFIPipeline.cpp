#include "VFI/MotionVFIPipeline.h"

namespace Stellaria::Motion {

std::string NullModelBackend::Name() const {
    return "NullModelBackend";
}

bool NullModelBackend::IsReady() const {
    return false;
}

std::string NullModelBackend::Diagnostics() const {
    return "model backend not configured";
}

void NullModelBackend::EnqueueFlowInference(const VFIJob&) {
}

MotionVFIPipeline::MotionVFIPipeline(IMFBackend* backend)
    : backend_(backend != nullptr ? backend : &nullBackend_) {
}

VFIPipelineDiagnostics MotionVFIPipeline::BuildGraph(RenderGraph& graph,
                                                     const VFIJob& job,
                                                     const MotionQualitySettings& settings) {
    VFIPipelineDiagnostics diagnostics;
    diagnostics.quality = job.quality;
    diagnostics.modelBackendName = backend_->Name();
    diagnostics.modelBackendReady = backend_->IsReady();
    diagnostics.modelBackendDiagnostics = backend_->Diagnostics();

    auto source = graph.ImportResource(ResourceDesc{
        .name = "ImportedFramePair",
        .width = job.f0.width,
        .height = job.f0.height,
        .format = "NV12/P010",
        .externalPtr = job.f0.pixelBuffer});

    auto packed = graph.CreateTransientResource(ResourceDesc{
        .name = "PackedRGB16F",
        .width = job.f0.width,
        .height = job.f0.height,
        .format = "RGBA16F"});

    graph.AddPass("YUVPack", {.reads = {source}, .writes = {packed}}, [] {});
    diagnostics.passNames.push_back("YUVPack");
    diagnostics.kernelNames.push_back("fused_yuv420_to_rgb16f_resize_normalize");

    auto detect = graph.CreateTransientResource(ResourceDesc{
        .name = "DetectionStats",
        .sizeBytes = 256,
        .format = "Stats"});
    graph.AddPass("SceneCutDetect", {.reads = {packed}, .writes = {detect}}, [] {});
    graph.AddPass("DuplicateDetect", {.reads = {packed}, .writes = {detect}}, [] {});
    diagnostics.passNames.push_back("SceneCutDetect");
    diagnostics.passNames.push_back("DuplicateDetect");
    diagnostics.kernelNames.push_back("fused_scene_duplicate_stats");

    if (settings.flowInputHeight == 0) {
        graph.AddPass("Present", {.reads = {packed}, .writes = {}}, [] {});
        diagnostics.passNames.push_back("Present");
        diagnostics.kernelNames.push_back("present_stub");
        return diagnostics;
    }

    const uint32_t flowWidth = job.f0.height == 0
        ? settings.flowInputHeight
        : static_cast<uint32_t>(settings.flowInputHeight * job.f0.width / job.f0.height);

    auto pyramid = graph.CreateTransientResource(ResourceDesc{
        .name = "FlowInputPyramid",
        .width = flowWidth,
        .height = settings.flowInputHeight,
        .format = "RGBA16F"});
    graph.AddPass("DownsamplePyramid", {.reads = {packed}, .writes = {pyramid}}, [] {});
    diagnostics.passNames.push_back("DownsamplePyramid");
    diagnostics.kernelNames.push_back("fused_yuv420_to_rgb16f_resize_normalize");

    auto lowResFlow = graph.CreateTransientResource(ResourceDesc{
        .name = "LowResFlowMask",
        .width = flowWidth,
        .height = settings.flowInputHeight,
        .format = "RG16F+R16F"});
    graph.AddPass("FlowInference", {.reads = {pyramid}, .writes = {lowResFlow}}, [this, job] {
        backend_->EnqueueFlowInference(job);
    });
    diagnostics.usedModelBackend = true;
    diagnostics.modelBackendName = backend_->Name();
    diagnostics.modelBackendReady = backend_->IsReady();
    diagnostics.modelBackendDiagnostics = backend_->Diagnostics();
    diagnostics.passNames.push_back("FlowInference");
    diagnostics.kernelNames.push_back(backend_->Name());

    auto highResFlow = graph.CreateTransientResource(ResourceDesc{
        .name = "HighResFlowMask",
        .width = job.f0.width,
        .height = job.f0.height,
        .format = "RG16F+R16F"});
    graph.AddPass("FlowUpscale", {.reads = {lowResFlow, packed}, .writes = {highResFlow}}, [] {});
    diagnostics.passNames.push_back("FlowUpscale");
    diagnostics.kernelNames.push_back("fused_flow_upscale_edge_aware");

    auto warped = graph.CreateTransientResource(ResourceDesc{
        .name = "WarpedRGBA16F",
        .width = job.f0.width,
        .height = job.f0.height,
        .format = "RGBA16F"});
    graph.AddPass("BackwardWarp", {.reads = {packed, highResFlow}, .writes = {warped}}, [] {});
    graph.AddPass("OcclusionBlend", {.reads = {warped, highResFlow}, .writes = {warped}}, [] {});
    diagnostics.passNames.push_back("BackwardWarp");
    diagnostics.passNames.push_back("OcclusionBlend");
    diagnostics.kernelNames.push_back("fused_warp_occlusion_protect_refine");

    if (settings.lineArtProtect) {
        graph.AddPass("LineArtProtect", {.reads = {packed, warped}, .writes = {warped}}, [] {});
        diagnostics.passNames.push_back("LineArtProtect");
        diagnostics.kernelNames.push_back("fused_warp_occlusion_protect_refine");
    }

    if (settings.subtitleProtect) {
        graph.AddPass("SubtitleProtect", {.reads = {packed, warped}, .writes = {warped}}, [] {});
        diagnostics.passNames.push_back("SubtitleProtect");
        diagnostics.kernelNames.push_back("fused_warp_occlusion_protect_refine");
    }

    if (settings.refineEnabled) {
        graph.AddPass("Refine", {.reads = {warped}, .writes = {warped}}, [] {});
        diagnostics.passNames.push_back("Refine");
        diagnostics.kernelNames.push_back("fused_warp_occlusion_protect_refine");
    }

    graph.AddPass("Present", {.reads = {warped}, .writes = {}}, [] {});
    diagnostics.passNames.push_back("Present");
    diagnostics.kernelNames.push_back("present_stub");
    return diagnostics;
}

} // namespace Stellaria::Motion
