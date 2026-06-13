#include "VFI/RIFESP4Runner.h"

#include "sp4/SP4Compiler.h"
#include "sp4/SP4Runtime.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <filesystem>
#include <sstream>
#include <string>
#include <vector>

namespace {

struct SMMIF4Params {
    uint32_t width;
    uint32_t height;
    uint32_t modelWidth;
    uint32_t modelHeight;
    uint32_t layerCount;
    uint32_t graphTensorCount;
    uint32_t activeBlockCount;
    uint32_t reserved0;
    float flowGain;
    float nativeBlend;
    float t;
    float reserved1;
};

struct SMSP4RefineParams {
    uint32_t width;
    uint32_t height;
    uint32_t modelWidth;
    uint32_t modelHeight;
    float residualStrength;
    float temporalProtect;
    float edgeProtect;
    float t;
};

struct SMSP4LayerPlanCPU {
    uint32_t qweightOffsetBytes = 0;
    uint32_t scaleOffset = 0;
    uint32_t modeOffset = 0;
    uint32_t auxOffset = 0;
    uint32_t residualTableOffset = 0;
    uint32_t residualIndexOffset = 0;
    uint32_t residualValueOffset = 0;
    uint32_t blockSize = 0;
    uint32_t blockCount = 0;
    uint32_t inputChannels = 0;
    uint32_t outputChannels = 0;
    uint32_t kernelWidth = 0;
    uint32_t kernelHeight = 0;
    uint32_t activationScaleOffset = 0;
    uint32_t flags = 0;
    uint32_t reserved0 = 0;
    uint32_t reserved1 = 0;
};

struct SMSP4PreparedLayerPlanCPU {
    uint32_t sourceLayerIndex = 0;
    uint32_t weightOffset = 0;
    uint32_t weightCount = 0;
    uint32_t biasOffset = 0;
    uint32_t biasCount = 0;
    uint32_t inputChannels = 0;
    uint32_t outputChannels = 0;
    uint32_t kernelWidth = 1;
    uint32_t kernelHeight = 1;
    uint32_t flags = 0;
};

NSURL* SMMotionKernelsURL() {
    NSURL* bundled = [[NSBundle mainBundle] URLForResource:@"MotionKernels" withExtension:@"metallib"];
    if (bundled != nil) {
        return bundled;
    }
    NSFileManager* fs = NSFileManager.defaultManager;
    NSArray<NSString*>* candidates = @[
        @"MotionKernels.metallib",
        @"build-app/MotionKernels.metallib",
        @"../build-app/MotionKernels.metallib"
    ];
    for (NSString* path in candidates) {
        if ([fs fileExistsAtPath:path]) {
            return [NSURL fileURLWithPath:path];
        }
    }
    return nil;
}

MTLSize SMThreadgroup(id<MTLComputePipelineState> pipeline) {
    const NSUInteger width = std::max<NSUInteger>(1, pipeline.threadExecutionWidth);
    const NSUInteger height = std::max<NSUInteger>(1, pipeline.maxTotalThreadsPerThreadgroup / width);
    return MTLSizeMake(width, height, 1);
}

id<MTLBuffer> SMMakePrivateBuffer(id<MTLDevice> device, id<MTLCommandQueue> queue, const void* data, size_t bytes) {
    if (device == nil || queue == nil || data == nullptr || bytes == 0) {
        return nil;
    }
    id<MTLBuffer> staging = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [device newBufferWithLength:bytes options:MTLResourceStorageModePrivate];
    if (staging == nil || out == nil) {
        return nil;
    }
    std::memcpy(staging.contents, data, bytes);
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    [blit copyFromBuffer:staging sourceOffset:0 toBuffer:out destinationOffset:0 size:bytes];
    [blit endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    return commandBuffer.status == MTLCommandBufferStatusCompleted ? out : nil;
}

template <typename T>
id<MTLBuffer> SMMakeVectorBuffer(id<MTLDevice> device, id<MTLCommandQueue> queue, const std::vector<T>& values) {
    return values.empty() ? nil : SMMakePrivateBuffer(device, queue, values.data(), values.size() * sizeof(T));
}

std::filesystem::path SMExistingPath(std::initializer_list<std::filesystem::path> candidates) {
    for (const std::filesystem::path& path : candidates) {
        if (!path.empty() && std::filesystem::exists(path)) {
            return path;
        }
    }
    return {};
}

std::filesystem::path SMBundledSP4AssetPath() {
    NSURL* bundled = [[NSBundle mainBundle] URLForResource:@"rife_sp4_a1p"
                                             withExtension:@"sp4"
                                              subdirectory:@"Models/RIFE-SP4"];
    if (bundled != nil) {
        return std::filesystem::path(bundled.path.UTF8String);
    }
    return {};
}

std::filesystem::path SMDefaultSP4AssetPath(const std::string& modelPath) {
    const std::filesystem::path input(modelPath);
    if (input.extension() == ".sp4" && std::filesystem::exists(input)) {
        return input;
    }
    std::filesystem::path compiledAsset;
#ifdef STELLARIA_SP4_DEFAULT_ASSET
    compiledAsset = std::filesystem::path(STELLARIA_SP4_DEFAULT_ASSET);
#endif
    return SMExistingPath({
        SMBundledSP4AssetPath(),
        std::filesystem::current_path() / "Models/RIFE-SP4/rife_sp4_a1p.sp4",
        std::filesystem::current_path().parent_path() / "Models/RIFE-SP4/rife_sp4_a1p.sp4",
        compiledAsset,
        std::filesystem::path("/Users/minsawa/Documents/Stellaria SP4/build/rife_sp4_a1p.sp4"),
    });
}

std::filesystem::path SMCompileSP4AssetIfNeeded(const std::string& modelPath, std::string* message) {
    const std::filesystem::path existing = SMDefaultSP4AssetPath(modelPath);
    if (!existing.empty()) {
        return existing;
    }
    const std::filesystem::path input(modelPath);
    if (!std::filesystem::exists(input)) {
        if (message != nullptr) {
            *message = "SP4 asset missing and safetensors input not found";
        }
        return {};
    }
    const std::filesystem::path out = std::filesystem::current_path() / "Models/RIFE-SP4/rife_sp4_a1p.sp4";
    std::filesystem::create_directories(out.parent_path());
    sp4::CompileOptions options;
    options.inputPath = input.string();
    options.outputPath = out.string();
    options.adapter = "rife";
    options.target = "metal-m4pro";
    options.blockSize = "auto";
    options.qualityProfile = "adaptive-rife";
    options.residualRatio = 0.02f;
    sp4::CompileResult result = sp4::CompileSafetensorsToSp4(options);
    if (!result.ok) {
        if (message != nullptr) {
            *message = result.message;
        }
        return {};
    }
    return out;
}

std::vector<SMSP4LayerPlanCPU> SMBuildPlans(const sp4::LoadedAsset& asset) {
    std::vector<SMSP4LayerPlanCPU> plans;
    plans.reserve(asset.manifest.layers.size());
    for (const sp4::LayerDesc& layer : asset.manifest.layers) {
        SMSP4LayerPlanCPU plan;
        plan.qweightOffsetBytes = layer.qweightOffsetBytes;
        plan.scaleOffset = layer.scaleOffset;
        plan.modeOffset = layer.modeOffset;
        plan.auxOffset = layer.auxOffset;
        plan.residualTableOffset = layer.residualTableOffset;
        plan.residualIndexOffset = layer.residualIndexOffset;
        plan.residualValueOffset = layer.residualValueOffset;
        plan.blockSize = layer.blockSize;
        plan.blockCount = layer.numBlocks;
        plan.outputChannels = layer.shape.size() > 0 ? layer.shape[0] : 0;
        plan.inputChannels = layer.shape.size() > 1 ? layer.shape[1] : 0;
        plan.kernelHeight = layer.shape.size() > 2 ? layer.shape[2] : 1;
        plan.kernelWidth = layer.shape.size() > 3 ? layer.shape[3] : 1;
        plan.activationScaleOffset = layer.activationScaleOffset;
        plans.push_back(plan);
    }
    return plans;
}

std::vector<SMSP4PreparedLayerPlanCPU> SMBuildPreparedPlans(const sp4::PreparedRuntimeCache& cache) {
    std::vector<SMSP4PreparedLayerPlanCPU> plans;
    plans.reserve(cache.layers.size());
    for (const sp4::PreparedLayerDesc& layer : cache.layers) {
        SMSP4PreparedLayerPlanCPU plan;
        plan.sourceLayerIndex = layer.sourceLayerIndex;
        plan.weightOffset = layer.weightOffset;
        plan.weightCount = layer.weightCount;
        plan.biasOffset = layer.biasOffset;
        plan.biasCount = layer.biasCount;
        plan.inputChannels = layer.inputChannels;
        plan.outputChannels = layer.outputChannels;
        plan.kernelWidth = layer.kernelWidth;
        plan.kernelHeight = layer.kernelHeight;
        plan.flags = layer.flags;
        plans.push_back(plan);
    }
    return plans;
}

class RIFESP4RunnerImpl {
public:
    void SetCommandQueue(id<MTLCommandQueue> commandQueue);
    bool Load(const std::string& modelPath, uint32_t modelWidth, uint32_t modelHeight);
    bool IsReady() const { return ready_; }
    std::string Diagnostics() const { return diagnostics_; }
    Stellaria::Motion::RIFESP4RunResult RunTextures(id<MTLTexture> previousTexture,
                                                    id<MTLTexture> currentTexture,
                                                    id<MTLTexture> outputTexture,
                                                    uint32_t sourceWidth,
                                                    uint32_t sourceHeight);
    Stellaria::Motion::RIFESP4RunResult RunTexturesAtT(id<MTLTexture> previousTexture,
                                                       id<MTLTexture> currentTexture,
                                                       id<MTLTexture> outputTexture,
                                                       uint32_t sourceWidth,
                                                       uint32_t sourceHeight,
                                                       float t);
    Stellaria::Motion::RIFESP4RunResult RunTexturesAtTValues(id<MTLTexture> previousTexture,
                                                             id<MTLTexture> currentTexture,
                                                             const std::vector<id<MTLTexture>>& outputTextures,
                                                             const std::vector<float>& tValues,
                                                             uint32_t sourceWidth,
                                                             uint32_t sourceHeight);

private:
    Stellaria::Motion::RIFESP4RunResult PresentWithExistingFlow(id<MTLTexture> previousTexture,
                                                                id<MTLTexture> currentTexture,
                                                                id<MTLTexture> outputTexture,
                                                                uint32_t sourceWidth,
                                                                uint32_t sourceHeight,
                                                                float oldT,
                                                                float newT);
    id<MTLDevice> device_ = nil;
    id<MTLCommandQueue> queue_ = nil;
    id<MTLComputePipelineState> flowPipeline_ = nil;
    id<MTLComputePipelineState> preparedFlowPipeline_ = nil;
    id<MTLComputePipelineState> rescaleFlowPipeline_ = nil;
    id<MTLComputePipelineState> blendPipeline_ = nil;
    id<MTLComputePipelineState> refinePipeline_ = nil;
    id<MTLComputePipelineState> blendRefinePipeline_ = nil;
    id<MTLBuffer> qweightBuffer_ = nil;
    id<MTLBuffer> scaleBuffer_ = nil;
    id<MTLBuffer> modeBuffer_ = nil;
    id<MTLBuffer> auxBuffer_ = nil;
    id<MTLBuffer> residualIndexBuffer_ = nil;
    id<MTLBuffer> residualValueBuffer_ = nil;
    id<MTLBuffer> residualTableBuffer_ = nil;
    id<MTLBuffer> layerPlanBuffer_ = nil;
    id<MTLBuffer> preparedWeightBuffer_ = nil;
    id<MTLBuffer> preparedBiasBuffer_ = nil;
    id<MTLBuffer> preparedLayerBuffer_ = nil;
    id<MTLBuffer> flowMaskBuffer_ = nil;
    id<MTLTexture> sp4Texture_ = nil;
    uint32_t modelWidth_ = 0;
    uint32_t modelHeight_ = 0;
    uint32_t graphTensorCount_ = 0;
    uint32_t layerCount_ = 0;
    uint64_t sp4WeightBytes_ = 0;
    uint64_t teacherWeightBytes_ = 0;
    uint64_t preparedBytes_ = 0;
    std::filesystem::path assetPath_;
    bool preparedReady_ = false;
    std::string preparedSummary_;
    bool ready_ = false;
    std::string diagnostics_ = "not loaded";
};

void RIFESP4RunnerImpl::SetCommandQueue(id<MTLCommandQueue> commandQueue) {
    if (commandQueue != nil) {
        queue_ = commandQueue;
        device_ = commandQueue.device ?: device_;
    }
}

bool RIFESP4RunnerImpl::Load(const std::string& modelPath, uint32_t modelWidth, uint32_t modelHeight) {
    ready_ = false;
    modelWidth_ = modelWidth;
    modelHeight_ = modelHeight;
    graphTensorCount_ = 0;
    layerCount_ = 0;
    sp4WeightBytes_ = 0;
    teacherWeightBytes_ = 0;
    preparedBytes_ = 0;
    flowPipeline_ = nil;
    preparedFlowPipeline_ = nil;
    rescaleFlowPipeline_ = nil;
    blendPipeline_ = nil;
    refinePipeline_ = nil;
    blendRefinePipeline_ = nil;
    qweightBuffer_ = nil;
    scaleBuffer_ = nil;
    modeBuffer_ = nil;
    auxBuffer_ = nil;
    residualIndexBuffer_ = nil;
    residualValueBuffer_ = nil;
    residualTableBuffer_ = nil;
    layerPlanBuffer_ = nil;
    preparedWeightBuffer_ = nil;
    preparedBiasBuffer_ = nil;
    preparedLayerBuffer_ = nil;
    flowMaskBuffer_ = nil;
    sp4Texture_ = nil;
    preparedReady_ = false;
    preparedSummary_.clear();

    if (device_ == nil) {
        device_ = MTLCreateSystemDefaultDevice();
    }
    if (queue_ == nil && device_ != nil) {
        queue_ = [device_ newCommandQueue];
    }
    if (device_ == nil || queue_ == nil) {
        diagnostics_ = "SP4 SDK device/queue unavailable";
        return false;
    }

    NSError* error = nil;
    NSURL* libraryURL = SMMotionKernelsURL();
    id<MTLLibrary> library = libraryURL != nil ? [device_ newLibraryWithURL:libraryURL error:&error] : nil;
    id<MTLFunction> flowFunction = [library newFunctionWithName:@"rife_sp4_sdk_flow_mask"];
    id<MTLFunction> preparedFlowFunction = [library newFunctionWithName:@"rife_sp4_prepared_flow_mask"];
    id<MTLFunction> rescaleFlowFunction = [library newFunctionWithName:@"rife_rescale_flow_mask_t"];
    id<MTLFunction> blendFunction = [library newFunctionWithName:@"rife_metal4_blend_flow_bgra"];
    id<MTLFunction> refineFunction = [library newFunctionWithName:@"rife_sp4_a1p_residual_refine_bgra"];
    id<MTLFunction> blendRefineFunction = [library newFunctionWithName:@"rife_sp4_a1p_blend_refine_flow_bgra"];
    flowPipeline_ = flowFunction != nil ? [device_ newComputePipelineStateWithFunction:flowFunction error:&error] : nil;
    preparedFlowPipeline_ = preparedFlowFunction != nil ? [device_ newComputePipelineStateWithFunction:preparedFlowFunction error:&error] : nil;
    rescaleFlowPipeline_ = rescaleFlowFunction != nil ? [device_ newComputePipelineStateWithFunction:rescaleFlowFunction error:&error] : nil;
    blendPipeline_ = blendFunction != nil ? [device_ newComputePipelineStateWithFunction:blendFunction error:&error] : nil;
    refinePipeline_ = refineFunction != nil ? [device_ newComputePipelineStateWithFunction:refineFunction error:&error] : nil;
    blendRefinePipeline_ = blendRefineFunction != nil ? [device_ newComputePipelineStateWithFunction:blendRefineFunction error:&error] : nil;
    if (flowPipeline_ == nil || blendPipeline_ == nil || (refinePipeline_ == nil && blendRefinePipeline_ == nil)) {
        diagnostics_ = std::string("SP4 SDK Metal kernels unavailable: ") +
            (error.localizedDescription.UTF8String ?: "MotionKernels.metallib missing");
        return false;
    }

    std::string compileMessage;
    assetPath_ = SMCompileSP4AssetIfNeeded(modelPath, &compileMessage);
    if (assetPath_.empty()) {
        diagnostics_ = "SP4 SDK asset unavailable: " + compileMessage;
        return false;
    }

    sp4::LoadedAsset asset;
    std::string loadError;
    if (!sp4::LoadAsset(assetPath_.string(), asset, &loadError)) {
        diagnostics_ = "SP4 SDK asset load failed: " + loadError;
        return false;
    }
    std::vector<SMSP4LayerPlanCPU> plans = SMBuildPlans(asset);
    if (plans.size() < 3) {
        diagnostics_ = "SP4 SDK RIFE asset has too few runtime layers";
        return false;
    }

    qweightBuffer_ = SMMakeVectorBuffer(device_, queue_, asset.qweight);
    scaleBuffer_ = SMMakeVectorBuffer(device_, queue_, asset.scaleFp16);
    modeBuffer_ = SMMakeVectorBuffer(device_, queue_, asset.mode);
    auxBuffer_ = SMMakeVectorBuffer(device_, queue_, asset.aux);
    residualIndexBuffer_ = SMMakeVectorBuffer(device_, queue_, asset.residualIndex);
    residualValueBuffer_ = SMMakeVectorBuffer(device_, queue_, asset.residualValueFp16);
    residualTableBuffer_ = SMMakeVectorBuffer(device_, queue_, asset.residualTable);
    layerPlanBuffer_ = SMMakeVectorBuffer(device_, queue_, plans);
    sp4::PreparedRuntimeCache preparedCache;
    sp4::RuntimePrepareOptions prepareOptions;
    prepareOptions.maxLayers = 3;
    std::string prepareError;
    if (preparedFlowPipeline_ != nil &&
        sp4::PrepareRuntimeCache(asset, prepareOptions, preparedCache, &prepareError)) {
        std::vector<SMSP4PreparedLayerPlanCPU> preparedPlans = SMBuildPreparedPlans(preparedCache);
        if (preparedCache.biasFp16.empty()) {
            preparedCache.biasFp16.push_back(0);
        }
        preparedWeightBuffer_ = SMMakeVectorBuffer(device_, queue_, preparedCache.weightFp16);
        preparedBiasBuffer_ = SMMakeVectorBuffer(device_, queue_, preparedCache.biasFp16);
        preparedLayerBuffer_ = SMMakeVectorBuffer(device_, queue_, preparedPlans);
        preparedReady_ = preparedWeightBuffer_ != nil && preparedBiasBuffer_ != nil && preparedLayerBuffer_ != nil &&
                         preparedPlans.size() >= 3;
        preparedBytes_ = preparedCache.preparedBytes;
        preparedSummary_ = preparedCache.scheduleSummary;
    } else {
        preparedSummary_ = prepareError.empty() ? "prepared cache unavailable" : prepareError;
    }
    const NSUInteger flowMaskBytes = static_cast<NSUInteger>(modelWidth_) * modelHeight_ * 5 * sizeof(float);
    flowMaskBuffer_ = [device_ newBufferWithLength:flowMaskBytes options:MTLResourceStorageModePrivate];
    if (qweightBuffer_ == nil || scaleBuffer_ == nil || modeBuffer_ == nil || auxBuffer_ == nil ||
        residualIndexBuffer_ == nil || residualValueBuffer_ == nil || residualTableBuffer_ == nil ||
        layerPlanBuffer_ == nil || flowMaskBuffer_ == nil) {
        diagnostics_ = "SP4 SDK Metal buffer upload failed";
        return false;
    }

    graphTensorCount_ = asset.manifest.graphTensorCount;
    layerCount_ = static_cast<uint32_t>(std::min<size_t>(plans.size(), 3));
    sp4WeightBytes_ = asset.manifest.sp4WeightBytes;
    teacherWeightBytes_ = asset.manifest.teacherWeightBytes;
    ready_ = true;
    const double compression = static_cast<double>(teacherWeightBytes_) /
        static_cast<double>(std::max<uint64_t>(1, sp4WeightBytes_));
    std::ostringstream out;
    out << "Stellaria SP4 SDK ready · "
        << modelWidth_ << "x" << modelHeight_
        << " · layers " << asset.manifest.layers.size()
        << " · compression " << compression << "x"
        << " · " << (preparedReady_ ? "prepared-cache" : "direct-decode")
        << " · " << preparedSummary_
        << " · " << assetPath_.filename().string();
    diagnostics_ = out.str();
    return true;
}

Stellaria::Motion::RIFESP4RunResult RIFESP4RunnerImpl::RunTextures(id<MTLTexture> previousTexture,
                                                                   id<MTLTexture> currentTexture,
                                                                   id<MTLTexture> outputTexture,
                                                                   uint32_t sourceWidth,
                                                                   uint32_t sourceHeight) {
    return RunTexturesAtT(previousTexture, currentTexture, outputTexture, sourceWidth, sourceHeight, 0.5f);
}

Stellaria::Motion::RIFESP4RunResult RIFESP4RunnerImpl::RunTexturesAtT(id<MTLTexture> previousTexture,
                                                                      id<MTLTexture> currentTexture,
                                                                      id<MTLTexture> outputTexture,
                                                                      uint32_t sourceWidth,
                                                                      uint32_t sourceHeight,
                                                                      float t) {
    Stellaria::Motion::RIFESP4RunResult result;
    result.width = sourceWidth;
    result.height = sourceHeight;
    result.modelWidth = modelWidth_;
    result.modelHeight = modelHeight_;
    if (!IsReady()) {
        result.message = diagnostics_;
        return result;
    }
    if (previousTexture == nil || currentTexture == nil || outputTexture == nil) {
        result.message = "SP4 SDK texture missing";
        return result;
    }
    const bool fastPresentation = modelHeight_ <= 144;
    const bool fusedPresentation = !fastPresentation && blendRefinePipeline_ != nil;
    if (!fastPresentation && !fusedPresentation &&
        (sp4Texture_ == nil || sp4Texture_.width != sourceWidth || sp4Texture_.height != sourceHeight)) {
        MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                              width:sourceWidth
                                                                                             height:sourceHeight
                                                                                          mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        descriptor.storageMode = MTLStorageModePrivate;
        sp4Texture_ = [device_ newTextureWithDescriptor:descriptor];
    }
    if (!fastPresentation && !fusedPresentation && sp4Texture_ == nil) {
        result.message = "SP4 SDK intermediate texture allocation failed";
        return result;
    }

    SMMIF4Params flowParams{
        .width = sourceWidth,
        .height = sourceHeight,
        .modelWidth = modelWidth_,
        .modelHeight = modelHeight_,
        .layerCount = layerCount_,
        .graphTensorCount = graphTensorCount_,
        .activeBlockCount = layerCount_,
        .reserved0 = 0,
        .flowGain = 5.0f,
        .nativeBlend = 0.02f,
        .t = std::max(0.0f, std::min(1.0f, t)),
        .reserved1 = 0.0f,
    };
    SMSP4RefineParams refineParams{
        .width = sourceWidth,
        .height = sourceHeight,
        .modelWidth = modelWidth_,
        .modelHeight = modelHeight_,
        .residualStrength = 0.18f,
        .temporalProtect = 0.72f,
        .edgeProtect = 0.55f,
        .t = std::max(0.0f, std::min(1.0f, t)),
    };

    const CFTimeInterval start = CACurrentMediaTime();
    id<MTLCommandBuffer> commandBuffer = [queue_ commandBuffer];
    id<MTLComputeCommandEncoder> flow = [commandBuffer computeCommandEncoder];
    [flow setTexture:previousTexture atIndex:0];
    [flow setTexture:currentTexture atIndex:1];
    [flow setBuffer:flowMaskBuffer_ offset:0 atIndex:0];
    if (preparedReady_) {
        [flow setComputePipelineState:preparedFlowPipeline_];
        [flow setBuffer:preparedWeightBuffer_ offset:0 atIndex:1];
        [flow setBuffer:preparedBiasBuffer_ offset:0 atIndex:2];
        [flow setBuffer:preparedLayerBuffer_ offset:0 atIndex:3];
        [flow setBytes:&flowParams length:sizeof(flowParams) atIndex:4];
        [flow dispatchThreads:MTLSizeMake(modelWidth_, modelHeight_, 1) threadsPerThreadgroup:SMThreadgroup(preparedFlowPipeline_)];
    } else {
        [flow setComputePipelineState:flowPipeline_];
        [flow setBuffer:qweightBuffer_ offset:0 atIndex:1];
        [flow setBuffer:scaleBuffer_ offset:0 atIndex:2];
        [flow setBuffer:modeBuffer_ offset:0 atIndex:3];
        [flow setBuffer:auxBuffer_ offset:0 atIndex:4];
        [flow setBuffer:residualIndexBuffer_ offset:0 atIndex:5];
        [flow setBuffer:residualValueBuffer_ offset:0 atIndex:6];
        [flow setBuffer:residualTableBuffer_ offset:0 atIndex:7];
        [flow setBuffer:layerPlanBuffer_ offset:0 atIndex:8];
        [flow setBytes:&flowParams length:sizeof(flowParams) atIndex:9];
        [flow dispatchThreads:MTLSizeMake(modelWidth_, modelHeight_, 1) threadsPerThreadgroup:SMThreadgroup(flowPipeline_)];
    }
    [flow endEncoding];

    if (fusedPresentation) {
        id<MTLComputeCommandEncoder> fused = [commandBuffer computeCommandEncoder];
        [fused setComputePipelineState:blendRefinePipeline_];
        [fused setTexture:previousTexture atIndex:0];
        [fused setTexture:currentTexture atIndex:1];
        [fused setTexture:outputTexture atIndex:2];
        [fused setBuffer:flowMaskBuffer_ offset:0 atIndex:0];
        [fused setBytes:&flowParams length:sizeof(flowParams) atIndex:1];
        [fused setBytes:&refineParams length:sizeof(refineParams) atIndex:2];
        [fused dispatchThreads:MTLSizeMake(sourceWidth, sourceHeight, 1) threadsPerThreadgroup:SMThreadgroup(blendRefinePipeline_)];
        [fused endEncoding];
    } else {
        id<MTLComputeCommandEncoder> blend = [commandBuffer computeCommandEncoder];
        [blend setComputePipelineState:blendPipeline_];
        [blend setTexture:previousTexture atIndex:0];
        [blend setTexture:currentTexture atIndex:1];
        [blend setTexture:(fastPresentation ? outputTexture : sp4Texture_) atIndex:2];
        [blend setBuffer:flowMaskBuffer_ offset:0 atIndex:0];
        [blend setBytes:&flowParams length:sizeof(flowParams) atIndex:1];
        [blend dispatchThreads:MTLSizeMake(sourceWidth, sourceHeight, 1) threadsPerThreadgroup:SMThreadgroup(blendPipeline_)];
        [blend endEncoding];
    }

    if (!fastPresentation && !fusedPresentation) {
        id<MTLComputeCommandEncoder> refine = [commandBuffer computeCommandEncoder];
        [refine setComputePipelineState:refinePipeline_];
        [refine setTexture:previousTexture atIndex:0];
        [refine setTexture:currentTexture atIndex:1];
        [refine setTexture:sp4Texture_ atIndex:2];
        [refine setTexture:outputTexture atIndex:3];
        [refine setBytes:&refineParams length:sizeof(refineParams) atIndex:0];
        [refine dispatchThreads:MTLSizeMake(sourceWidth, sourceHeight, 1) threadsPerThreadgroup:SMThreadgroup(refinePipeline_)];
        [refine endEncoding];
    }

    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    result.elapsedMs = (CACurrentMediaTime() - start) * 1000.0;
    result.ok = commandBuffer.status == MTLCommandBufferStatusCompleted;
    result.message = result.ok
        ? (preparedReady_
            ? (fastPresentation ? "Stellaria SP4 SDK prepared fast frame processed" : "Stellaria SP4 SDK prepared frame processed")
            : (fastPresentation ? "Stellaria SP4 SDK fast frame processed" : "Stellaria SP4 SDK frame processed"))
        : "Stellaria SP4 SDK command failed";
    return result;
}

Stellaria::Motion::RIFESP4RunResult RIFESP4RunnerImpl::PresentWithExistingFlow(id<MTLTexture> previousTexture,
                                                                               id<MTLTexture> currentTexture,
                                                                               id<MTLTexture> outputTexture,
                                                                               uint32_t sourceWidth,
                                                                               uint32_t sourceHeight,
                                                                               float oldT,
                                                                               float newT) {
    Stellaria::Motion::RIFESP4RunResult result;
    result.width = sourceWidth;
    result.height = sourceHeight;
    result.modelWidth = modelWidth_;
    result.modelHeight = modelHeight_;
    if (!IsReady() || rescaleFlowPipeline_ == nil || flowMaskBuffer_ == nil) {
        result.message = "SP4 SDK reusable flow unavailable";
        return result;
    }
    if (previousTexture == nil || currentTexture == nil || outputTexture == nil) {
        result.message = "SP4 SDK texture missing";
        return result;
    }
    const bool fastPresentation = modelHeight_ <= 144;
    const bool fusedPresentation = !fastPresentation && blendRefinePipeline_ != nil;
    if (!fastPresentation && !fusedPresentation &&
        (sp4Texture_ == nil || sp4Texture_.width != sourceWidth || sp4Texture_.height != sourceHeight)) {
        MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                              width:sourceWidth
                                                                                             height:sourceHeight
                                                                                          mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        descriptor.storageMode = MTLStorageModePrivate;
        sp4Texture_ = [device_ newTextureWithDescriptor:descriptor];
    }
    if (!fastPresentation && !fusedPresentation && sp4Texture_ == nil) {
        result.message = "SP4 SDK intermediate texture allocation failed";
        return result;
    }

    SMMIF4Params flowParams{
        .width = sourceWidth,
        .height = sourceHeight,
        .modelWidth = modelWidth_,
        .modelHeight = modelHeight_,
        .layerCount = layerCount_,
        .graphTensorCount = graphTensorCount_,
        .activeBlockCount = layerCount_,
        .reserved0 = 0,
        .flowGain = 5.0f,
        .nativeBlend = 0.02f,
        .t = std::max(0.0f, std::min(1.0f, newT)),
        .reserved1 = std::max(0.0f, std::min(1.0f, oldT)),
    };
    SMSP4RefineParams refineParams{
        .width = sourceWidth,
        .height = sourceHeight,
        .modelWidth = modelWidth_,
        .modelHeight = modelHeight_,
        .residualStrength = 0.18f,
        .temporalProtect = 0.72f,
        .edgeProtect = 0.55f,
        .t = std::max(0.0f, std::min(1.0f, newT)),
    };

    const CFTimeInterval start = CACurrentMediaTime();
    id<MTLCommandBuffer> commandBuffer = [queue_ commandBuffer];
    id<MTLComputeCommandEncoder> rescale = [commandBuffer computeCommandEncoder];
    [rescale setComputePipelineState:rescaleFlowPipeline_];
    [rescale setBuffer:flowMaskBuffer_ offset:0 atIndex:0];
    [rescale setBytes:&flowParams length:sizeof(flowParams) atIndex:1];
    [rescale dispatchThreads:MTLSizeMake(modelWidth_, modelHeight_, 1) threadsPerThreadgroup:SMThreadgroup(rescaleFlowPipeline_)];
    [rescale endEncoding];

    if (fusedPresentation) {
        id<MTLComputeCommandEncoder> fused = [commandBuffer computeCommandEncoder];
        [fused setComputePipelineState:blendRefinePipeline_];
        [fused setTexture:previousTexture atIndex:0];
        [fused setTexture:currentTexture atIndex:1];
        [fused setTexture:outputTexture atIndex:2];
        [fused setBuffer:flowMaskBuffer_ offset:0 atIndex:0];
        [fused setBytes:&flowParams length:sizeof(flowParams) atIndex:1];
        [fused setBytes:&refineParams length:sizeof(refineParams) atIndex:2];
        [fused dispatchThreads:MTLSizeMake(sourceWidth, sourceHeight, 1) threadsPerThreadgroup:SMThreadgroup(blendRefinePipeline_)];
        [fused endEncoding];
    } else {
        id<MTLComputeCommandEncoder> blend = [commandBuffer computeCommandEncoder];
        [blend setComputePipelineState:blendPipeline_];
        [blend setTexture:previousTexture atIndex:0];
        [blend setTexture:currentTexture atIndex:1];
        [blend setTexture:(fastPresentation ? outputTexture : sp4Texture_) atIndex:2];
        [blend setBuffer:flowMaskBuffer_ offset:0 atIndex:0];
        [blend setBytes:&flowParams length:sizeof(flowParams) atIndex:1];
        [blend dispatchThreads:MTLSizeMake(sourceWidth, sourceHeight, 1) threadsPerThreadgroup:SMThreadgroup(blendPipeline_)];
        [blend endEncoding];
    }

    if (!fastPresentation && !fusedPresentation) {
        id<MTLComputeCommandEncoder> refine = [commandBuffer computeCommandEncoder];
        [refine setComputePipelineState:refinePipeline_];
        [refine setTexture:previousTexture atIndex:0];
        [refine setTexture:currentTexture atIndex:1];
        [refine setTexture:sp4Texture_ atIndex:2];
        [refine setTexture:outputTexture atIndex:3];
        [refine setBytes:&refineParams length:sizeof(refineParams) atIndex:0];
        [refine dispatchThreads:MTLSizeMake(sourceWidth, sourceHeight, 1) threadsPerThreadgroup:SMThreadgroup(refinePipeline_)];
        [refine endEncoding];
    }

    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    result.elapsedMs = (CACurrentMediaTime() - start) * 1000.0;
    result.ok = commandBuffer.status == MTLCommandBufferStatusCompleted;
    result.message = result.ok ? "Stellaria SP4 SDK reused flow frame processed" : "Stellaria SP4 SDK reused flow failed";
    return result;
}

Stellaria::Motion::RIFESP4RunResult RIFESP4RunnerImpl::RunTexturesAtTValues(id<MTLTexture> previousTexture,
                                                                            id<MTLTexture> currentTexture,
                                                                            const std::vector<id<MTLTexture>>& outputTextures,
                                                                            const std::vector<float>& tValues,
                                                                            uint32_t sourceWidth,
                                                                            uint32_t sourceHeight) {
    Stellaria::Motion::RIFESP4RunResult combined;
    combined.width = sourceWidth;
    combined.height = sourceHeight;
    combined.modelWidth = modelWidth_;
    combined.modelHeight = modelHeight_;
    const size_t count = std::min(outputTextures.size(), tValues.size());
    if (count == 0) {
        combined.message = "SP4 SDK t batch is empty";
        return combined;
    }
    if (count == 1 || rescaleFlowPipeline_ == nil) {
        return RunTexturesAtT(previousTexture, currentTexture, outputTextures[0], sourceWidth, sourceHeight, tValues[0]);
    }
    if (!IsReady()) {
        combined.message = diagnostics_;
        return combined;
    }
    if (previousTexture == nil || currentTexture == nil) {
        combined.message = "SP4 SDK texture missing";
        return combined;
    }
    for (size_t i = 0; i < count; ++i) {
        if (outputTextures[i] == nil) {
            combined.message = "SP4 SDK output texture missing";
            return combined;
        }
    }

    const bool fastPresentation = modelHeight_ <= 144;
    const bool fusedPresentation = !fastPresentation && blendRefinePipeline_ != nil;
    if (!fastPresentation && !fusedPresentation &&
        (sp4Texture_ == nil || sp4Texture_.width != sourceWidth || sp4Texture_.height != sourceHeight)) {
        MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                              width:sourceWidth
                                                                                             height:sourceHeight
                                                                                          mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        descriptor.storageMode = MTLStorageModePrivate;
        sp4Texture_ = [device_ newTextureWithDescriptor:descriptor];
    }
    if (!fastPresentation && !fusedPresentation && sp4Texture_ == nil) {
        combined.message = "SP4 SDK intermediate texture allocation failed";
        return combined;
    }

    auto clamp01 = [](float value) {
        return std::max(0.0f, std::min(1.0f, value));
    };
    auto makeFlowParams = [&](float t, float oldT) {
        return SMMIF4Params{
            .width = sourceWidth,
            .height = sourceHeight,
            .modelWidth = modelWidth_,
            .modelHeight = modelHeight_,
            .layerCount = layerCount_,
            .graphTensorCount = graphTensorCount_,
            .activeBlockCount = layerCount_,
            .reserved0 = 0,
            .flowGain = 5.0f,
            .nativeBlend = 0.02f,
            .t = clamp01(t),
            .reserved1 = clamp01(oldT),
        };
    };
    auto makeRefineParams = [&](float t) {
        return SMSP4RefineParams{
            .width = sourceWidth,
            .height = sourceHeight,
            .modelWidth = modelWidth_,
            .modelHeight = modelHeight_,
            .residualStrength = 0.18f,
            .temporalProtect = 0.72f,
            .edgeProtect = 0.55f,
            .t = clamp01(t),
        };
    };
    auto encodePresentation = [&](id<MTLCommandBuffer> commandBuffer,
                                  id<MTLTexture> outputTexture,
                                  const SMMIF4Params& flowParams,
                                  const SMSP4RefineParams& refineParams) {
        if (fusedPresentation) {
            id<MTLComputeCommandEncoder> fused = [commandBuffer computeCommandEncoder];
            [fused setComputePipelineState:blendRefinePipeline_];
            [fused setTexture:previousTexture atIndex:0];
            [fused setTexture:currentTexture atIndex:1];
            [fused setTexture:outputTexture atIndex:2];
            [fused setBuffer:flowMaskBuffer_ offset:0 atIndex:0];
            [fused setBytes:&flowParams length:sizeof(flowParams) atIndex:1];
            [fused setBytes:&refineParams length:sizeof(refineParams) atIndex:2];
            [fused dispatchThreads:MTLSizeMake(sourceWidth, sourceHeight, 1) threadsPerThreadgroup:SMThreadgroup(blendRefinePipeline_)];
            [fused endEncoding];
            return;
        }

        id<MTLComputeCommandEncoder> blend = [commandBuffer computeCommandEncoder];
        [blend setComputePipelineState:blendPipeline_];
        [blend setTexture:previousTexture atIndex:0];
        [blend setTexture:currentTexture atIndex:1];
        [blend setTexture:(fastPresentation ? outputTexture : sp4Texture_) atIndex:2];
        [blend setBuffer:flowMaskBuffer_ offset:0 atIndex:0];
        [blend setBytes:&flowParams length:sizeof(flowParams) atIndex:1];
        [blend dispatchThreads:MTLSizeMake(sourceWidth, sourceHeight, 1) threadsPerThreadgroup:SMThreadgroup(blendPipeline_)];
        [blend endEncoding];

        if (!fastPresentation) {
            id<MTLComputeCommandEncoder> refine = [commandBuffer computeCommandEncoder];
            [refine setComputePipelineState:refinePipeline_];
            [refine setTexture:previousTexture atIndex:0];
            [refine setTexture:currentTexture atIndex:1];
            [refine setTexture:sp4Texture_ atIndex:2];
            [refine setTexture:outputTexture atIndex:3];
            [refine setBytes:&refineParams length:sizeof(refineParams) atIndex:0];
            [refine dispatchThreads:MTLSizeMake(sourceWidth, sourceHeight, 1) threadsPerThreadgroup:SMThreadgroup(refinePipeline_)];
            [refine endEncoding];
        }
    };

    const CFTimeInterval start = CACurrentMediaTime();
    id<MTLCommandBuffer> commandBuffer = [queue_ commandBuffer];
    SMMIF4Params flowParams = makeFlowParams(tValues[0], 0.0f);
    id<MTLComputeCommandEncoder> flow = [commandBuffer computeCommandEncoder];
    [flow setTexture:previousTexture atIndex:0];
    [flow setTexture:currentTexture atIndex:1];
    [flow setBuffer:flowMaskBuffer_ offset:0 atIndex:0];
    if (preparedReady_) {
        [flow setComputePipelineState:preparedFlowPipeline_];
        [flow setBuffer:preparedWeightBuffer_ offset:0 atIndex:1];
        [flow setBuffer:preparedBiasBuffer_ offset:0 atIndex:2];
        [flow setBuffer:preparedLayerBuffer_ offset:0 atIndex:3];
        [flow setBytes:&flowParams length:sizeof(flowParams) atIndex:4];
        [flow dispatchThreads:MTLSizeMake(modelWidth_, modelHeight_, 1) threadsPerThreadgroup:SMThreadgroup(preparedFlowPipeline_)];
    } else {
        [flow setComputePipelineState:flowPipeline_];
        [flow setBuffer:qweightBuffer_ offset:0 atIndex:1];
        [flow setBuffer:scaleBuffer_ offset:0 atIndex:2];
        [flow setBuffer:modeBuffer_ offset:0 atIndex:3];
        [flow setBuffer:auxBuffer_ offset:0 atIndex:4];
        [flow setBuffer:residualIndexBuffer_ offset:0 atIndex:5];
        [flow setBuffer:residualValueBuffer_ offset:0 atIndex:6];
        [flow setBuffer:residualTableBuffer_ offset:0 atIndex:7];
        [flow setBuffer:layerPlanBuffer_ offset:0 atIndex:8];
        [flow setBytes:&flowParams length:sizeof(flowParams) atIndex:9];
        [flow dispatchThreads:MTLSizeMake(modelWidth_, modelHeight_, 1) threadsPerThreadgroup:SMThreadgroup(flowPipeline_)];
    }
    [flow endEncoding];

    encodePresentation(commandBuffer, outputTextures[0], flowParams, makeRefineParams(tValues[0]));

    float oldT = tValues[0];
    for (size_t i = 1; i < count; ++i) {
        flowParams = makeFlowParams(tValues[i], oldT);
        id<MTLComputeCommandEncoder> rescale = [commandBuffer computeCommandEncoder];
        [rescale setComputePipelineState:rescaleFlowPipeline_];
        [rescale setBuffer:flowMaskBuffer_ offset:0 atIndex:0];
        [rescale setBytes:&flowParams length:sizeof(flowParams) atIndex:1];
        [rescale dispatchThreads:MTLSizeMake(modelWidth_, modelHeight_, 1) threadsPerThreadgroup:SMThreadgroup(rescaleFlowPipeline_)];
        [rescale endEncoding];
        encodePresentation(commandBuffer, outputTextures[i], flowParams, makeRefineParams(tValues[i]));
        oldT = tValues[i];
    }

    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    combined.elapsedMs = (CACurrentMediaTime() - start) * 1000.0;
    combined.ok = commandBuffer.status == MTLCommandBufferStatusCompleted;
    combined.message = combined.ok
        ? (fusedPresentation ? "Stellaria SP4 SDK fused t batch processed" : "Stellaria SP4 SDK t batch processed")
        : "Stellaria SP4 SDK t batch command failed";
    return combined;
}

} // namespace

namespace Stellaria::Motion {

RIFESP4Runner::RIFESP4Runner()
    : impl_(new RIFESP4RunnerImpl()) {
}

RIFESP4Runner::~RIFESP4Runner() {
    delete static_cast<RIFESP4RunnerImpl*>(impl_);
}

void RIFESP4Runner::SetCommandQueue(void* commandQueue) {
    static_cast<RIFESP4RunnerImpl*>(impl_)->SetCommandQueue((__bridge id<MTLCommandQueue>)commandQueue);
}

bool RIFESP4Runner::Load(const std::string& modelPath, uint32_t modelWidth, uint32_t modelHeight) {
    return static_cast<RIFESP4RunnerImpl*>(impl_)->Load(modelPath, modelWidth, modelHeight);
}

bool RIFESP4Runner::IsReady() const {
    return static_cast<RIFESP4RunnerImpl*>(impl_)->IsReady();
}

std::string RIFESP4Runner::Diagnostics() const {
    return static_cast<RIFESP4RunnerImpl*>(impl_)->Diagnostics();
}

RIFESP4RunResult RIFESP4Runner::RunTextures(void* previousTexture,
                                            void* currentTexture,
                                            void* outputTexture,
                                            uint32_t sourceWidth,
                                            uint32_t sourceHeight) {
    return static_cast<RIFESP4RunnerImpl*>(impl_)->RunTextures((__bridge id<MTLTexture>)previousTexture,
                                                               (__bridge id<MTLTexture>)currentTexture,
                                                               (__bridge id<MTLTexture>)outputTexture,
                                                               sourceWidth,
                                                               sourceHeight);
}

RIFESP4RunResult RIFESP4Runner::RunTexturesAtT(void* previousTexture,
                                               void* currentTexture,
                                               void* outputTexture,
                                               uint32_t sourceWidth,
                                               uint32_t sourceHeight,
                                               float t) {
    return static_cast<RIFESP4RunnerImpl*>(impl_)->RunTexturesAtT((__bridge id<MTLTexture>)previousTexture,
                                                                  (__bridge id<MTLTexture>)currentTexture,
                                                                  (__bridge id<MTLTexture>)outputTexture,
                                                                  sourceWidth,
                                                                  sourceHeight,
                                                                  t);
}

RIFESP4RunResult RIFESP4Runner::RunTexturesAtTValues(void* previousTexture,
                                                     void* currentTexture,
                                                     void* const* outputTextures,
                                                     const float* tValues,
                                                     uint32_t outputCount,
                                                     uint32_t sourceWidth,
                                                     uint32_t sourceHeight) {
    std::vector<id<MTLTexture>> textures;
    std::vector<float> times;
    textures.reserve(outputCount);
    times.reserve(outputCount);
    for (uint32_t i = 0; i < outputCount; ++i) {
        textures.push_back((__bridge id<MTLTexture>)outputTextures[i]);
        times.push_back(tValues[i]);
    }
    return static_cast<RIFESP4RunnerImpl*>(impl_)->RunTexturesAtTValues((__bridge id<MTLTexture>)previousTexture,
                                                                        (__bridge id<MTLTexture>)currentTexture,
                                                                        textures,
                                                                        times,
                                                                        sourceWidth,
                                                                        sourceHeight);
}

} // namespace Stellaria::Motion
