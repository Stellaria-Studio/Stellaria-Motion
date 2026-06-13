#include "VFI/RIFECoreMLRunner.h"

#import <CoreML/CoreML.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <sstream>

namespace {

using Stellaria::Motion::RIFEMPSGraphRunResult;

MLComputeUnits SMCoreMLDefaultComputeUnits() {
    return MLComputeUnitsAll;
}

MLComputeUnits SMCoreMLEfficiencyComputeUnits() {
    if (@available(macOS 12.0, *)) {
        return MLComputeUnitsCPUAndNeuralEngine;
    }
    return MLComputeUnitsAll;
}

const char* SMCoreMLComputeUnitsLabel(MLComputeUnits units) {
    switch (units) {
        case MLComputeUnitsCPUOnly:
            return "cpu";
        case MLComputeUnitsCPUAndGPU:
            return "cpu+gpu";
        case MLComputeUnitsAll:
            return "all";
        default:
            if (@available(macOS 12.0, *)) {
                if (units == MLComputeUnitsCPUAndNeuralEngine) {
                    return "cpu+ane";
                }
            }
            return "custom";
    }
}

NSArray<NSNumber*>* SMCoreMLShape(uint32_t height, uint32_t width, uint32_t channels) {
    return @[@1, @(height), @(width), @(channels)];
}

NSArray<NSNumber*>* SMCoreMLStrides(uint32_t height, uint32_t width, uint32_t channels) {
    return @[@(height * width * channels), @(width * channels), @(channels), @1];
}

NSString* SMCoreMLString(const std::string& value) {
    return [NSString stringWithUTF8String:value.c_str()];
}

std::string SMCoreMLErrorString(NSError* error) {
    NSString* description = error.localizedDescription;
    return std::string(description.UTF8String ?: "unknown");
}

bool SMShapeCompatible(NSArray<NSNumber*>* modelShape, NSArray<NSNumber*>* runtimeShape) {
    if (modelShape.count != runtimeShape.count) {
        return false;
    }
    for (NSUInteger i = 0; i < modelShape.count; ++i) {
        const NSInteger expected = [runtimeShape[i] integerValue];
        const NSInteger actual = [modelShape[i] integerValue];
        if (actual > 0 && actual != expected) {
            return false;
        }
    }
    return true;
}

NSString* SMFirstMultiArrayFeatureName(NSDictionary<NSString*, MLFeatureDescription*>* descriptions) {
    for (NSString* name in descriptions) {
        MLFeatureDescription* description = descriptions[name];
        if (description.type == MLFeatureTypeMultiArray) {
            return name;
        }
    }
    return nil;
}

float SMFloat16ToFloat(uint16_t half) {
    const uint32_t sign = (static_cast<uint32_t>(half & 0x8000U)) << 16U;
    uint32_t exponent = (half >> 10U) & 0x1FU;
    uint32_t mantissa = half & 0x03FFU;
    uint32_t value = 0;
    if (exponent == 0) {
        if (mantissa == 0) {
            value = sign;
        } else {
            exponent = 1;
            while ((mantissa & 0x0400U) == 0) {
                mantissa <<= 1U;
                --exponent;
            }
            mantissa &= 0x03FFU;
            value = sign | ((exponent + 112U) << 23U) | (mantissa << 13U);
        }
    } else if (exponent == 31U) {
        value = sign | 0x7F800000U | (mantissa << 13U);
    } else {
        value = sign | ((exponent + 112U) << 23U) | (mantissa << 13U);
    }
    float out = 0.0f;
    std::memcpy(&out, &value, sizeof(out));
    return out;
}

bool SMCopyMultiArrayToFloatBuffer(MLMultiArray* array, float* dst, NSUInteger height, NSUInteger width, NSUInteger channels) {
    if (array == nil || dst == nullptr || array.shape.count != 4 || array.strides.count != 4) {
        return false;
    }
    const NSUInteger expected[] = {1, height, width, channels};
    for (NSUInteger i = 0; i < 4; ++i) {
        const NSInteger dim = [array.shape[i] integerValue];
        if (dim > 0 && static_cast<NSUInteger>(dim) != expected[i]) {
            return false;
        }
    }
    const NSInteger s0 = [array.strides[0] integerValue];
    const NSInteger s1 = [array.strides[1] integerValue];
    const NSInteger s2 = [array.strides[2] integerValue];
    const NSInteger s3 = [array.strides[3] integerValue];
    if (s0 < 0 || s1 < 0 || s2 < 0 || s3 < 0) {
        return false;
    }
    const NSUInteger total = height * width * channels;
    if (array.dataType == MLMultiArrayDataTypeFloat32 &&
        s0 == static_cast<NSInteger>(total) &&
        s1 == static_cast<NSInteger>(width * channels) &&
        s2 == static_cast<NSInteger>(channels) &&
        s3 == 1) {
        std::memcpy(dst, array.dataPointer, total * sizeof(float));
        return true;
    }
    for (NSUInteger y = 0; y < height; ++y) {
        for (NSUInteger x = 0; x < width; ++x) {
            for (NSUInteger c = 0; c < channels; ++c) {
                const NSUInteger dstIndex = (y * width + x) * channels + c;
                const NSUInteger srcIndex = y * static_cast<NSUInteger>(s1) + x * static_cast<NSUInteger>(s2) + c * static_cast<NSUInteger>(s3);
                if (array.dataType == MLMultiArrayDataTypeFloat32) {
                    dst[dstIndex] = static_cast<float*>(array.dataPointer)[srcIndex];
                } else if (array.dataType == MLMultiArrayDataTypeFloat16) {
                    dst[dstIndex] = SMFloat16ToFloat(static_cast<uint16_t*>(array.dataPointer)[srcIndex]);
                } else if (array.dataType == MLMultiArrayDataTypeDouble) {
                    dst[dstIndex] = static_cast<float>(static_cast<double*>(array.dataPointer)[srcIndex]);
                } else {
                    return false;
                }
            }
        }
    }
    return true;
}

} // namespace

