#include "VFI/RIFEMPSGraphRunner.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShadersGraph/MetalPerformanceShadersGraph.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>
#include <sstream>
#include <vector>

namespace {

using Stellaria::Motion::RIFEMPSGraphRunResult;

NSArray<NSNumber*>* SMShape(std::initializer_list<int64_t> values) {
    NSMutableArray<NSNumber*>* out = [NSMutableArray arrayWithCapacity:values.size()];
    for (int64_t value : values) {
        [out addObject:@(value)];
    }
    return out;
}

NSData* SMInt32Data(std::initializer_list<int32_t> values) {
    return [NSData dataWithBytes:values.begin() length:values.size() * sizeof(int32_t)];
}

NSData* SMFloatData(std::initializer_list<float> values) {
    return [NSData dataWithBytes:values.begin() length:values.size() * sizeof(float)];
}

NSString* SMNSString(const std::string& value) {
    return [NSString stringWithUTF8String:value.c_str()];
}

class RIFEMPSGraphRunnerImpl {
public:
    bool Load(const std::string& modelPath, uint32_t width, uint32_t height);
    bool IsReady() const { return ready_; }
    std::string Diagnostics() const { return diagnostics_; }
    bool HasMetal4MachineLearningAPI() const;
    void SetCommandQueue(id<MTLCommandQueue> commandQueue);
    RIFEMPSGraphRunResult RunZeroInput();
    RIFEMPSGraphRunResult RunWithBuffers(id<MTLBuffer> inputBuffer, id<MTLBuffer> outputBuffer);

private:
    MPSGraphTensor* Constant(const std::string& name);
    MPSGraphTensor* Scalar(float value, NSString* name);
    MPSGraphTensor* SizeTensor(int32_t height, int32_t width, NSString* name);
    MPSGraphTensor* Conv(MPSGraphTensor* input,
                         const std::string& prefix,
                         NSUInteger stride,
                         bool activation,
                         NSString* name);
    MPSGraphTensor* Deconv(MPSGraphTensor* input,
                           const std::string& prefix,
                           uint32_t outHeight,
                           uint32_t outWidth,
                           uint32_t outChannels,
                           bool activation,
                           NSString* name);
    MPSGraphTensor* PReLU(MPSGraphTensor* input, const std::string& slopeName, NSString* name);
    MPSGraphTensor* Resize(MPSGraphTensor* input, uint32_t height, uint32_t width, NSString* name);
    MPSGraphTensor* SliceC(MPSGraphTensor* input, NSInteger start, NSInteger length, NSString* name);
    MPSGraphTensor* IFBlock(const std::string& block,
                            MPSGraphTensor* x,
                            MPSGraphTensor* flow,
                            uint32_t scale,
                            MPSGraphTensor** maskOut);
    MPSGraphTensor* Warp(MPSGraphTensor* image, MPSGraphTensor* flow, NSString* name);
    MPSGraphTensor* BuildGraph();

