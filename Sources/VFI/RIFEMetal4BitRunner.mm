#include "VFI/RIFEMetal4BitRunner.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <sstream>
#include <unordered_map>
#include <vector>

namespace {

struct SMQ4LayerDescCPU {
    uint32_t weightOffsetBytes = 0;
    uint32_t scaleOffset = 0;
    uint32_t biasOffset = 0;
    uint32_t outputChannels = 0;
    uint32_t inputChannels = 0;
    uint32_t kernelWidth = 0;
    uint32_t kernelHeight = 0;
    uint32_t op = 0;
};

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

NSString* SMNSString(const std::string& value) {
    return [NSString stringWithUTF8String:value.c_str()];
}

uint64_t SMReadLE64(const uint8_t* bytes) {
    uint64_t value = 0;
    for (int i = 7; i >= 0; --i) {
        value = (value << 8U) | bytes[i];
    }
    return value;
}

std::vector<float> SMReadTensor(NSDictionary* header,
                                NSData* file,
                                uint64_t headerBytes,
                                NSString* name,
                                std::vector<uint32_t>* shapeOut,
                                std::string* error) {
    NSDictionary* entry = [header[name] isKindOfClass:NSDictionary.class] ? header[name] : nil;
    NSArray<NSNumber*>* offsets = [entry[@"data_offsets"] isKindOfClass:NSArray.class] ? entry[@"data_offsets"] : nil;
    NSArray<NSNumber*>* shape = [entry[@"shape"] isKindOfClass:NSArray.class] ? entry[@"shape"] : nil;
    NSString* dtype = [entry[@"dtype"] isKindOfClass:NSString.class] ? entry[@"dtype"] : @"";
    if (entry == nil || offsets.count != 2 || shape.count == 0 || ![dtype isEqualToString:@"F32"]) {
        if (error != nullptr) {
            *error = std::string("missing F32 tensor ") + name.UTF8String;
        }
        return {};
    }

    uint64_t count = 1;
    std::vector<uint32_t> parsedShape;
    parsedShape.reserve(shape.count);
    for (NSNumber* dim in shape) {
        parsedShape.push_back(dim.unsignedIntValue);
        count *= dim.unsignedLongLongValue;
    }

    const uint64_t start = offsets[0].unsignedLongLongValue + 8 + headerBytes;
    const uint64_t end = offsets[1].unsignedLongLongValue + 8 + headerBytes;
    if (end <= start || end > file.length || (end - start) != count * sizeof(float)) {
        if (error != nullptr) {
            *error = std::string("invalid tensor storage ") + name.UTF8String;
        }
        return {};
    }

    std::vector<float> values(static_cast<size_t>(count));
    std::memcpy(values.data(),
                static_cast<const uint8_t*>(file.bytes) + start,
                static_cast<size_t>(count * sizeof(float)));
    if (shapeOut != nullptr) {
        *shapeOut = std::move(parsedShape);
    }
    return values;
}

void SMPackQ4Layer(const std::vector<float>& weights,
                   const std::vector<float>& bias,
                   const std::vector<uint32_t>& shape,
                   std::vector<uint8_t>* q4Pool,
                   std::vector<float>* scalePool,
                   std::vector<float>* biasPool,
                   std::vector<SMQ4LayerDescCPU>* layers,
                   uint32_t op) {
    if (shape.size() != 4 || q4Pool == nullptr || scalePool == nullptr || biasPool == nullptr || layers == nullptr) {
        return;
    }
    const uint32_t outputChannels = shape[0];
    const uint32_t inputChannels = shape[1];
    const uint32_t kernelHeight = shape[2];
    const uint32_t kernelWidth = shape[3];
    const uint32_t kernelValues = inputChannels * kernelHeight * kernelWidth;
    const uint32_t packedPerOutput = (kernelValues + 1U) / 2U;
    SMQ4LayerDescCPU desc;
    desc.weightOffsetBytes = static_cast<uint32_t>(q4Pool->size());
    desc.scaleOffset = static_cast<uint32_t>(scalePool->size());
    desc.biasOffset = static_cast<uint32_t>(biasPool->size());
    desc.outputChannels = outputChannels;
    desc.inputChannels = inputChannels;
    desc.kernelWidth = kernelWidth;
    desc.kernelHeight = kernelHeight;
    desc.op = op;

    q4Pool->resize(q4Pool->size() + static_cast<size_t>(outputChannels) * packedPerOutput);
    scalePool->resize(scalePool->size() + outputChannels);
    biasPool->resize(biasPool->size() + outputChannels);
    for (uint32_t oc = 0; oc < outputChannels; ++oc) {
        float maxAbs = 0.0f;
        for (uint32_t i = 0; i < kernelValues; ++i) {
            maxAbs = std::max(maxAbs, std::fabs(weights[static_cast<size_t>(oc) * kernelValues + i]));
        }
        const float scale = maxAbs > 1.0e-8f ? maxAbs / 7.0f : 1.0f;
        (*scalePool)[desc.scaleOffset + oc] = scale;
        (*biasPool)[desc.biasOffset + oc] = oc < bias.size() ? bias[oc] : 0.0f;
        for (uint32_t i = 0; i < kernelValues; ++i) {
            const float value = weights[static_cast<size_t>(oc) * kernelValues + i] / scale;
            const int q = std::clamp(static_cast<int>(std::lrint(value)), -8, 7);
            const uint8_t nibble = static_cast<uint8_t>(q & 0x0F);
            const size_t packedOffset = static_cast<size_t>(desc.weightOffsetBytes) +
                static_cast<size_t>(oc) * packedPerOutput + i / 2U;
            if ((i & 1U) == 0U) {
                (*q4Pool)[packedOffset] = nibble;
            } else {
                (*q4Pool)[packedOffset] |= static_cast<uint8_t>(nibble << 4U);
            }
        }
    }
    layers->push_back(desc);
}

bool SMLoadRIFEGraphAsQ4(const std::string& modelPath,
                         std::vector<uint8_t>* q4Pool,
                         std::vector<float>* scalePool,
                         std::vector<float>* biasPool,
                         std::vector<SMQ4LayerDescCPU>* layers,
                         uint32_t* tensorCount,
                         std::string* error) {
    if (q4Pool == nullptr || scalePool == nullptr || biasPool == nullptr || layers == nullptr || tensorCount == nullptr) {
        return false;
    }
    q4Pool->clear();
    scalePool->clear();
    biasPool->clear();
    layers->clear();
    *tensorCount = 0;

    NSString* path = SMNSString(modelPath);
    NSData* file = [NSData dataWithContentsOfFile:path];
    if (file.length < 16) {
        if (error != nullptr) {
            *error = "RIFE safetensors missing or unreadable";
        }
        return false;
    }
    const uint8_t* bytes = static_cast<const uint8_t*>(file.bytes);
    const uint64_t headerBytes = SMReadLE64(bytes);
    if (headerBytes == 0 || headerBytes + 8 > file.length) {
        if (error != nullptr) {
            *error = "RIFE safetensors header length invalid";
        }
        return false;
    }
    NSData* headerData = [file subdataWithRange:NSMakeRange(8, static_cast<NSUInteger>(headerBytes))];
    NSDictionary* header = [NSJSONSerialization JSONObjectWithData:headerData options:0 error:nil];
    if (![header isKindOfClass:NSDictionary.class]) {
        if (error != nullptr) {
            *error = "RIFE safetensors header JSON invalid";
        }
        return false;
    }

    for (NSString* key in header) {
        if (![key isEqualToString:@"__metadata__"]) {
            *tensorCount += 1;
        }
    }

    std::vector<NSString*> orderedWeights;
    for (int block = 0; block < 3; ++block) {
        orderedWeights.push_back([NSString stringWithFormat:@"block%d.conv0.0.0.weight", block]);
    }
    NSMutableArray<NSString*>* allWeights = [NSMutableArray array];
    for (NSString* key in header) {
        NSDictionary* entry = [header[key] isKindOfClass:NSDictionary.class] ? header[key] : nil;
        NSArray<NSNumber*>* shape = [entry[@"shape"] isKindOfClass:NSArray.class] ? entry[@"shape"] : nil;
        NSString* dtype = [entry[@"dtype"] isKindOfClass:NSString.class] ? entry[@"dtype"] : @"";
        if ([dtype isEqualToString:@"F32"] && shape.count == 4 && [key hasSuffix:@".weight"]) {
            [allWeights addObject:key];
        }
    }
    [allWeights sortUsingSelector:@selector(compare:)];
    for (NSString* key in allWeights) {
        BOOL alreadyListed = NO;
        for (NSString* listed : orderedWeights) {
            if ([listed isEqualToString:key]) {
                alreadyListed = YES;
                break;
            }
        }
        if (!alreadyListed) {
            orderedWeights.push_back(key);
        }
    }

    for (NSString* weightName : orderedWeights) {
        std::string loadError;
        std::vector<uint32_t> weightShape;
        std::vector<float> weights = SMReadTensor(header, file, headerBytes, weightName, &weightShape, &loadError);
        if (weights.empty() || weightShape.size() != 4) {
            if (error != nullptr) {
                *error = loadError.empty() ? "RIFE q4 weight tensor invalid" : loadError;
            }
            return false;
        }
        NSString* biasName = [[weightName stringByDeletingPathExtension] stringByAppendingString:@".bias"];
        if ([weightName hasSuffix:@".0.weight"]) {
            biasName = [[weightName substringToIndex:weightName.length - @".weight".length] stringByAppendingString:@".bias"];
        }
        std::vector<uint32_t> biasShape;
        std::vector<float> bias = SMReadTensor(header, file, headerBytes, biasName, &biasShape, nullptr);
        const uint32_t op = [weightName containsString:@".conv1."] || [weightName containsString:@".conv2."] ? 2U : 1U;
        SMPackQ4Layer(weights, bias, weightShape, q4Pool, scalePool, biasPool, layers, op);
    }

    if (*tensorCount != 160 || layers->size() < 48) {
        if (error != nullptr) {
            std::ostringstream out;
            out << "RIFE full graph incomplete tensors=" << *tensorCount << " q4Layers=" << layers->size();
            *error = out.str();
        }
        return false;
    }
    return true;
}

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

id<MTLBuffer> SMMakePrivateBuffer(id<MTLDevice> device,
                                  id<MTLCommandQueue> queue,
                                  const void* bytes,
                                  NSUInteger length) {
    if (device == nil || queue == nil || bytes == nullptr || length == 0) {
        return nil;
    }
    id<MTLBuffer> staging = [device newBufferWithBytes:bytes length:length options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [device newBufferWithLength:length options:MTLResourceStorageModePrivate];
    if (staging == nil || out == nil) {
        return nil;
    }
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    [blit copyFromBuffer:staging sourceOffset:0 toBuffer:out destinationOffset:0 size:length];
    [blit endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    return commandBuffer.status == MTLCommandBufferStatusCompleted ? out : nil;
}

MTLSize SMThreadgroup(id<MTLComputePipelineState> pipeline) {
    const NSUInteger width = std::max<NSUInteger>(1, pipeline.threadExecutionWidth);
    const NSUInteger height = std::max<NSUInteger>(1, pipeline.maxTotalThreadsPerThreadgroup / width);
    return MTLSizeMake(width, height, 1);
}

class RIFEMetal4BitRunnerImpl {
public:
    void SetCommandQueue(id<MTLCommandQueue> commandQueue);
    bool Load(const std::string& modelPath, uint32_t modelWidth, uint32_t modelHeight);
    bool IsReady() const { return ready_; }
    std::string Diagnostics() const { return diagnostics_; }
    Stellaria::Motion::RIFEMetal4BitRunResult RunTextures(id<MTLTexture> previousTexture,
                                                          id<MTLTexture> currentTexture,
                                                          id<MTLTexture> outputTexture,
                                                          uint32_t sourceWidth,
                                                          uint32_t sourceHeight);
    Stellaria::Motion::RIFEMetal4BitRunResult RunTexturesAtT(id<MTLTexture> previousTexture,
                                                             id<MTLTexture> currentTexture,
                                                             id<MTLTexture> outputTexture,
                                                             uint32_t sourceWidth,
                                                             uint32_t sourceHeight,
                                                             float t);

private:
    id<MTLDevice> device_ = nil;
    id<MTLCommandQueue> queue_ = nil;
    id<MTLComputePipelineState> flowPipeline_ = nil;
    id<MTLComputePipelineState> blendPipeline_ = nil;
    id<MTLBuffer> q4WeightPool_ = nil;
    id<MTLBuffer> scalePool_ = nil;
    id<MTLBuffer> biasPool_ = nil;
    id<MTLBuffer> layerDescBuffer_ = nil;
    id<MTLBuffer> flowMaskBuffer_ = nil;
    uint32_t modelWidth_ = 0;
    uint32_t modelHeight_ = 0;
    uint32_t layerCount_ = 0;
    uint32_t graphTensorCount_ = 0;
    bool ready_ = false;
    std::string diagnostics_ = "not loaded";
};

void RIFEMetal4BitRunnerImpl::SetCommandQueue(id<MTLCommandQueue> commandQueue) {
    if (commandQueue != nil) {
        queue_ = commandQueue;
        device_ = commandQueue.device ?: device_;
    }
}

bool RIFEMetal4BitRunnerImpl::Load(const std::string& modelPath, uint32_t modelWidth, uint32_t modelHeight) {
    ready_ = false;
    modelWidth_ = modelWidth;
    modelHeight_ = modelHeight;
    q4WeightPool_ = nil;
    scalePool_ = nil;
    biasPool_ = nil;
    layerDescBuffer_ = nil;
    flowPipeline_ = nil;
    blendPipeline_ = nil;
    flowMaskBuffer_ = nil;
    layerCount_ = 0;
    graphTensorCount_ = 0;

    if (modelWidth < 64 || modelHeight < 64) {
        diagnostics_ = "Metal INT4 RIFE requires model width/height >=64";
        return false;
    }

    if (device_ == nil) {
        device_ = MTLCreateSystemDefaultDevice();
    }
    if (queue_ == nil && device_ != nil) {
        queue_ = [device_ newCommandQueue];
    }
    if (device_ == nil || queue_ == nil) {
        diagnostics_ = "Metal INT4 RIFE device/queue unavailable";
        return false;
    }

    NSError* error = nil;
    NSURL* libraryURL = SMMotionKernelsURL();
    id<MTLLibrary> library = libraryURL != nil ? [device_ newLibraryWithURL:libraryURL error:&error] : nil;
    id<MTLFunction> flowFunction = [library newFunctionWithName:@"rife_metal4_int4_flow_mask"];
    id<MTLFunction> blendFunction = [library newFunctionWithName:@"rife_metal4_blend_flow_bgra"];
    flowPipeline_ = flowFunction != nil ? [device_ newComputePipelineStateWithFunction:flowFunction error:&error] : nil;
    blendPipeline_ = blendFunction != nil ? [device_ newComputePipelineStateWithFunction:blendFunction error:&error] : nil;
    if (flowPipeline_ == nil || blendPipeline_ == nil) {
        diagnostics_ = std::string("Metal INT4 RIFE kernel unavailable: ") +
            (error.localizedDescription.UTF8String ?: "MotionKernels.metallib missing");
        return false;
    }

    std::vector<uint8_t> q4Pool;
    std::vector<float> scalePool;
    std::vector<float> biasPool;
    std::vector<SMQ4LayerDescCPU> layers;
    uint32_t tensorCount = 0;
    std::string q4Error;
    if (!SMLoadRIFEGraphAsQ4(modelPath, &q4Pool, &scalePool, &biasPool, &layers, &tensorCount, &q4Error)) {
        diagnostics_ = "Metal INT4 RIFE full graph q4 pack failed: " + q4Error;
        return false;
    }

    q4WeightPool_ = SMMakePrivateBuffer(device_, queue_, q4Pool.data(), q4Pool.size());
    scalePool_ = SMMakePrivateBuffer(device_, queue_, scalePool.data(), scalePool.size() * sizeof(float));
    biasPool_ = SMMakePrivateBuffer(device_, queue_, biasPool.data(), biasPool.size() * sizeof(float));
    layerDescBuffer_ = SMMakePrivateBuffer(device_, queue_, layers.data(), layers.size() * sizeof(SMQ4LayerDescCPU));
    const NSUInteger flowMaskBytes = static_cast<NSUInteger>(modelWidth_) * modelHeight_ * 5 * sizeof(float);
    flowMaskBuffer_ = [device_ newBufferWithLength:flowMaskBytes options:MTLResourceStorageModePrivate];
    if (q4WeightPool_ == nil || scalePool_ == nil || biasPool_ == nil || layerDescBuffer_ == nil || flowMaskBuffer_ == nil) {
        diagnostics_ = "Metal INT4 RIFE private full-graph buffer upload failed";
        return false;
    }

    layerCount_ = static_cast<uint32_t>(layers.size());
    graphTensorCount_ = tensorCount;
    ready_ = true;
    std::ostringstream out;
    out << "RIFE Metal INT4 ready · "
        << modelWidth_ << "x" << modelHeight_
        << " · full graph tensors " << graphTensorCount_
        << " · q4 layers " << layerCount_
        << " · shader IFBlock 4/2/1";
    diagnostics_ = out.str();
    return true;
}

Stellaria::Motion::RIFEMetal4BitRunResult RIFEMetal4BitRunnerImpl::RunTextures(id<MTLTexture> previousTexture,
                                                                               id<MTLTexture> currentTexture,
                                                                               id<MTLTexture> outputTexture,
                                                                               uint32_t sourceWidth,
                                                                               uint32_t sourceHeight) {
    return RunTexturesAtT(previousTexture, currentTexture, outputTexture, sourceWidth, sourceHeight, 0.5f);
}

Stellaria::Motion::RIFEMetal4BitRunResult RIFEMetal4BitRunnerImpl::RunTexturesAtT(id<MTLTexture> previousTexture,
                                                                                  id<MTLTexture> currentTexture,
                                                                                  id<MTLTexture> outputTexture,
                                                                                  uint32_t sourceWidth,
                                                                                  uint32_t sourceHeight,
                                                                                  float t) {
    Stellaria::Motion::RIFEMetal4BitRunResult result;
    result.width = sourceWidth;
    result.height = sourceHeight;
    result.modelWidth = modelWidth_;
    result.modelHeight = modelHeight_;
    if (!ready_) {
        result.message = diagnostics_;
        return result;
    }
    if (previousTexture == nil || currentTexture == nil || outputTexture == nil) {
        result.message = "Metal INT4 RIFE texture missing";
        return result;
    }

    SMMIF4Params params{
        .width = sourceWidth,
        .height = sourceHeight,
        .modelWidth = modelWidth_,
        .modelHeight = modelHeight_,
        .layerCount = layerCount_,
        .graphTensorCount = graphTensorCount_,
        .activeBlockCount = 3,
        .reserved0 = 0,
        .flowGain = 5.0f,
        .nativeBlend = 0.025f,
        .t = std::max(0.0f, std::min(1.0f, t)),
        .reserved1 = 0.0f,
    };

    const CFTimeInterval start = CACurrentMediaTime();
    id<MTLCommandBuffer> commandBuffer = [queue_ commandBuffer];
    id<MTLComputeCommandEncoder> flow = [commandBuffer computeCommandEncoder];
    [flow setComputePipelineState:flowPipeline_];
    [flow setTexture:previousTexture atIndex:0];
    [flow setTexture:currentTexture atIndex:1];
    [flow setBuffer:flowMaskBuffer_ offset:0 atIndex:0];
    [flow setBuffer:q4WeightPool_ offset:0 atIndex:1];
    [flow setBuffer:scalePool_ offset:0 atIndex:2];
    [flow setBuffer:biasPool_ offset:0 atIndex:3];
    [flow setBuffer:layerDescBuffer_ offset:0 atIndex:4];
    [flow setBytes:&params length:sizeof(params) atIndex:5];
    [flow dispatchThreads:MTLSizeMake(modelWidth_, modelHeight_, 1) threadsPerThreadgroup:SMThreadgroup(flowPipeline_)];
    [flow endEncoding];

    id<MTLComputeCommandEncoder> blend = [commandBuffer computeCommandEncoder];
    [blend setComputePipelineState:blendPipeline_];
    [blend setTexture:previousTexture atIndex:0];
    [blend setTexture:currentTexture atIndex:1];
    [blend setTexture:outputTexture atIndex:2];
    [blend setBuffer:flowMaskBuffer_ offset:0 atIndex:0];
    [blend setBytes:&params length:sizeof(params) atIndex:1];
    [blend dispatchThreads:MTLSizeMake(sourceWidth, sourceHeight, 1) threadsPerThreadgroup:SMThreadgroup(blendPipeline_)];
    [blend endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    result.elapsedMs = (CACurrentMediaTime() - start) * 1000.0;
    result.ok = commandBuffer.status == MTLCommandBufferStatusCompleted;
    result.message = result.ok ? "RIFE Metal INT4 frame processed" : "RIFE Metal INT4 command failed";
    return result;
}

} // namespace

namespace Stellaria::Motion {

RIFEMetal4BitRunner::RIFEMetal4BitRunner()
    : impl_(new RIFEMetal4BitRunnerImpl()) {
}

RIFEMetal4BitRunner::~RIFEMetal4BitRunner() {
    delete static_cast<RIFEMetal4BitRunnerImpl*>(impl_);
}

void RIFEMetal4BitRunner::SetCommandQueue(void* commandQueue) {
    static_cast<RIFEMetal4BitRunnerImpl*>(impl_)->SetCommandQueue((__bridge id<MTLCommandQueue>)commandQueue);
}

bool RIFEMetal4BitRunner::Load(const std::string& modelPath, uint32_t modelWidth, uint32_t modelHeight) {
    return static_cast<RIFEMetal4BitRunnerImpl*>(impl_)->Load(modelPath, modelWidth, modelHeight);
}

bool RIFEMetal4BitRunner::IsReady() const {
    return static_cast<RIFEMetal4BitRunnerImpl*>(impl_)->IsReady();
}

std::string RIFEMetal4BitRunner::Diagnostics() const {
    return static_cast<RIFEMetal4BitRunnerImpl*>(impl_)->Diagnostics();
}

RIFEMetal4BitRunResult RIFEMetal4BitRunner::RunTextures(void* previousTexture,
                                                        void* currentTexture,
                                                        void* outputTexture,
                                                        uint32_t sourceWidth,
                                                        uint32_t sourceHeight) {
    return static_cast<RIFEMetal4BitRunnerImpl*>(impl_)->RunTextures((__bridge id<MTLTexture>)previousTexture,
                                                                     (__bridge id<MTLTexture>)currentTexture,
                                                                     (__bridge id<MTLTexture>)outputTexture,
                                                                     sourceWidth,
                                                                     sourceHeight);
}

RIFEMetal4BitRunResult RIFEMetal4BitRunner::RunTexturesAtT(void* previousTexture,
                                                           void* currentTexture,
                                                           void* outputTexture,
                                                           uint32_t sourceWidth,
                                                           uint32_t sourceHeight,
                                                           float t) {
    return static_cast<RIFEMetal4BitRunnerImpl*>(impl_)->RunTexturesAtT((__bridge id<MTLTexture>)previousTexture,
                                                                        (__bridge id<MTLTexture>)currentTexture,
                                                                        (__bridge id<MTLTexture>)outputTexture,
                                                                        sourceWidth,
                                                                        sourceHeight,
                                                                        t);
}

} // namespace Stellaria::Motion