@interface SMRIFECoreMLFeatureProvider : NSObject<MLFeatureProvider>
- (instancetype)initWithName:(NSString*)name value:(MLFeatureValue*)value;
@end

@implementation SMRIFECoreMLFeatureProvider {
    NSDictionary<NSString*, MLFeatureValue*>* _features;
    NSSet<NSString*>* _featureNames;
}

- (instancetype)initWithName:(NSString*)name value:(MLFeatureValue*)value {
    self = [super init];
    if (self) {
        _features = @{name: value};
        _featureNames = [NSSet setWithObject:name];
    }
    return self;
}

- (NSSet<NSString*>*)featureNames {
    return _featureNames;
}

- (nullable MLFeatureValue*)featureValueForName:(NSString*)featureName {
    return _features[featureName];
}

@end

namespace {

class RIFECoreMLRunnerImpl {
public:
    bool Load(const std::string& modelPath, uint32_t width, uint32_t height);
    bool IsReady() const { return ready_; }
    std::string Diagnostics() const { return diagnostics_; }
    RIFEMPSGraphRunResult RunWithBuffers(id<MTLBuffer> inputBuffer, id<MTLBuffer> outputBuffer);

private:
    __strong MLModel* model_ = nil;
    __strong NSString* inputName_ = nil;
    __strong NSString* outputName_ = nil;
    __strong NSArray<NSNumber*>* inputShape_ = nil;
    __strong NSArray<NSNumber*>* outputShape_ = nil;
    __strong NSArray<NSNumber*>* inputStrides_ = nil;
    __strong NSArray<NSNumber*>* outputStrides_ = nil;
    __strong MLMultiArray* cachedInputArray_ = nil;
    __strong MLMultiArray* cachedOutputArray_ = nil;
    __strong MLFeatureValue* cachedInputValue_ = nil;
    __strong MLFeatureValue* cachedOutputValue_ = nil;
    __strong SMRIFECoreMLFeatureProvider* cachedProvider_ = nil;
    __strong MLPredictionOptions* cachedOptions_ = nil;
    void* cachedInputPointer_ = nullptr;
    void* cachedOutputPointer_ = nullptr;
    uint32_t width_ = 0;
    uint32_t height_ = 0;
    bool ready_ = false;
    std::string diagnostics_ = "not loaded";
};

class RIFECoreMLBlockRunnerImpl {
public:
    bool Load(const std::string& modelPath, uint32_t width, uint32_t height);
    bool IsReady() const { return ready_; }
    std::string Diagnostics() const { return diagnostics_; }
    RIFEMPSGraphRunResult RunWithBuffers(id<MTLBuffer> xBuffer, id<MTLBuffer> flowBuffer, id<MTLBuffer> outputBuffer);

private:
    __strong MLModel* model_ = nil;
    __strong NSString* xInputName_ = nil;
    __strong NSString* flowInputName_ = nil;
    __strong NSString* outputName_ = nil;
    __strong NSArray<NSNumber*>* xShape_ = nil;
    __strong NSArray<NSNumber*>* flowShape_ = nil;
    __strong NSArray<NSNumber*>* outputShape_ = nil;
    __strong NSArray<NSNumber*>* xStrides_ = nil;
    __strong NSArray<NSNumber*>* flowStrides_ = nil;
    __strong NSArray<NSNumber*>* outputStrides_ = nil;
    __strong MLMultiArray* cachedXArray_ = nil;
    __strong MLMultiArray* cachedFlowArray_ = nil;
    __strong MLMultiArray* cachedOutputArray_ = nil;
    __strong MLFeatureValue* cachedXValue_ = nil;
    __strong MLFeatureValue* cachedFlowValue_ = nil;
    __strong MLFeatureValue* cachedOutputValue_ = nil;
    __strong MLDictionaryFeatureProvider* cachedProvider_ = nil;
    __strong MLPredictionOptions* cachedOptions_ = nil;
    void* cachedXPointer_ = nullptr;
    void* cachedFlowPointer_ = nullptr;
    void* cachedOutputPointer_ = nullptr;
    uint32_t width_ = 0;
    uint32_t height_ = 0;
    bool ready_ = false;
    std::string diagnostics_ = "not loaded";
};

class RIFECoreMLFlowMaskRunnerImpl {
public:
    bool Load(const std::string& modelPath, uint32_t width, uint32_t height);
    bool IsReady() const { return ready_; }
    std::string Diagnostics() const { return diagnostics_; }
    RIFEMPSGraphRunResult RunWithBuffers(id<MTLBuffer> inputBuffer, id<MTLBuffer> outputBuffer);

private:
    __strong MLModel* model_ = nil;
    __strong NSString* inputName_ = nil;
    __strong NSString* outputName_ = nil;
    __strong NSArray<NSNumber*>* inputShape_ = nil;
    __strong NSArray<NSNumber*>* outputShape_ = nil;
    __strong NSArray<NSNumber*>* inputStrides_ = nil;
    __strong NSArray<NSNumber*>* outputStrides_ = nil;
    __strong MLMultiArray* cachedInputArray_ = nil;
    __strong MLMultiArray* cachedOutputArray_ = nil;
    __strong MLFeatureValue* cachedInputValue_ = nil;
    __strong MLFeatureValue* cachedOutputValue_ = nil;
    __strong SMRIFECoreMLFeatureProvider* cachedProvider_ = nil;
    __strong MLPredictionOptions* cachedOptions_ = nil;
    void* cachedInputPointer_ = nullptr;
    void* cachedOutputPointer_ = nullptr;
    uint32_t width_ = 0;
    uint32_t height_ = 0;
    bool ready_ = false;
    std::string diagnostics_ = "not loaded";
};

bool RIFECoreMLRunnerImpl::Load(const std::string& modelPath, uint32_t width, uint32_t height) {
    ready_ = false;
    model_ = nil;
    inputName_ = nil;
    outputName_ = nil;
    cachedInputArray_ = nil;
    cachedOutputArray_ = nil;
    cachedInputValue_ = nil;
    cachedOutputValue_ = nil;
    cachedProvider_ = nil;
    cachedOptions_ = nil;
    cachedInputPointer_ = nullptr;
    cachedOutputPointer_ = nullptr;
    inputShape_ = SMCoreMLShape(height, width, 6);
    outputShape_ = SMCoreMLShape(height, width, 3);
    inputStrides_ = SMCoreMLStrides(height, width, 6);
    outputStrides_ = SMCoreMLStrides(height, width, 3);
    width_ = width;
    height_ = height;

    NSString* path = SMCoreMLString(modelPath);
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        diagnostics_ = "CoreML RIFE model missing";
        return false;
    }