    NSMutableDictionary<NSString*, NSData*>* weights_ = nil;
    NSMutableDictionary<NSString*, NSArray<NSNumber*>*>* shapes_ = nil;
    MPSGraph* graph_ = nil;
    MPSGraphTensor* input_ = nil;
    MPSGraphTensor* output_ = nil;
    MPSGraphTensorData* zeroInput_ = nil;
    MPSGraphTensorData* cachedInputData_ = nil;
    MPSGraphTensorData* cachedOutputData_ = nil;
    NSDictionary* cachedFeeds_ = nil;
    NSDictionary* cachedResults_ = nil;
    __strong id<MTLBuffer> cachedInputBuffer_ = nil;
    __strong id<MTLBuffer> cachedOutputBuffer_ = nil;
    id<MTLDevice> device_ = nil;
    id<MTLCommandQueue> queue_ = nil;
    uint32_t width_ = 0;
    uint32_t height_ = 0;
    bool ready_ = false;
    std::string diagnostics_ = "not loaded";
};

bool RIFEMPSGraphRunnerImpl::Load(const std::string& modelPath, uint32_t width, uint32_t height) {
    ready_ = false;
    width_ = width;
    height_ = height;
    weights_ = [NSMutableDictionary dictionary];
    shapes_ = [NSMutableDictionary dictionary];
    graph_ = nil;
    input_ = nil;
    output_ = nil;
    zeroInput_ = nil;
    cachedInputData_ = nil;
    cachedOutputData_ = nil;
    cachedFeeds_ = nil;
    cachedResults_ = nil;
    cachedInputBuffer_ = nil;
    cachedOutputBuffer_ = nil;

    if (width < 16 || height < 16 || width % 16 != 0 || height % 16 != 0) {
        diagnostics_ = "RIFE MPSGraph requires width/height divisible by 16 for the student IFBlocks";
        return false;
    }

    NSString* path = SMNSString(modelPath);
    NSData* file = [NSData dataWithContentsOfFile:path];
    if (file.length < 16) {
        diagnostics_ = "RIFE safetensors missing or unreadable";
        return false;
    }
    const uint8_t* bytes = static_cast<const uint8_t*>(file.bytes);
    uint64_t headerBytes = 0;
    for (int i = 7; i >= 0; --i) {
        headerBytes = (headerBytes << 8) | bytes[i];
    }
    if (headerBytes == 0 || headerBytes + 8 > file.length) {
        diagnostics_ = "RIFE safetensors header length invalid";
        return false;
    }
    NSData* headerData = [file subdataWithRange:NSMakeRange(8, static_cast<NSUInteger>(headerBytes))];
    NSDictionary* header = [NSJSONSerialization JSONObjectWithData:headerData options:0 error:nil];
    if (![header isKindOfClass:NSDictionary.class]) {
        diagnostics_ = "RIFE safetensors header JSON invalid";
        return false;
    }

    for (NSString* key in header) {
        if ([key isEqualToString:@"__metadata__"]) {
            continue;
        }
        NSDictionary* entry = [header[key] isKindOfClass:NSDictionary.class] ? header[key] : nil;
        NSArray<NSNumber*>* offsets = [entry[@"data_offsets"] isKindOfClass:NSArray.class] ? entry[@"data_offsets"] : nil;
        NSArray<NSNumber*>* shape = [entry[@"shape"] isKindOfClass:NSArray.class] ? entry[@"shape"] : nil;
        NSString* dtype = [entry[@"dtype"] isKindOfClass:NSString.class] ? entry[@"dtype"] : @"";
        if (![dtype isEqualToString:@"F32"] || offsets.count != 2 || shape.count == 0) {
            continue;
        }
        const uint64_t start = offsets[0].unsignedLongLongValue + 8 + headerBytes;
        const uint64_t end = offsets[1].unsignedLongLongValue + 8 + headerBytes;
        if (end <= start || end > file.length) {
            diagnostics_ = "RIFE safetensors tensor offset invalid";
            return false;
        }
        weights_[key] = [file subdataWithRange:NSMakeRange(static_cast<NSUInteger>(start),
                                                           static_cast<NSUInteger>(end - start))];
        shapes_[key] = shape;
    }

    if (weights_.count != 160) {
        std::ostringstream out;
        out << "RIFE expected 160 tensors, loaded " << weights_.count;
        diagnostics_ = out.str();
        return false;
    }

    device_ = MTLCreateSystemDefaultDevice();
    queue_ = [device_ newCommandQueue];
    if (device_ == nil || queue_ == nil) {
        diagnostics_ = "Metal device/queue unavailable";
        return false;
    }

    @try {
        graph_ = [MPSGraph new];
        output_ = BuildGraph();
        const NSUInteger floats = static_cast<NSUInteger>(width_) * height_ * 6;
        id<MTLBuffer> inputBuffer = [device_ newBufferWithLength:floats * sizeof(float) options:MTLResourceStorageModeShared];
        memset(inputBuffer.contents, 0, floats * sizeof(float));
        zeroInput_ = [[MPSGraphTensorData alloc] initWithMTLBuffer:inputBuffer
                                                             shape:SMShape({1, height_, width_, 6})
                                                          dataType:MPSDataTypeFloat32];
    } @catch (NSException* exception) {
        diagnostics_ = std::string("RIFE MPSGraph build failed: ") + (exception.reason.UTF8String ?: exception.name.UTF8String ?: "exception");
        return false;
    }

    ready_ = output_ != nil && zeroInput_ != nil;
    std::ostringstream out;
    out << "RIFE MPSGraph ready tensors=" << weights_.count
        << " input=1x" << height_ << "x" << width_ << "x6"
        << " backend=Metal/MPSGraph"
        << " metal4ML=" << (HasMetal4MachineLearningAPI() ? "available" : "unavailable");
    diagnostics_ = out.str();
    return ready_;
}

bool RIFEMPSGraphRunnerImpl::HasMetal4MachineLearningAPI() const {
    if (@available(macOS 26.0, *)) {
        return [queue_ respondsToSelector:NSSelectorFromString(@"commandBuffer")] && NSClassFromString(@"MTL4MachineLearningPipelineDescriptor") != nil;
    }
    return false;
}

void RIFEMPSGraphRunnerImpl::SetCommandQueue(id<MTLCommandQueue> commandQueue) {
    if (commandQueue != nil) {
        queue_ = commandQueue;
        device_ = commandQueue.device ?: device_;
    }
}

MPSGraphTensor* RIFEMPSGraphRunnerImpl::Constant(const std::string& name) {
    NSString* key = SMNSString(name);
    NSData* data = weights_[key];
    NSArray<NSNumber*>* shape = shapes_[key];
    if (data == nil || shape == nil) {
        [NSException raise:@"RIFEMissingTensor" format:@"missing tensor %@", key];
    }
    return [graph_ constantWithData:data shape:shape dataType:MPSDataTypeFloat32];
}

MPSGraphTensor* RIFEMPSGraphRunnerImpl::Scalar(float value, NSString* name) {
    (void)name;
    return [graph_ constantWithData:SMFloatData({value}) shape:SMShape({1}) dataType:MPSDataTypeFloat32];
}

MPSGraphTensor* RIFEMPSGraphRunnerImpl::SizeTensor(int32_t height, int32_t width, NSString* name) {
    (void)name;
    return [graph_ constantWithData:SMInt32Data({height, width}) shape:SMShape({2}) dataType:MPSDataTypeInt32];
}

MPSGraphTensor* RIFEMPSGraphRunnerImpl::PReLU(MPSGraphTensor* input, const std::string& slopeName, NSString* name) {
    NSArray<NSNumber*>* slopeShape = shapes_[SMNSString(slopeName)];
    const int64_t channels = slopeShape.count > 0 ? slopeShape[0].longLongValue : 1;
    MPSGraphTensor* slope = [graph_ reshapeTensor:Constant(slopeName) withShape:SMShape({1, 1, 1, channels}) name:nil];
    MPSGraphTensor* zero = Scalar(0.0f, nil);
    MPSGraphTensor* positive = [graph_ maximumWithPrimaryTensor:input secondaryTensor:zero name:nil];
    MPSGraphTensor* negative = [graph_ minimumWithPrimaryTensor:input secondaryTensor:zero name:nil];
    MPSGraphTensor* scaled = [graph_ multiplicationWithPrimaryTensor:negative secondaryTensor:slope name:nil];
    return [graph_ additionWithPrimaryTensor:positive secondaryTensor:scaled name:name];
}

MPSGraphTensor* RIFEMPSGraphRunnerImpl::Conv(MPSGraphTensor* input,
                                             const std::string& prefix,
                                             NSUInteger stride,
                                             bool activation,
                                             NSString* name) {
    MPSGraphConvolution2DOpDescriptor* descriptor =
        [MPSGraphConvolution2DOpDescriptor descriptorWithStrideInX:stride
                                                         strideInY:stride
                                                   dilationRateInX:1
                                                   dilationRateInY:1
                                                            groups:1
                                                       paddingLeft:1
                                                      paddingRight:1
                                                        paddingTop:1
                                                     paddingBottom:1
                                                      paddingStyle:MPSGraphPaddingStyleExplicit
                                                        dataLayout:MPSGraphTensorNamedDataLayoutNHWC
                                                     weightsLayout:MPSGraphTensorNamedDataLayoutOIHW];
    MPSGraphTensor* y = [graph_ convolution2DWithSourceTensor:input
                                                weightsTensor:Constant(prefix + ".0.weight")
                                                   descriptor:descriptor
                                                         name:name];
    MPSGraphTensor* bias = [graph_ reshapeTensor:Constant(prefix + ".0.bias")
                                      withShape:SMShape({1, 1, 1, shapes_[SMNSString(prefix + ".0.bias")][0].longLongValue})
                                           name:nil];
    y = [graph_ additionWithPrimaryTensor:y secondaryTensor:bias name:nil];
    return activation ? PReLU(y, prefix + ".1.weight", name) : y;
}

MPSGraphTensor* RIFEMPSGraphRunnerImpl::Deconv(MPSGraphTensor* input,
                                               const std::string& prefix,
                                               uint32_t outHeight,
                                               uint32_t outWidth,
                                               uint32_t outChannels,
                                               bool activation,
                                               NSString* name) {
    MPSGraphConvolution2DOpDescriptor* descriptor =
        [MPSGraphConvolution2DOpDescriptor descriptorWithStrideInX:2
                                                         strideInY:2
                                                   dilationRateInX:1
                                                   dilationRateInY:1
                                                            groups:1
                                                       paddingLeft:1
                                                      paddingRight:1
                                                        paddingTop:1
                                                     paddingBottom:1
                                                      paddingStyle:MPSGraphPaddingStyleExplicit
                                                        dataLayout:MPSGraphTensorNamedDataLayoutNHWC
                                                     weightsLayout:MPSGraphTensorNamedDataLayoutOIHW];
    MPSGraphTensor* y = [graph_ convolutionTranspose2DWithSourceTensor:input
                                                         weightsTensor:Constant(prefix + ".weight")
                                                           outputShape:SMShape({1, outHeight, outWidth, outChannels})
                                                            descriptor:descriptor
                                                                  name:name];
    MPSGraphTensor* bias = [graph_ reshapeTensor:Constant(prefix + ".bias")
                                      withShape:SMShape({1, 1, 1, outChannels})
                                           name:nil];
    y = [graph_ additionWithPrimaryTensor:y secondaryTensor:bias name:nil];
    return activation ? PReLU(y, prefix.substr(0, prefix.rfind('.')) + ".1.weight", name) : y;
}

MPSGraphTensor* RIFEMPSGraphRunnerImpl::Resize(MPSGraphTensor* input, uint32_t height, uint32_t width, NSString* name) {
    return [graph_ resizeBilinearWithTensor:input
                                 sizeTensor:SizeTensor(static_cast<int32_t>(height), static_cast<int32_t>(width), nil)
                               centerResult:YES
                               alignCorners:NO
                                     layout:MPSGraphTensorNamedDataLayoutNHWC
                                       name:name];
}

MPSGraphTensor* RIFEMPSGraphRunnerImpl::SliceC(MPSGraphTensor* input, NSInteger start, NSInteger length, NSString* name) {
    return [graph_ sliceTensor:input dimension:3 start:start length:length name:name];
}

MPSGraphTensor* RIFEMPSGraphRunnerImpl::IFBlock(const std::string& block,
                                                MPSGraphTensor* x,
                                                MPSGraphTensor* flow,
                                                uint32_t scale,
                                                MPSGraphTensor** maskOut) {
    const uint32_t h = height_ / scale;
    const uint32_t w = width_ / scale;
    MPSGraphTensor* xScaled = Resize(x, h, w, nil);
    MPSGraphTensor* flowScaled = Resize(flow, h, w, nil);
    flowScaled = [graph_ multiplicationWithPrimaryTensor:flowScaled secondaryTensor:Scalar(1.0f / static_cast<float>(scale), nil) name:nil];
    MPSGraphTensor* feat = [graph_ concatTensors:@[xScaled, flowScaled] dimension:3 name:nil];

    feat = Conv(feat, block + ".conv0.0", 2, true, nil);
    feat = Conv(feat, block + ".conv0.1", 2, true, nil);

    for (int residual = 0; residual < 4; ++residual) {
        MPSGraphTensor* base = feat;
        feat = Conv(feat, block + ".convblock" + std::to_string(residual) + ".0", 1, true, nil);
        feat = Conv(feat, block + ".convblock" + std::to_string(residual) + ".1", 1, true, nil);
        feat = [graph_ additionWithPrimaryTensor:feat secondaryTensor:base name:nil];
    }

    const uint32_t midH = h / 2;
    const uint32_t midW = w / 2;
    MPSGraphTensor* flowHead = Deconv(feat, block + ".conv1.0", midH, midW, 45, true, nil);
    flowHead = Deconv(flowHead, block + ".conv1.2", h, w, 4, false, nil);
    flowHead = Resize(flowHead, height_, width_, nil);
    flowHead = [graph_ multiplicationWithPrimaryTensor:flowHead secondaryTensor:Scalar(static_cast<float>(scale), nil) name:nil];

    MPSGraphTensor* maskHead = Deconv(feat, block + ".conv2.0", midH, midW, 45, true, nil);
    maskHead = Deconv(maskHead, block + ".conv2.2", h, w, 1, false, nil);
    *maskOut = Resize(maskHead, height_, width_, nil);
    return flowHead;
}

MPSGraphTensor* RIFEMPSGraphRunnerImpl::Warp(MPSGraphTensor* image, MPSGraphTensor* flow, NSString* name) {
    const NSUInteger count = static_cast<NSUInteger>(height_) * width_ * 2;
    NSMutableData* grid = [NSMutableData dataWithLength:count * sizeof(float)];
    float* ptr = static_cast<float*>(grid.mutableBytes);
    for (uint32_t y = 0; y < height_; ++y) {
        for (uint32_t x = 0; x < width_; ++x) {
            const NSUInteger index = (static_cast<NSUInteger>(y) * width_ + x) * 2;
            ptr[index + 0] = static_cast<float>(x);
            ptr[index + 1] = static_cast<float>(y);
        }
    }
    MPSGraphTensor* base = [graph_ constantWithData:grid shape:SMShape({1, height_, width_, 2}) dataType:MPSDataTypeFloat32];
    MPSGraphTensor* coords = [graph_ additionWithPrimaryTensor:base secondaryTensor:flow name:nil];
    return [graph_ sampleGridWithSourceTensor:image
                             coordinateTensor:coords
                                       layout:MPSGraphTensorNamedDataLayoutNHWC
                         normalizeCoordinates:NO
                          relativeCoordinates:NO
                                 alignCorners:YES
                                  paddingMode:MPSGraphPaddingModeClampToEdge
                                 samplingMode:MPSGraphResizeBilinear
                                constantValue:0.0
                                         name:name];
}

MPSGraphTensor* RIFEMPSGraphRunnerImpl::BuildGraph() {
    input_ = [graph_ placeholderWithShape:SMShape({1, height_, width_, 6}) dataType:MPSDataTypeFloat32 name:@"rife_input"];
    MPSGraphTensor* img0 = SliceC(input_, 0, 3, nil);
    MPSGraphTensor* img1 = SliceC(input_, 3, 3, nil);
    MPSGraphTensor* flow = [graph_ constantWithData:[NSMutableData dataWithLength:static_cast<NSUInteger>(height_) * width_ * 4 * sizeof(float)]
                                             shape:SMShape({1, height_, width_, 4})
                                          dataType:MPSDataTypeFloat32];
    MPSGraphTensor* mask = [graph_ constantWithData:[NSMutableData dataWithLength:static_cast<NSUInteger>(height_) * width_ * sizeof(float)]
                                             shape:SMShape({1, height_, width_, 1})
                                          dataType:MPSDataTypeFloat32];
    MPSGraphTensor* warped0 = img0;
    MPSGraphTensor* warped1 = img1;

    const uint32_t scales[3] = {4, 2, 1};
    for (int i = 0; i < 3; ++i) {
        const std::string block = "block" + std::to_string(i);
        MPSGraphTensor* m0 = nil;
        MPSGraphTensor* m1 = nil;
        MPSGraphTensor* rgb0 = SliceC(warped0, 0, 3, nil);
        MPSGraphTensor* rgb1 = SliceC(warped1, 0, 3, nil);
        MPSGraphTensor* f0 = IFBlock(block, [graph_ concatTensors:@[rgb0, rgb1, mask] dimension:3 name:nil], flow, scales[i], &m0);
        MPSGraphTensor* flowSwap = [graph_ concatTensors:@[SliceC(flow, 2, 2, nil), SliceC(flow, 0, 2, nil)] dimension:3 name:nil];
        MPSGraphTensor* f1 = IFBlock(block,
                                     [graph_ concatTensors:@[rgb1, rgb0, [graph_ negativeWithTensor:mask name:nil]] dimension:3 name:nil],
                                     flowSwap,
                                     scales[i],
                                     &m1);
        MPSGraphTensor* f1Swap = [graph_ concatTensors:@[SliceC(f1, 2, 2, nil), SliceC(f1, 0, 2, nil)] dimension:3 name:nil];
        MPSGraphTensor* flowDelta = [graph_ additionWithPrimaryTensor:f0 secondaryTensor:f1Swap name:nil];
        flowDelta = [graph_ multiplicationWithPrimaryTensor:flowDelta secondaryTensor:Scalar(0.5f, nil) name:nil];
        flow = [graph_ additionWithPrimaryTensor:flow secondaryTensor:flowDelta name:nil];
        MPSGraphTensor* maskDelta = [graph_ subtractionWithPrimaryTensor:m0 secondaryTensor:m1 name:nil];
        maskDelta = [graph_ multiplicationWithPrimaryTensor:maskDelta secondaryTensor:Scalar(0.5f, nil) name:nil];
        mask = [graph_ additionWithPrimaryTensor:mask secondaryTensor:maskDelta name:nil];
        warped0 = Warp(img0, SliceC(flow, 0, 2, nil), nil);
        warped1 = Warp(img1, SliceC(flow, 2, 2, nil), nil);
    }

    MPSGraphTensor* sigmoid = [graph_ sigmoidWithTensor:mask name:nil];
    MPSGraphTensor* inv = [graph_ subtractionWithPrimaryTensor:Scalar(1.0f, nil) secondaryTensor:sigmoid name:nil];
    MPSGraphTensor* left = [graph_ multiplicationWithPrimaryTensor:warped0 secondaryTensor:sigmoid name:nil];
    MPSGraphTensor* right = [graph_ multiplicationWithPrimaryTensor:warped1 secondaryTensor:inv name:nil];
    return [graph_ additionWithPrimaryTensor:left secondaryTensor:right name:@"rife_output"];
}

RIFEMPSGraphRunResult RIFEMPSGraphRunnerImpl::RunZeroInput() {
    const NSUInteger outFloats = static_cast<NSUInteger>(height_) * width_ * 3;
    id<MTLBuffer> outputBuffer = [device_ newBufferWithLength:outFloats * sizeof(float) options:MTLResourceStorageModeShared];
    return RunWithBuffers(nil, outputBuffer);
}

RIFEMPSGraphRunResult RIFEMPSGraphRunnerImpl::RunWithBuffers(id<MTLBuffer> inputBuffer, id<MTLBuffer> outputBuffer) {
    RIFEMPSGraphRunResult result;
    result.width = width_;
    result.height = height_;
    result.outputChannels = 3;
    if (!ready_) {
        result.message = diagnostics_;
        return result;
    }
    if (outputBuffer == nil || outputBuffer.length < static_cast<NSUInteger>(height_) * width_ * 3 * sizeof(float)) {
        result.message = "RIFE output MTLBuffer missing or too small";
        return result;
    }
    @try {
        MPSGraphTensorData* inputData = zeroInput_;
        if (inputBuffer != nil) {
            if (inputBuffer.length < static_cast<NSUInteger>(height_) * width_ * 6 * sizeof(float)) {
                result.message = "RIFE input MTLBuffer too small";
                return result;
            }
            if (cachedInputData_ == nil || cachedInputBuffer_ != inputBuffer) {
                cachedInputBuffer_ = inputBuffer;
                cachedInputData_ = [[MPSGraphTensorData alloc] initWithMTLBuffer:inputBuffer
                                                                           shape:SMShape({1, height_, width_, 6})
                                                                        dataType:MPSDataTypeFloat32];
                cachedFeeds_ = nil;
            }
            inputData = cachedInputData_;
        } else if (cachedInputBuffer_ != nil) {
            cachedInputBuffer_ = nil;
            cachedFeeds_ = nil;
        }
        if (cachedOutputData_ == nil || cachedOutputBuffer_ != outputBuffer) {
            cachedOutputBuffer_ = outputBuffer;
            cachedOutputData_ = [[MPSGraphTensorData alloc] initWithMTLBuffer:outputBuffer
                                                                        shape:SMShape({1, height_, width_, 3})
                                                                     dataType:MPSDataTypeFloat32];
            cachedResults_ = nil;
        }
        const CFTimeInterval start = CACurrentMediaTime();
        NSDictionary* feeds = nil;
        if (inputBuffer == nil) {
            feeds = @{input_: inputData};
        } else {
            if (cachedFeeds_ == nil) {
                cachedFeeds_ = @{input_: inputData};
            }
            feeds = cachedFeeds_;
        }
        if (cachedResults_ == nil) {
            cachedResults_ = @{output_: cachedOutputData_};
        }
        [graph_ runWithMTLCommandQueue:queue_
                                  feeds:feeds
                       targetOperations:nil
                      resultsDictionary:cachedResults_];
        result.elapsedMs = (CACurrentMediaTime() - start) * 1000.0;
        result.ok = true;
        result.message = "RIFE MPSGraph full inference completed";
    } @catch (NSException* exception) {
        result.ok = false;
        result.message = std::string("RIFE MPSGraph run failed: ") + (exception.reason.UTF8String ?: exception.name.UTF8String ?: "exception");
    }
    return result;
}

} // namespace