    NSURL* modelURL = [NSURL fileURLWithPath:path];
    NSURL* loadURL = modelURL;
    NSError* error = nil;
    NSString* extension = path.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"mlmodel"] || [extension isEqualToString:@"mlpackage"]) {
        loadURL = [MLModel compileModelAtURL:modelURL error:&error];
        if (loadURL == nil) {
            diagnostics_ = "CoreML RIFE compile failed: " + SMCoreMLErrorString(error);
            return false;
        }
    }

    MLModelConfiguration* configuration = [[MLModelConfiguration alloc] init];
    const MLComputeUnits computeUnits = SMCoreMLDefaultComputeUnits();
    configuration.computeUnits = computeUnits;
    model_ = [MLModel modelWithContentsOfURL:loadURL configuration:configuration error:&error];
    if (model_ == nil) {
        diagnostics_ = "CoreML RIFE load failed: " + SMCoreMLErrorString(error);
        return false;
    }

    inputName_ = SMFirstMultiArrayFeatureName(model_.modelDescription.inputDescriptionsByName);
    outputName_ = SMFirstMultiArrayFeatureName(model_.modelDescription.outputDescriptionsByName);
    if (inputName_ == nil || outputName_ == nil) {
        diagnostics_ = "CoreML RIFE requires MultiArray input/output";
        return false;
    }

    MLFeatureDescription* inputDescription = model_.modelDescription.inputDescriptionsByName[inputName_];
    MLFeatureDescription* outputDescription = model_.modelDescription.outputDescriptionsByName[outputName_];
    NSArray<NSNumber*>* modelInputShape = inputDescription.multiArrayConstraint.shape;
    NSArray<NSNumber*>* modelOutputShape = outputDescription.multiArrayConstraint.shape;
    if (!SMShapeCompatible(modelInputShape, inputShape_)) {
        diagnostics_ = "CoreML RIFE input must be NHWC [1,H,W,6]; current pack avoids CPU NCHW transpose";
        return false;
    }
    if (!SMShapeCompatible(modelOutputShape, outputShape_)) {
        diagnostics_ = "CoreML RIFE output must be NHWC [1,H,W,3] for Metal unpack";
        return false;
    }

    std::ostringstream out;
    out << "CoreML RIFE ready · "
        << inputName_.UTF8String << "->" << outputName_.UTF8String
        << " · " << width_ << "x" << height_
        << " · computeUnits=" << SMCoreMLComputeUnitsLabel(computeUnits);
    diagnostics_ = out.str();
    ready_ = true;
    return true;
}

RIFEMPSGraphRunResult RIFECoreMLRunnerImpl::RunWithBuffers(id<MTLBuffer> inputBuffer, id<MTLBuffer> outputBuffer) {
    RIFEMPSGraphRunResult result;
    result.width = width_;
    result.height = height_;
    result.outputChannels = 3;
    if (!ready_ || inputBuffer == nil || outputBuffer == nil) {
        result.message = "CoreML RIFE is not ready";
        return result;
    }

    NSError* error = nil;
    CFTimeInterval start = CACurrentMediaTime();
    void* inputPointer = inputBuffer.contents;
    if (cachedInputArray_ == nil || cachedInputPointer_ != inputPointer) {
        cachedInputArray_ = [[MLMultiArray alloc] initWithDataPointer:inputPointer
                                                                shape:inputShape_
                                                             dataType:MLMultiArrayDataTypeFloat32
                                                              strides:inputStrides_
                                                          deallocator:^(void*) {}
                                                                error:&error];
        if (cachedInputArray_ == nil) {
            result.message = "CoreML RIFE input array failed: " + SMCoreMLErrorString(error);
            return result;
        }
        cachedInputValue_ = [MLFeatureValue featureValueWithMultiArray:cachedInputArray_];
        cachedProvider_ = [[SMRIFECoreMLFeatureProvider alloc] initWithName:inputName_ value:cachedInputValue_];
        cachedInputPointer_ = inputPointer;
    }

    void* outputPointer = outputBuffer.contents;
    if (cachedOutputArray_ == nil || cachedOutputPointer_ != outputPointer) {
        cachedOutputArray_ = [[MLMultiArray alloc] initWithDataPointer:outputPointer
                                                                 shape:outputShape_
                                                              dataType:MLMultiArrayDataTypeFloat32
                                                               strides:outputStrides_
                                                           deallocator:^(void*) {}
                                                                 error:&error];
        if (cachedOutputArray_ != nil) {
            cachedOutputValue_ = [MLFeatureValue featureValueWithMultiArray:cachedOutputArray_];
            cachedOptions_ = [MLPredictionOptions new];
            cachedOptions_.outputBackings = @{outputName_: cachedOutputValue_};
            cachedOutputPointer_ = outputPointer;
        } else {
            cachedOutputValue_ = nil;
            cachedOptions_ = nil;
            cachedOutputPointer_ = nullptr;
        }
    }

    id<MLFeatureProvider> output = cachedOptions_ != nil
        ? [model_ predictionFromFeatures:cachedProvider_ options:cachedOptions_ error:&error]
        : [model_ predictionFromFeatures:cachedProvider_ error:&error];
    if (output == nil) {
        result.message = "CoreML RIFE prediction failed: " + SMCoreMLErrorString(error);
        return result;
    }
    MLMultiArray* outputArray = [output featureValueForName:outputName_].multiArrayValue;
    if (outputArray == nil || !SMShapeCompatible(outputArray.shape, outputShape_)) {
        result.message = "CoreML RIFE output shape mismatch";
        return result;
    }

    if (outputArray.dataPointer != outputBuffer.contents &&
        !SMCopyMultiArrayToFloatBuffer(outputArray, static_cast<float*>(outputBuffer.contents), height_, width_, 3)) {
        result.message = "CoreML RIFE output copy failed";
        return result;
    }
    result.elapsedMs = (CACurrentMediaTime() - start) * 1000.0;
    result.ok = true;
    result.message = "CoreML RIFE frame processed";
    return result;
}