namespace Stellaria::Motion {

RIFEMPSGraphRunner::RIFEMPSGraphRunner()
    : impl_(new RIFEMPSGraphRunnerImpl()) {
}

RIFEMPSGraphRunner::~RIFEMPSGraphRunner() {
    delete static_cast<RIFEMPSGraphRunnerImpl*>(impl_);
}

bool RIFEMPSGraphRunner::Load(const std::string& modelPath, uint32_t width, uint32_t height) {
    return static_cast<RIFEMPSGraphRunnerImpl*>(impl_)->Load(modelPath, width, height);
}

bool RIFEMPSGraphRunner::IsReady() const {
    return static_cast<RIFEMPSGraphRunnerImpl*>(impl_)->IsReady();
}

std::string RIFEMPSGraphRunner::Diagnostics() const {
    return static_cast<RIFEMPSGraphRunnerImpl*>(impl_)->Diagnostics();
}

bool RIFEMPSGraphRunner::HasMetal4MachineLearningAPI() const {
    return static_cast<RIFEMPSGraphRunnerImpl*>(impl_)->HasMetal4MachineLearningAPI();
}

void RIFEMPSGraphRunner::SetCommandQueue(void* commandQueue) {
    static_cast<RIFEMPSGraphRunnerImpl*>(impl_)->SetCommandQueue((__bridge id<MTLCommandQueue>)commandQueue);
}

RIFEMPSGraphRunResult RIFEMPSGraphRunner::RunZeroInput() {
    return static_cast<RIFEMPSGraphRunnerImpl*>(impl_)->RunZeroInput();
}

RIFEMPSGraphRunResult RIFEMPSGraphRunner::RunWithBuffers(void* inputMTLBuffer, void* outputMTLBuffer) {
    return static_cast<RIFEMPSGraphRunnerImpl*>(impl_)->RunWithBuffers((__bridge id<MTLBuffer>)inputMTLBuffer,
                                                                       (__bridge id<MTLBuffer>)outputMTLBuffer);
}

} // namespace Stellaria::Motion