bool RIFECoreMLFlowMaskRunnerImpl::Load(const std::string& modelPath, uint32_t width, uint32_t height) {
    ready_ = false;
    model_ = nil;
    inputName_ = nil;
    outputName_ = nil;
    cachedInputArray_ = nil;
    cachedOutputArray_ = nil;
    cachedInputValue_ = nil;
    cachedOutputValue_ = nil;
    cachedProvider_ = nil;
    cachedOptions_ = nil;
    cachedInputPointer_ = nullptr;
    cachedOutputPointer_ = nullptr;
    inputShape_ = SMCoreMLShape(height, width, 6);
    outputShape_ = SMCoreMLShape(height, width, 5);
    inputStrides_ = SMCoreMLStrides(height, width, 6);
    outputStrides_ = SMCoreMLStrides(height, width, 5);
    width_ = width;
    height_ = height;

    NSString* path = SMCoreMLString(modelPath);
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        diagnostics_ = "CoreML continuous RIFE flow-mask model missing";
        return false;
    }

    NSURL* modelURL = [NSURL fileURLWithPath:path];
    NSURL* loadURL = modelURL;
    NSError* error = nil;
    NSString* extension = path.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"mlmodel"] || [extension isEqualToString:@"mlpackage"]) {
        loadURL = [MLModel compileModelAtURL:modelURL error:&error];
        if (loadURL == nil) {
            diagnostics_ = "CoreML continuous RIFE compile failed: " + SMCoreMLErrorString(error);
            return false;
        }
    }

    MLModelConfiguration* configuration = [[MLModelConfiguration alloc] init];
    const MLComputeUnits computeUnits = SMCoreMLEfficiencyComputeUnits();
    configuration.computeUnits = computeUnits;
    model_ = [MLModel modelWithContentsOfURL:loadURL configuration:configuration error:&error];
    if (model_ == nil) {
        diagnostics_ = "CoreML continuous RIFE load failed: " + SMCoreMLErrorString(error);
        return false;
    }

    NSDictionary<NSString*, MLFeatureDescription*>* inputs = model_.modelDescription.inputDescriptionsByName;
    inputName_ = inputs[@"pair_nhwc"] != nil ? @"pair_nhwc" : (inputs[@"input_nhwc"] != nil ? @"input_nhwc" : SMFirstMultiArrayFeatureName(inputs));
    outputName_ = model_.modelDescription.outputDescriptionsByName[@"flow_mask_nhwc"] != nil
        ? @"flow_mask_nhwc"
        : SMFirstMultiArrayFeatureName(model_.modelDescription.outputDescriptionsByName);
    if (inputName_ == nil || outputName_ == nil) {
        diagnostics_ = "CoreML continuous RIFE requires pair_nhwc/input_nhwc and flow_mask_nhwc MultiArrays";
        return false;
    }

    MLFeatureDescription* inputDescription = model_.modelDescription.inputDescriptionsByName[inputName_];
    MLFeatureDescription* outputDescription = model_.modelDescription.outputDescriptionsByName[outputName_];
    if (!SMShapeCompatible(inputDescription.multiArrayConstraint.shape, inputShape_)) {
        diagnostics_ = "CoreML continuous RIFE input must be NHWC [1,H,W,6]";
        return false;
    }
    if (!SMShapeCompatible(outputDescription.multiArrayConstraint.shape, outputShape_)) {
        diagnostics_ = "CoreML continuous RIFE output must be NHWC [1,H,W,5]";
        return false;
    }

    std::ostringstream out;
    out << "CoreML continuous RIFE ready · "
        << inputName_.UTF8String << "->" << outputName_.UTF8String
        << " · " << width_ << "x" << height_
        << " · computeUnits=" << SMCoreMLComputeUnitsLabel(computeUnits);
    diagnostics_ = out.str();
    ready_ = true;
    return true;
}

RIFEMPSGraphRunResult RIFECoreMLFlowMaskRunnerImpl::RunWithBuffers(id<MTLBuffer> inputBuffer, id<MTLBuffer> outputBuffer) {
    RIFEMPSGraphRunResult result;
    result.width = width_;
    result.height = height_;
    result.outputChannels = 5;
    if (!ready_ || inputBuffer == nil || outputBuffer == nil) {
        result.message = "CoreML continuous RIFE is not ready";
        return result;
    }

    NSError* error = nil;
    CFTimeInterval start = CACurrentMediaTime();
    void* inputPointer = inputBuffer.contents;
    if (cachedInputArray_ == nil || cachedInputPointer_ != inputPointer) {
        cachedInputArray_ = [[MLMultiArray alloc] initWithDataPointer:inputPointer
                                                                shape:inputShape_
                                                             dataType:MLMultiArrayDataTypeFloat32
                                                              strides:inputStrides_
                                                          deallocator:^(void*) {}
                                                                error:&error];
        if (cachedInputArray_ == nil) {
            result.message = "CoreML continuous RIFE input array failed: " + SMCoreMLErrorString(error);
            return result;
        }
        cachedInputValue_ = [MLFeatureValue featureValueWithMultiArray:cachedInputArray_];
        cachedProvider_ = [[SMRIFECoreMLFeatureProvider alloc] initWithName:inputName_ value:cachedInputValue_];
        cachedInputPointer_ = inputPointer;
    }

    void* outputPointer = outputBuffer.contents;
    if (cachedOutputArray_ == nil || cachedOutputPointer_ != outputPointer) {
        cachedOutputArray_ = [[MLMultiArray alloc] initWithDataPointer:outputPointer
                                                                 shape:outputShape_
                                                              dataType:MLMultiArrayDataTypeFloat32
                                                               strides:outputStrides_
                                                           deallocator:^(void*) {}
                                                                 error:&error];
        if (cachedOutputArray_ != nil) {
            cachedOutputValue_ = [MLFeatureValue featureValueWithMultiArray:cachedOutputArray_];
            cachedOptions_ = [MLPredictionOptions new];
            cachedOptions_.outputBackings = @{outputName_: cachedOutputValue_};
            cachedOutputPointer_ = outputPointer;
        } else {
            cachedOutputValue_ = nil;
            cachedOptions_ = nil;
            cachedOutputPointer_ = nullptr;
        }
    }

    id<MLFeatureProvider> prediction = cachedOptions_ != nil
        ? [model_ predictionFromFeatures:cachedProvider_ options:cachedOptions_ error:&error]
        : [model_ predictionFromFeatures:cachedProvider_ error:&error];
    if (prediction == nil) {
        result.message = "CoreML continuous RIFE prediction failed: " + SMCoreMLErrorString(error);
        return result;
    }
    MLMultiArray* outputArray = [prediction featureValueForName:outputName_].multiArrayValue;
    if (outputArray == nil || !SMShapeCompatible(outputArray.shape, outputShape_)) {
        result.message = "CoreML continuous RIFE output shape mismatch";
        return result;
    }

    if (outputArray.dataPointer != outputBuffer.contents &&
        !SMCopyMultiArrayToFloatBuffer(outputArray, static_cast<float*>(outputBuffer.contents), height_, width_, 5)) {
        result.message = "CoreML continuous RIFE output copy failed";
        return result;
    }
    result.elapsedMs = (CACurrentMediaTime() - start) * 1000.0;
    result.ok = true;
    result.message = "CoreML continuous RIFE flow-mask processed";
    return result;
}

bool RIFECoreMLBlockRunnerImpl::Load(const std::string& modelPath, uint32_t width, uint32_t height) {
    ready_ = false;
    model_ = nil;
    xInputName_ = nil;
    flowInputName_ = nil;
    outputName_ = nil;
    cachedXArray_ = nil;
    cachedFlowArray_ = nil;
    cachedOutputArray_ = nil;
    cachedXValue_ = nil;
    cachedFlowValue_ = nil;
    cachedOutputValue_ = nil;
    cachedProvider_ = nil;
    cachedOptions_ = nil;
    cachedXPointer_ = nullptr;
    cachedFlowPointer_ = nullptr;
    cachedOutputPointer_ = nullptr;
    xShape_ = SMCoreMLShape(height, width, 7);
    flowShape_ = SMCoreMLShape(height, width, 4);
    outputShape_ = SMCoreMLShape(height, width, 5);
    xStrides_ = SMCoreMLStrides(height, width, 7);
    flowStrides_ = SMCoreMLStrides(height, width, 4);
    outputStrides_ = SMCoreMLStrides(height, width, 5);
    width_ = width;
    height_ = height;

    NSString* path = SMCoreMLString(modelPath);
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        diagnostics_ = "CoreML RIFE block model missing";
        return false;
    }

    NSURL* modelURL = [NSURL fileURLWithPath:path];
    NSURL* loadURL = modelURL;
    NSError* error = nil;
    NSString* extension = path.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"mlmodel"] || [extension isEqualToString:@"mlpackage"]) {
        loadURL = [MLModel compileModelAtURL:modelURL error:&error];
        if (loadURL == nil) {
            diagnostics_ = "CoreML RIFE block compile failed: " + SMCoreMLErrorString(error);
            return false;
        }
    }

    MLModelConfiguration* configuration = [[MLModelConfiguration alloc] init];
    const MLComputeUnits computeUnits = SMCoreMLDefaultComputeUnits();
    configuration.computeUnits = computeUnits;
    model_ = [MLModel modelWithContentsOfURL:loadURL configuration:configuration error:&error];
    if (model_ == nil) {
        diagnostics_ = "CoreML RIFE block load failed: " + SMCoreMLErrorString(error);
        return false;
    }

    NSDictionary<NSString*, MLFeatureDescription*>* inputs = model_.modelDescription.inputDescriptionsByName;
    xInputName_ = inputs[@"x_nhwc"] != nil ? @"x_nhwc" : nil;
    flowInputName_ = inputs[@"flow_nhwc"] != nil ? @"flow_nhwc" : nil;
    if (xInputName_ == nil || flowInputName_ == nil) {
        NSMutableArray<NSString*>* multiArrayNames = [NSMutableArray array];
        for (NSString* name in inputs) {
            if (inputs[name].type == MLFeatureTypeMultiArray) {
                [multiArrayNames addObject:name];
            }
        }
        if (multiArrayNames.count >= 2) {
            xInputName_ = multiArrayNames[0];
            flowInputName_ = multiArrayNames[1];
        }
    }
    outputName_ = model_.modelDescription.outputDescriptionsByName[@"flow_mask_nhwc"] != nil
        ? @"flow_mask_nhwc"
        : SMFirstMultiArrayFeatureName(model_.modelDescription.outputDescriptionsByName);
    if (xInputName_ == nil || flowInputName_ == nil || outputName_ == nil) {
        diagnostics_ = "CoreML RIFE block requires x_nhwc, flow_nhwc, flow_mask_nhwc MultiArrays";
        return false;
    }

    if (!SMShapeCompatible(inputs[xInputName_].multiArrayConstraint.shape, xShape_) ||
        !SMShapeCompatible(inputs[flowInputName_].multiArrayConstraint.shape, flowShape_) ||
        !SMShapeCompatible(model_.modelDescription.outputDescriptionsByName[outputName_].multiArrayConstraint.shape, outputShape_)) {
        diagnostics_ = "CoreML RIFE block shape mismatch for NHWC [1,H,W,7]+[1,H,W,4]->[1,H,W,5]";
        return false;
    }

    std::ostringstream out;
    out << "CoreML RIFE block ready · " << width_ << "x" << height_
        << " · computeUnits=" << SMCoreMLComputeUnitsLabel(computeUnits);
    diagnostics_ = out.str();
    ready_ = true;
    return true;
}

RIFEMPSGraphRunResult RIFECoreMLBlockRunnerImpl::RunWithBuffers(id<MTLBuffer> xBuffer, id<MTLBuffer> flowBuffer, id<MTLBuffer> outputBuffer) {
    RIFEMPSGraphRunResult result;
    result.width = width_;
    result.height = height_;
    result.outputChannels = 5;
    if (!ready_ || xBuffer == nil || flowBuffer == nil || outputBuffer == nil) {
        result.message = "CoreML RIFE block is not ready";
        return result;
    }

    NSError* error = nil;
    CFTimeInterval start = CACurrentMediaTime();
    void* xPointer = xBuffer.contents;
    void* flowPointer = flowBuffer.contents;
    if (cachedProvider_ == nil || cachedXPointer_ != xPointer || cachedFlowPointer_ != flowPointer) {
        cachedXArray_ = [[MLMultiArray alloc] initWithDataPointer:xPointer
                                                            shape:xShape_
                                                         dataType:MLMultiArrayDataTypeFloat32
                                                          strides:xStrides_
                                                      deallocator:^(void*) {}
                                                            error:&error];
        if (cachedXArray_ == nil) {
            result.message = "CoreML RIFE block x array failed: " + SMCoreMLErrorString(error);
            return result;
        }
        cachedFlowArray_ = [[MLMultiArray alloc] initWithDataPointer:flowPointer
                                                               shape:flowShape_
                                                            dataType:MLMultiArrayDataTypeFloat32
                                                             strides:flowStrides_
                                                         deallocator:^(void*) {}
                                                               error:&error];
        if (cachedFlowArray_ == nil) {
            result.message = "CoreML RIFE block flow array failed: " + SMCoreMLErrorString(error);
            return result;
        }
        cachedXValue_ = [MLFeatureValue featureValueWithMultiArray:cachedXArray_];
        cachedFlowValue_ = [MLFeatureValue featureValueWithMultiArray:cachedFlowArray_];
        NSDictionary<NSString*, MLFeatureValue*>* featureValues = @{
            xInputName_: cachedXValue_,
            flowInputName_: cachedFlowValue_,
        };
        NSError* providerError = nil;
        cachedProvider_ = [[MLDictionaryFeatureProvider alloc] initWithDictionary:featureValues error:&providerError];
        if (cachedProvider_ == nil) {
            result.message = "CoreML RIFE block provider failed: " + SMCoreMLErrorString(providerError);
            return result;
        }
        cachedXPointer_ = xPointer;
        cachedFlowPointer_ = flowPointer;
    }
    void* outputPointer = outputBuffer.contents;
    if (cachedOutputArray_ == nil || cachedOutputPointer_ != outputPointer) {
        cachedOutputArray_ = [[MLMultiArray alloc] initWithDataPointer:outputPointer
                                                                 shape:outputShape_
                                                              dataType:MLMultiArrayDataTypeFloat32
                                                               strides:outputStrides_
                                                           deallocator:^(void*) {}
                                                                 error:&error];
        if (cachedOutputArray_ != nil) {
            cachedOutputValue_ = [MLFeatureValue featureValueWithMultiArray:cachedOutputArray_];
            cachedOptions_ = [MLPredictionOptions new];
            cachedOptions_.outputBackings = @{outputName_: cachedOutputValue_};
            cachedOutputPointer_ = outputPointer;
        } else {
            cachedOutputValue_ = nil;
            cachedOptions_ = nil;
            cachedOutputPointer_ = nullptr;
        }
    }

    id<MLFeatureProvider> prediction = cachedOptions_ != nil
        ? [model_ predictionFromFeatures:cachedProvider_ options:cachedOptions_ error:&error]
        : [model_ predictionFromFeatures:cachedProvider_ error:&error];
    if (prediction == nil) {
        result.message = "CoreML RIFE block prediction failed: " + SMCoreMLErrorString(error);
        return result;
    }
    MLMultiArray* outputArray = [prediction featureValueForName:outputName_].multiArrayValue;
    if (outputArray == nil || !SMShapeCompatible(outputArray.shape, outputShape_)) {
        result.message = "CoreML RIFE block output shape mismatch";
        return result;
    }

    if (outputArray.dataPointer != outputBuffer.contents &&
        !SMCopyMultiArrayToFloatBuffer(outputArray, static_cast<float*>(outputBuffer.contents), height_, width_, 5)) {
        result.message = "CoreML RIFE block output copy failed";
        return result;
    }
    result.elapsedMs = (CACurrentMediaTime() - start) * 1000.0;
    result.ok = true;
    result.message = "CoreML RIFE block processed";
    return result;
}

} // namespace

namespace Stellaria::Motion {

RIFECoreMLRunner::RIFECoreMLRunner()
    : impl_(new RIFECoreMLRunnerImpl()) {
}

RIFECoreMLRunner::~RIFECoreMLRunner() {
    delete static_cast<RIFECoreMLRunnerImpl*>(impl_);
}

bool RIFECoreMLRunner::Load(const std::string& modelPath, uint32_t width, uint32_t height) {
    return static_cast<RIFECoreMLRunnerImpl*>(impl_)->Load(modelPath, width, height);
}

bool RIFECoreMLRunner::IsReady() const {
    return static_cast<RIFECoreMLRunnerImpl*>(impl_)->IsReady();
}

std::string RIFECoreMLRunner::Diagnostics() const {
    return static_cast<RIFECoreMLRunnerImpl*>(impl_)->Diagnostics();
}

RIFEMPSGraphRunResult RIFECoreMLRunner::RunWithBuffers(void* inputMTLBuffer, void* outputMTLBuffer) {
    return static_cast<RIFECoreMLRunnerImpl*>(impl_)->RunWithBuffers((__bridge id<MTLBuffer>)inputMTLBuffer,
                                                                     (__bridge id<MTLBuffer>)outputMTLBuffer);
}

RIFECoreMLBlockRunner::RIFECoreMLBlockRunner()
    : impl_(new RIFECoreMLBlockRunnerImpl()) {
}

RIFECoreMLBlockRunner::~RIFECoreMLBlockRunner() {
    delete static_cast<RIFECoreMLBlockRunnerImpl*>(impl_);
}

bool RIFECoreMLBlockRunner::Load(const std::string& modelPath, uint32_t width, uint32_t height) {
    return static_cast<RIFECoreMLBlockRunnerImpl*>(impl_)->Load(modelPath, width, height);
}

bool RIFECoreMLBlockRunner::IsReady() const {
    return static_cast<RIFECoreMLBlockRunnerImpl*>(impl_)->IsReady();
}

std::string RIFECoreMLBlockRunner::Diagnostics() const {
    return static_cast<RIFECoreMLBlockRunnerImpl*>(impl_)->Diagnostics();
}

RIFEMPSGraphRunResult RIFECoreMLBlockRunner::RunWithBuffers(void* xMTLBuffer, void* flowMTLBuffer, void* outputMTLBuffer) {
    return static_cast<RIFECoreMLBlockRunnerImpl*>(impl_)->RunWithBuffers((__bridge id<MTLBuffer>)xMTLBuffer,
                                                                         (__bridge id<MTLBuffer>)flowMTLBuffer,
                                                                         (__bridge id<MTLBuffer>)outputMTLBuffer);
}

RIFECoreMLFlowMaskRunner::RIFECoreMLFlowMaskRunner()
    : impl_(new RIFECoreMLFlowMaskRunnerImpl()) {
}

RIFECoreMLFlowMaskRunner::~RIFECoreMLFlowMaskRunner() {
    delete static_cast<RIFECoreMLFlowMaskRunnerImpl*>(impl_);
}

bool RIFECoreMLFlowMaskRunner::Load(const std::string& modelPath, uint32_t width, uint32_t height) {
    return static_cast<RIFECoreMLFlowMaskRunnerImpl*>(impl_)->Load(modelPath, width, height);
}

bool RIFECoreMLFlowMaskRunner::IsReady() const {
    return static_cast<RIFECoreMLFlowMaskRunnerImpl*>(impl_)->IsReady();
}

std::string RIFECoreMLFlowMaskRunner::Diagnostics() const {
    return static_cast<RIFECoreMLFlowMaskRunnerImpl*>(impl_)->Diagnostics();
}

RIFEMPSGraphRunResult RIFECoreMLFlowMaskRunner::RunWithBuffers(void* inputMTLBuffer, void* outputMTLBuffer) {
    return static_cast<RIFECoreMLFlowMaskRunnerImpl*>(impl_)->RunWithBuffers((__bridge id<MTLBuffer>)inputMTLBuffer,
                                                                             (__bridge id<MTLBuffer>)outputMTLBuffer);
}

} // namespace Stellaria::Motion
