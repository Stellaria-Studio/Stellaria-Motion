#include <metal_stdlib>
using namespace metal;

struct PresentParams {
    uint width;
    uint height;
};

struct YUVPackParams {
    uint outWidth;
    uint outHeight;
    float2 sourceSize;
    float normalizeScale;
    float normalizeBias;
};

struct FlowUpscaleParams {
    float2 scale;
    float2 inverseScale;
    float edgeGain;
};

struct BlendProtectParams {
    float t;
    float lineGain;
    float subtitleThreshold;
    float refineStrength;
};

struct BGRAInterpolateParams {
    uint outWidth;
    uint outHeight;
    float2 inverseUpscale;
    float t;
};

struct RIFETextureParams {
    uint width;
    uint height;
    uint modelWidth;
    uint modelHeight;
};

struct RIFECoreMLBlockParams {
    uint width;
    uint height;
    uint modelWidth;
    uint modelHeight;
    uint reverse;
};

struct RIFEMetal4Params {
    uint width;
    uint height;
    uint modelWidth;
    uint modelHeight;
    uint layerCount;
    uint graphTensorCount;
    uint activeBlockCount;
    uint reserved0;
    float flowGain;
    float nativeBlend;
    float t;
    float reserved1;
};

struct SP4RefineParams {
    uint width;
    uint height;
    uint modelWidth;
    uint modelHeight;
    float residualStrength;
    float temporalProtect;
    float edgeProtect;
    float t;
};

struct RIFEMetal4LayerDesc {
    uint weightOffsetBytes;
    uint scaleOffset;
    uint biasOffset;
    uint outputChannels;
    uint inputChannels;
    uint kernelWidth;
    uint kernelHeight;
    uint op;
};

struct SP4SDKLayerPlan {
    uint qweightOffsetBytes;
    uint scaleOffset;
    uint modeOffset;
    uint auxOffset;
    uint residualTableOffset;
    uint residualIndexOffset;
    uint residualValueOffset;
    uint blockSize;
    uint blockCount;
    uint inputChannels;
    uint outputChannels;
    uint kernelWidth;
    uint kernelHeight;
    uint activationScaleOffset;
    uint flags;
    uint reserved0;
    uint reserved1;
};

struct SP4PreparedLayerPlan {
    uint sourceLayerIndex;
    uint weightOffset;
    uint weightCount;
    uint biasOffset;
    uint biasCount;
    uint inputChannels;
    uint outputChannels;
    uint kernelWidth;
    uint kernelHeight;
    uint flags;
};

static inline float3 yuv_to_rgb(float y, float2 uv) {
    uv -= float2(0.5);
    return clamp(float3(y + 1.402 * uv.y,
                        y - 0.344136 * uv.x - 0.714136 * uv.y,
                        y + 1.772 * uv.x), 0.0, 1.0);
}

static inline float luma3(float3 rgb) {
    return dot(rgb, float3(0.299, 0.587, 0.114));
}

static inline int sm_q4_unpack(device const uchar* packed, uint index) {
    const uchar byteValue = packed[index >> 1];
    int value = ((index & 1) == 0) ? int(byteValue & 0x0F) : int((byteValue >> 4) & 0x0F);
    if (value >= 8) {
        value -= 16;
    }
    return value;
}

static inline uint sm_sp4_u4(device const uchar* qweight, uint valueIndex) {
    const uchar packed = qweight[valueIndex >> 1];
    return ((valueIndex & 1) == 0 ? packed : (packed >> 4)) & 0x0f;
}

static inline float sm_sp4_codebook_value(uint code) {
    constexpr float codebook[16] = {
        -1.000000f, -0.696193f, -0.525073f, -0.394917f,
        -0.284441f, -0.184773f, -0.091050f,  0.000000f,
         0.079580f,  0.160930f,  0.246112f,  0.337915f,
         0.440710f,  0.562617f,  0.722956f,  1.000000f,
    };
    return codebook[code & 0x0f];
}

static inline float sm_sp4_learned_codebook_value(uint code) {
    constexpr float codebook[16] = {
        -1.000000f, -0.770166f, -0.607256f, -0.472373f,
        -0.356107f, -0.252558f, -0.158382f, -0.070901f,
         0.012902f,  0.098159f,  0.189695f,  0.291085f,
         0.407779f,  0.548442f,  0.727477f,  1.000000f,
    };
    return codebook[code & 0x0f];
}

static inline float sm_rife_feature(texture2d<float, access::sample> previousFrame,
                                    texture2d<float, access::sample> currentFrame,
                                    sampler linearSampler,
                                    float2 sourcePos,
                                    uint channel) {
    const float3 a = previousFrame.sample(linearSampler, sourcePos).rgb;
    const float3 b = currentFrame.sample(linearSampler, sourcePos).rgb;
    switch (channel) {
        case 0: return clamp(a.r, 0.0, 1.0);
        case 1: return clamp(a.g, 0.0, 1.0);
        case 2: return clamp(a.b, 0.0, 1.0);
        case 3: return clamp(b.r, 0.0, 1.0);
        case 4: return clamp(b.g, 0.0, 1.0);
        case 5: return clamp(b.b, 0.0, 1.0);
        case 6: return 0.0;
        case 7: return 0.0;
        case 8: return 0.0;
        case 9: return 0.0;
        case 10: return 0.0;
        default: return 0.0;
    }
}

static inline float sm_int4_first_conv(texture2d<float, access::sample> previousFrame,
                                       texture2d<float, access::sample> currentFrame,
                                       device const uchar* q4Weights,
                                       device const float* scales,
                                       device const float* bias,
                                       RIFEMetal4LayerDesc layer,
                                       constant RIFEMetal4Params& params,
                                       sampler linearSampler,
                                       float2 modelPos,
                                       uint outputChannel) {
    if (outputChannel >= layer.outputChannels) {
        return 0.0;
    }
    const uint kernelValues = layer.inputChannels * layer.kernelWidth * layer.kernelHeight;
    const uint packedPerOutput = (kernelValues + 1) >> 1;
    device const uchar* layerWeights = q4Weights + layer.weightOffsetBytes;
    device const float* layerScales = scales + layer.scaleOffset;
    device const float* layerBias = bias + layer.biasOffset;
    const uint weightBase = outputChannel * packedPerOutput;
    float sum = layerBias[outputChannel];
    uint linearIndex = 0;
    const float2 sourceScale = float2(params.width, params.height) / float2(params.modelWidth, params.modelHeight);
    for (uint ky = 0; ky < layer.kernelHeight; ++ky) {
        const float y = modelPos.y + float(int(ky) - int(layer.kernelHeight / 2));
        for (uint kx = 0; kx < layer.kernelWidth; ++kx) {
            const float x = modelPos.x + float(int(kx) - int(layer.kernelWidth / 2));
            const float2 sourcePos = (float2(x, y) + 0.5) * sourceScale;
            for (uint ic = 0; ic < layer.inputChannels; ++ic) {
                const int q = sm_q4_unpack(layerWeights + weightBase, linearIndex);
                const float feature = sm_rife_feature(previousFrame, currentFrame, linearSampler, sourcePos, ic);
                sum += float(q) * layerScales[outputChannel] * feature;
                ++linearIndex;
            }
        }
    }
    return max(sum, sum * 0.25);
}

static inline float sm_sp4_first_conv(texture2d<float, access::sample> previousFrame,
                                      texture2d<float, access::sample> currentFrame,
                                      device const uchar* qweight,
                                      device const half* scales,
                                      device const uchar* mode,
                                      device const uchar* aux,
                                      device const int* residualIndex,
                                      device const half* residualValue,
                                      device const int2* residualTable,
                                      device const SP4SDKLayerPlan* layers,
                                      constant RIFEMetal4Params& params,
                                      sampler linearSampler,
                                      uint layerIndex,
                                      float2 modelPos,
                                      uint outputChannel) {
    const SP4SDKLayerPlan layer = layers[layerIndex];
    if (outputChannel >= layer.outputChannels) {
        return 0.0;
    }
    const uint kernelValues = layer.inputChannels * layer.kernelWidth * layer.kernelHeight;
    const uint weightBase = outputChannel * kernelValues;
    const float2 sourceScale = float2(params.width, params.height) / float2(params.modelWidth, params.modelHeight);
    float sum = 0.0;
    uint linearIndex = 0;
    for (uint ky = 0; ky < layer.kernelHeight; ++ky) {
        const float y = modelPos.y + float(int(ky) - int(layer.kernelHeight / 2));
        for (uint kx = 0; kx < layer.kernelWidth; ++kx) {
            const float x = modelPos.x + float(int(kx) - int(layer.kernelWidth / 2));
            const float2 sourcePos = (float2(x, y) + 0.5) * sourceScale;
            for (uint ic = 0; ic < layer.inputChannels; ++ic) {
                const uint valueIndex = weightBase + linearIndex;
                const uint blockSize = max(1u, layer.blockSize);
                const uint blockId = valueIndex / blockSize;
                const uint local = valueIndex - blockId * blockSize;
                const uint modeValue = mode[layer.modeOffset + blockId];
                const uint code = sm_sp4_u4(qweight + layer.qweightOffsetBytes, valueIndex);
                const float scale = float(scales[layer.scaleOffset + blockId]);
                float weight = 0.0;
                if (modeValue == 5u || modeValue == 6u) {
                    weight = (modeValue == 6u ? sm_sp4_learned_codebook_value(code) : sm_sp4_codebook_value(code)) * scale;
                } else if (modeValue == 1u) {
                    const int zeroPoint = int(aux[layer.auxOffset + blockId] & 0x0fu);
                    weight = float(int(code) - zeroPoint) * scale;
                } else {
                    weight = float(sm_q4_unpack(qweight + layer.qweightOffsetBytes, valueIndex)) * scale;
                }
                const int2 span = residualTable[layer.residualTableOffset + blockId];
                for (int i = 0; i < span.y; ++i) {
                    const uint entry = uint(span.x + i);
                    if (uint(residualIndex[layer.residualIndexOffset + entry]) == local) {
                        weight += float(residualValue[layer.residualValueOffset + entry]);
                    }
                }
                sum += weight * sm_rife_feature(previousFrame, currentFrame, linearSampler, sourcePos, ic);
                ++linearIndex;
            }
        }
    }
    return max(sum, sum * 0.25);
}

static inline float sm_sp4_prepared_first_conv(texture2d<float, access::sample> previousFrame,
                                               texture2d<float, access::sample> currentFrame,
                                               device const half* weights,
                                               device const half* bias,
                                               device const SP4PreparedLayerPlan* layers,
                                               constant RIFEMetal4Params& params,
                                               sampler linearSampler,
                                               uint layerIndex,
                                               float2 modelPos,
                                               uint outputChannel) {
    const SP4PreparedLayerPlan layer = layers[layerIndex];
    if (outputChannel >= layer.outputChannels) {
        return 0.0;
    }
    const uint kernelValues = layer.inputChannels * layer.kernelWidth * layer.kernelHeight;
    const uint outputBase = layer.weightOffset + outputChannel * kernelValues;
    if (outputBase + kernelValues > layer.weightOffset + layer.weightCount) {
        return 0.0;
    }
    float sum = outputChannel < layer.biasCount ? float(bias[layer.biasOffset + outputChannel]) : 0.0;
    const float2 sourceScale = float2(params.width, params.height) / float2(params.modelWidth, params.modelHeight);
    for (uint ky = 0; ky < layer.kernelHeight; ++ky) {
        const float y = modelPos.y + float(int(ky) - int(layer.kernelHeight / 2));
        for (uint kx = 0; kx < layer.kernelWidth; ++kx) {
            const float x = modelPos.x + float(int(kx) - int(layer.kernelWidth / 2));
            const float2 sourcePos = (float2(x, y) + 0.5) * sourceScale;
            for (uint ic = 0; ic < layer.inputChannels; ++ic) {
                const uint weightIndex = outputBase + ((ic * layer.kernelHeight + ky) * layer.kernelWidth + kx);
                const float feature = sm_rife_feature(previousFrame, currentFrame, linearSampler, sourcePos, ic);
                sum += float(weights[weightIndex]) * feature;
            }
        }
    }
    return max(sum, sum * 0.25);
}

kernel void rife_metal4_int4_predict_bgra(texture2d<float, access::sample> previousFrame [[texture(0)]],
                                          texture2d<float, access::sample> currentFrame [[texture(1)]],
                                          texture2d<float, access::write> outFrame [[texture(2)]],
                                          device const uchar* q4Weights [[buffer(0)]],
                                          device const float* scales [[buffer(1)]],
                                          device const float* bias [[buffer(2)]],
                                          device const RIFEMetal4LayerDesc* layers [[buffer(3)]],
                                          constant RIFEMetal4Params& params [[buffer(4)]],
                                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }

    constexpr sampler linearSampler(coord::pixel, address::clamp_to_edge, filter::linear);
    const float2 sourcePos = float2(gid) + 0.5;
    const float2 modelScale = float2(params.modelWidth, params.modelHeight) / float2(params.width, params.height);
    const float2 modelPos = sourcePos * modelScale - 0.5;

    const float2 sourcePerModel = float2(params.width, params.height) / float2(params.modelWidth, params.modelHeight);
    float2 flow = float2(0.0);
    float maskLogit = 0.0;
    const uint activeBlocks = min(min(params.activeBlockCount, params.layerCount), 3u);
    for (uint block = 0; block < activeBlocks; ++block) {
        const RIFEMetal4LayerDesc layer = layers[block];
        const float scale = block == 0 ? 0.42 : (block == 1 ? 0.33 : 0.25);
        const float blockScale = block == 0 ? 4.0 : (block == 1 ? 2.0 : 1.0);
        const float2 scaledModelPos = (floor(modelPos / blockScale) + 0.5) * blockScale;
        const float s0 = sm_int4_first_conv(previousFrame, currentFrame, q4Weights, scales, bias, layer, params, linearSampler, scaledModelPos, 0);
        const float s1 = sm_int4_first_conv(previousFrame, currentFrame, q4Weights, scales, bias, layer, params, linearSampler, scaledModelPos, 1);
        const float s2 = sm_int4_first_conv(previousFrame, currentFrame, q4Weights, scales, bias, layer, params, linearSampler, scaledModelPos, 2);
        const float s3 = sm_int4_first_conv(previousFrame, currentFrame, q4Weights, scales, bias, layer, params, linearSampler, scaledModelPos, 3);
        const float s4 = sm_int4_first_conv(previousFrame, currentFrame, q4Weights, scales, bias, layer, params, linearSampler, scaledModelPos, 4);
        flow += float2(s0 - s1, s2 - s3) * scale * blockScale;
        maskLogit += s4 * scale;
    }
    flow *= params.flowGain * sourcePerModel;
    flow = clamp(flow, float2(-12.0), float2(12.0));

    float2 bestMotion = flow;
    float bestScore = 1.0e9;
    for (int y = -4; y <= 4; y += 2) {
        for (int x = -4; x <= 4; x += 2) {
            const float2 candidate = flow + float2(x, y);
            const float3 p0 = previousFrame.sample(linearSampler, sourcePos - candidate * 0.5).rgb;
            const float3 p1 = currentFrame.sample(linearSampler, sourcePos + candidate * 0.5).rgb;
            const float score = abs(luma3(p0) - luma3(p1)) + dot(candidate, candidate) * 0.0015;
            if (score < bestScore) {
                bestScore = score;
                bestMotion = candidate;
            }
        }
    }

    const float mask = clamp(1.0 / (1.0 + exp(-maskLogit)), 0.08, 0.92);
    const float3 a = previousFrame.sample(linearSampler, sourcePos - bestMotion * 0.5).rgb;
    const float3 b = currentFrame.sample(linearSampler, sourcePos + bestMotion * 0.5).rgb;
    const float3 native = mix(previousFrame.sample(linearSampler, sourcePos).rgb,
                              currentFrame.sample(linearSampler, sourcePos).rgb,
                              clamp(params.t, 0.0, 1.0));
    float3 rgb = mix(b, a, mask);
    rgb = mix(rgb, native, clamp(params.nativeBlend, 0.0, 0.20));
    outFrame.write(float4(clamp(rgb, 0.0, 1.0), 1.0), gid);
}

kernel void rife_metal4_int4_flow_mask(texture2d<float, access::sample> previousFrame [[texture(0)]],
                                       texture2d<float, access::sample> currentFrame [[texture(1)]],
                                       device float* flowMask [[buffer(0)]],
                                       device const uchar* q4Weights [[buffer(1)]],
                                       device const float* scales [[buffer(2)]],
                                       device const float* bias [[buffer(3)]],
                                       device const RIFEMetal4LayerDesc* layers [[buffer(4)]],
                                       constant RIFEMetal4Params& params [[buffer(5)]],
                                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.modelWidth || gid.y >= params.modelHeight) {
        return;
    }

    constexpr sampler linearSampler(coord::pixel, address::clamp_to_edge, filter::linear);
    const float2 modelPos = float2(gid);
    const float2 sourceScale = float2(params.width, params.height) / float2(params.modelWidth, params.modelHeight);
    const float2 sourcePos = (modelPos + 0.5) * sourceScale;

    float2 flow = float2(0.0);
    float maskLogit = 0.0;
    const uint activeBlocks = min(min(params.activeBlockCount, params.layerCount), 3u);
    for (uint block = 0; block < activeBlocks; ++block) {
        const RIFEMetal4LayerDesc layer = layers[block];
        const float scale = block == 0 ? 0.42 : (block == 1 ? 0.33 : 0.25);
        const float blockScale = block == 0 ? 4.0 : (block == 1 ? 2.0 : 1.0);
        const float2 scaledModelPos = (floor(modelPos / blockScale) + 0.5) * blockScale;
        const float s0 = sm_int4_first_conv(previousFrame, currentFrame, q4Weights, scales, bias, layer, params, linearSampler, scaledModelPos, 0);
        const float s1 = sm_int4_first_conv(previousFrame, currentFrame, q4Weights, scales, bias, layer, params, linearSampler, scaledModelPos, 1);
        const float s2 = sm_int4_first_conv(previousFrame, currentFrame, q4Weights, scales, bias, layer, params, linearSampler, scaledModelPos, 2);
        const float s3 = sm_int4_first_conv(previousFrame, currentFrame, q4Weights, scales, bias, layer, params, linearSampler, scaledModelPos, 3);
        const float s4 = sm_int4_first_conv(previousFrame, currentFrame, q4Weights, scales, bias, layer, params, linearSampler, scaledModelPos, 4);
        flow += float2(s0 - s1, s2 - s3) * scale * blockScale;
        maskLogit += s4 * scale;
    }
    flow *= params.flowGain * sourceScale;
    flow = clamp(flow, float2(-16.0), float2(16.0));

    float2 bestMotion = flow;
    float bestScore = 1.0e9;
    for (int y = -4; y <= 4; y += 2) {
        for (int x = -4; x <= 4; x += 2) {
            const float2 candidate = flow + float2(x, y);
            const float3 p0 = previousFrame.sample(linearSampler, sourcePos - candidate * 0.5).rgb;
            const float3 p1 = currentFrame.sample(linearSampler, sourcePos + candidate * 0.5).rgb;
            const float score = abs(luma3(p0) - luma3(p1)) + dot(candidate, candidate) * 0.0015;
            if (score < bestScore) {
                bestScore = score;
                bestMotion = candidate;
            }
        }
    }

    const float t = clamp(params.t, 0.0, 1.0);
    const uint offset = (gid.y * params.modelWidth + gid.x) * 5;
    flowMask[offset + 0] = -bestMotion.x * t;
    flowMask[offset + 1] = -bestMotion.y * t;
    flowMask[offset + 2] = bestMotion.x * (1.0 - t);
    flowMask[offset + 3] = bestMotion.y * (1.0 - t);
    flowMask[offset + 4] = clamp(1.0 / (1.0 + exp(-maskLogit)), 0.08, 0.92);
}

kernel void rife_sp4_sdk_flow_mask(texture2d<float, access::sample> previousFrame [[texture(0)]],
                                   texture2d<float, access::sample> currentFrame [[texture(1)]],
                                   device float* flowMask [[buffer(0)]],
                                   device const uchar* qweight [[buffer(1)]],
                                   device const half* scale [[buffer(2)]],
                                   device const uchar* mode [[buffer(3)]],
                                   device const uchar* aux [[buffer(4)]],
                                   device const int* residualIndex [[buffer(5)]],
                                   device const half* residualValue [[buffer(6)]],
                                   device const int2* residualTable [[buffer(7)]],
                                   device const SP4SDKLayerPlan* layers [[buffer(8)]],
                                   constant RIFEMetal4Params& params [[buffer(9)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.modelWidth || gid.y >= params.modelHeight) {
        return;
    }

    constexpr sampler linearSampler(coord::pixel, address::clamp_to_edge, filter::linear);
    const float2 modelPos = float2(gid);
    const float2 sourceScale = float2(params.width, params.height) / float2(params.modelWidth, params.modelHeight);
    const float2 sourcePos = (modelPos + 0.5) * sourceScale;

    float2 flow = float2(0.0);
    float maskLogit = 0.0;
    const uint activeBlocks = min(min(params.activeBlockCount, params.layerCount), 3u);
    for (uint block = 0; block < activeBlocks; ++block) {
        const float scaleWeight = block == 0 ? 0.42 : (block == 1 ? 0.33 : 0.25);
        const float blockScale = block == 0 ? 4.0 : (block == 1 ? 2.0 : 1.0);
        const float2 scaledModelPos = (floor(modelPos / blockScale) + 0.5) * blockScale;
        const float s0 = sm_sp4_first_conv(previousFrame, currentFrame, qweight, scale, mode, aux, residualIndex, residualValue, residualTable, layers, params, linearSampler, block, scaledModelPos, 0);
        const float s1 = sm_sp4_first_conv(previousFrame, currentFrame, qweight, scale, mode, aux, residualIndex, residualValue, residualTable, layers, params, linearSampler, block, scaledModelPos, 1);
        const float s2 = sm_sp4_first_conv(previousFrame, currentFrame, qweight, scale, mode, aux, residualIndex, residualValue, residualTable, layers, params, linearSampler, block, scaledModelPos, 2);
        const float s3 = sm_sp4_first_conv(previousFrame, currentFrame, qweight, scale, mode, aux, residualIndex, residualValue, residualTable, layers, params, linearSampler, block, scaledModelPos, 3);
        const float s4 = sm_sp4_first_conv(previousFrame, currentFrame, qweight, scale, mode, aux, residualIndex, residualValue, residualTable, layers, params, linearSampler, block, scaledModelPos, 4);
        flow += float2(s0 - s1, s2 - s3) * scaleWeight * blockScale;
        maskLogit += s4 * scaleWeight;
    }
    flow *= params.flowGain * sourceScale;
    flow = clamp(flow, float2(-16.0), float2(16.0));

    float2 bestMotion = flow;
    float bestScore = 1.0e9;
    for (int y = -4; y <= 4; y += 2) {
        for (int x = -4; x <= 4; x += 2) {
            const float2 candidate = flow + float2(x, y);
            const float3 p0 = previousFrame.sample(linearSampler, sourcePos - candidate * 0.5).rgb;
            const float3 p1 = currentFrame.sample(linearSampler, sourcePos + candidate * 0.5).rgb;
            const float score = abs(luma3(p0) - luma3(p1)) + dot(candidate, candidate) * 0.0015;
            if (score < bestScore) {
                bestScore = score;
                bestMotion = candidate;
            }
        }
    }

    const float t = clamp(params.t, 0.0, 1.0);
    const uint offset = (gid.y * params.modelWidth + gid.x) * 5;
    flowMask[offset + 0] = -bestMotion.x * t;
    flowMask[offset + 1] = -bestMotion.y * t;
    flowMask[offset + 2] = bestMotion.x * (1.0 - t);
    flowMask[offset + 3] = bestMotion.y * (1.0 - t);
    flowMask[offset + 4] = clamp(1.0 / (1.0 + exp(-maskLogit)), 0.08, 0.92);
}

kernel void rife_sp4_prepared_flow_mask(texture2d<float, access::sample> previousFrame [[texture(0)]],
                                        texture2d<float, access::sample> currentFrame [[texture(1)]],
                                        device float* flowMask [[buffer(0)]],
                                        device const half* preparedWeights [[buffer(1)]],
                                        device const half* preparedBias [[buffer(2)]],
                                        device const SP4PreparedLayerPlan* preparedLayers [[buffer(3)]],
                                        constant RIFEMetal4Params& params [[buffer(4)]],
                                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.modelWidth || gid.y >= params.modelHeight) {
        return;
    }

    constexpr sampler linearSampler(coord::pixel, address::clamp_to_edge, filter::linear);
    const float2 modelPos = float2(gid);
    const float2 sourceScale = float2(params.width, params.height) / float2(params.modelWidth, params.modelHeight);
    const float2 sourcePos = (modelPos + 0.5) * sourceScale;

    float2 flow = float2(0.0);
    float maskLogit = 0.0;
    const uint activeBlocks = min(min(params.activeBlockCount, params.layerCount), 3u);
    for (uint block = 0; block < activeBlocks; ++block) {
        const float scaleWeight = block == 0 ? 0.42 : (block == 1 ? 0.33 : 0.25);
        const float blockScale = block == 0 ? 4.0 : (block == 1 ? 2.0 : 1.0);
        const float2 scaledModelPos = (floor(modelPos / blockScale) + 0.5) * blockScale;
        const float s0 = sm_sp4_prepared_first_conv(previousFrame, currentFrame, preparedWeights, preparedBias, preparedLayers, params, linearSampler, block, scaledModelPos, 0);
        const float s1 = sm_sp4_prepared_first_conv(previousFrame, currentFrame, preparedWeights, preparedBias, preparedLayers, params, linearSampler, block, scaledModelPos, 1);
        const float s2 = sm_sp4_prepared_first_conv(previousFrame, currentFrame, preparedWeights, preparedBias, preparedLayers, params, linearSampler, block, scaledModelPos, 2);
        const float s3 = sm_sp4_prepared_first_conv(previousFrame, currentFrame, preparedWeights, preparedBias, preparedLayers, params, linearSampler, block, scaledModelPos, 3);
        const float s4 = sm_sp4_prepared_first_conv(previousFrame, currentFrame, preparedWeights, preparedBias, preparedLayers, params, linearSampler, block, scaledModelPos, 4);
        flow += float2(s0 - s1, s2 - s3) * scaleWeight * blockScale;
        maskLogit += s4 * scaleWeight;
    }
    flow *= params.flowGain * sourceScale;
    flow = clamp(flow, float2(-16.0), float2(16.0));

    float2 bestMotion = flow;
    float bestScore = 1.0e9;
    for (int y = -4; y <= 4; y += 2) {
        for (int x = -4; x <= 4; x += 2) {
            const float2 candidate = flow + float2(x, y);
            const float3 p0 = previousFrame.sample(linearSampler, sourcePos - candidate * 0.5).rgb;
            const float3 p1 = currentFrame.sample(linearSampler, sourcePos + candidate * 0.5).rgb;
            const float score = abs(luma3(p0) - luma3(p1)) + dot(candidate, candidate) * 0.0015;
            if (score < bestScore) {
                bestScore = score;
                bestMotion = candidate;
            }
        }
    }

    const float t = clamp(params.t, 0.0, 1.0);
    const uint offset = (gid.y * params.modelWidth + gid.x) * 5;
    flowMask[offset + 0] = -bestMotion.x * t;
    flowMask[offset + 1] = -bestMotion.y * t;
    flowMask[offset + 2] = bestMotion.x * (1.0 - t);
    flowMask[offset + 3] = bestMotion.y * (1.0 - t);
    flowMask[offset + 4] = clamp(1.0 / (1.0 + exp(-maskLogit)), 0.08, 0.92);
}

kernel void rife_rescale_flow_mask_t(device float* flowMask [[buffer(0)]],
                                     constant RIFEMetal4Params& params [[buffer(1)]],
                                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.modelWidth || gid.y >= params.modelHeight) {
        return;
    }
    const float oldT = clamp(params.reserved1, 0.001, 0.999);
    const float newT = clamp(params.t, 0.0, 1.0);
    const uint offset = (gid.y * params.modelWidth + gid.x) * 5;
    const float2 prevFlow = float2(flowMask[offset + 0], flowMask[offset + 1]);
    const float2 currFlow = float2(flowMask[offset + 2], flowMask[offset + 3]);
    const float2 motionFromPrev = -prevFlow / oldT;
    const float2 motionFromCurr = currFlow / max(0.001, 1.0 - oldT);
    const float2 motion = mix(motionFromPrev, motionFromCurr, 0.5);
    flowMask[offset + 0] = -motion.x * newT;
    flowMask[offset + 1] = -motion.y * newT;
    flowMask[offset + 2] = motion.x * (1.0 - newT);
    flowMask[offset + 3] = motion.y * (1.0 - newT);
}

struct RIFEMetal4FlowMaskSample {
    float4 flow;
    float mask;
};

static inline RIFEMetal4FlowMaskSample sm_metal4_flow_mask_bilinear(device const float* flowMask, uint width, uint height, float2 pos) {
    const float2 clamped = clamp(pos, float2(0.0), float2(width - 1, height - 1));
    const uint2 p0 = uint2(floor(clamped));
    const uint2 p1 = uint2(min(p0 + uint2(1), uint2(width - 1, height - 1)));
    const float2 f = fract(clamped);
    const uint o00 = (p0.y * width + p0.x) * 5;
    const uint o10 = (p0.y * width + p1.x) * 5;
    const uint o01 = (p1.y * width + p0.x) * 5;
    const uint o11 = (p1.y * width + p1.x) * 5;
    const float4 af = float4(flowMask[o00 + 0], flowMask[o00 + 1], flowMask[o00 + 2], flowMask[o00 + 3]);
    const float4 bf = float4(flowMask[o10 + 0], flowMask[o10 + 1], flowMask[o10 + 2], flowMask[o10 + 3]);
    const float4 cf = float4(flowMask[o01 + 0], flowMask[o01 + 1], flowMask[o01 + 2], flowMask[o01 + 3]);
    const float4 df = float4(flowMask[o11 + 0], flowMask[o11 + 1], flowMask[o11 + 2], flowMask[o11 + 3]);
    const float4 flow = mix(mix(af, bf, f.x), mix(cf, df, f.x), f.y);
    const float am = flowMask[o00 + 4];
    const float bm = flowMask[o10 + 4];
    const float cm = flowMask[o01 + 4];
    const float dm = flowMask[o11 + 4];
    RIFEMetal4FlowMaskSample out;
    out.flow = flow;
    out.mask = mix(mix(am, bm, f.x), mix(cm, dm, f.x), f.y);
    return out;
}

kernel void rife_metal4_blend_flow_bgra(texture2d<float, access::sample> previousFrame [[texture(0)]],
                                        texture2d<float, access::sample> currentFrame [[texture(1)]],
                                        texture2d<float, access::write> outFrame [[texture(2)]],
                                        device const float* flowMask [[buffer(0)]],
                                        constant RIFEMetal4Params& params [[buffer(1)]],
                                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    constexpr sampler linearSampler(coord::pixel, address::clamp_to_edge, filter::linear);
    const float2 sourcePos = float2(gid) + 0.5;
    const float2 modelScale = float2(params.modelWidth, params.modelHeight) / float2(params.width, params.height);
    const float2 modelPos = sourcePos * modelScale - 0.5;
    const RIFEMetal4FlowMaskSample fm = sm_metal4_flow_mask_bilinear(flowMask, params.modelWidth, params.modelHeight, modelPos);
    const float3 a = previousFrame.sample(linearSampler, sourcePos + fm.flow.xy).rgb;
    const float3 b = currentFrame.sample(linearSampler, sourcePos + fm.flow.zw).rgb;
    const float3 prevNative = previousFrame.sample(linearSampler, sourcePos).rgb;
    const float3 currNative = currentFrame.sample(linearSampler, sourcePos).rgb;
    const float3 native = mix(prevNative, currNative, clamp(params.t, 0.0, 1.0));
    float3 rgb = mix(b, a, clamp(fm.mask, 0.0, 1.0));

    const float2 dx = float2(1.0, 0.0);
    const float2 dy = float2(0.0, 1.0);
    const float prevEdge = abs(luma3(previousFrame.sample(linearSampler, sourcePos + dx).rgb) -
                               luma3(previousFrame.sample(linearSampler, sourcePos - dx).rgb)) +
                           abs(luma3(previousFrame.sample(linearSampler, sourcePos + dy).rgb) -
                               luma3(previousFrame.sample(linearSampler, sourcePos - dy).rgb));
    const float currEdge = abs(luma3(currentFrame.sample(linearSampler, sourcePos + dx).rgb) -
                               luma3(currentFrame.sample(linearSampler, sourcePos - dx).rgb)) +
                           abs(luma3(currentFrame.sample(linearSampler, sourcePos + dy).rgb) -
                               luma3(currentFrame.sample(linearSampler, sourcePos - dy).rgb));
    const float sourceEdge = clamp(max(prevEdge, currEdge) * 2.4, 0.0, 1.0);
    const float warpMismatch = abs(luma3(a) - luma3(b));
    const float nativeMismatch = abs(luma3(prevNative) - luma3(currNative));
    const float temporalGuard = smoothstep(0.06, 0.22, warpMismatch - nativeMismatch * 0.35);
    const float flowLength = max(length(fm.flow.xy), length(fm.flow.zw));
    const float flowGuard = smoothstep(8.0, 16.0, flowLength);
    const float protect = clamp(sourceEdge * 0.45 + temporalGuard * 0.42 + flowGuard * 0.28, 0.0, 0.72);
    rgb = mix(rgb, native, clamp(clamp(params.nativeBlend, 0.0, 0.20) + protect, 0.0, 0.85));
    outFrame.write(float4(clamp(rgb, 0.0, 1.0), 1.0), gid);
}

kernel void rife_sp4_a1p_residual_refine_bgra(texture2d<float, access::sample> previousFrame [[texture(0)]],
                                              texture2d<float, access::sample> currentFrame [[texture(1)]],
                                              texture2d<float, access::sample> int4Frame [[texture(2)]],
                                              texture2d<float, access::write> outFrame [[texture(3)]],
                                              constant SP4RefineParams& params [[buffer(0)]],
                                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }

    constexpr sampler linearSampler(coord::pixel, address::clamp_to_edge, filter::linear);
    const float2 p = float2(gid) + 0.5;
    const float3 prev = previousFrame.sample(linearSampler, p).rgb;
    const float3 curr = currentFrame.sample(linearSampler, p).rgb;
    const float3 main = int4Frame.sample(linearSampler, p).rgb;
    const float t = clamp(params.t, 0.0, 1.0);
    const float3 native = mix(prev, curr, t);

    const float2 dx = float2(1.0, 0.0);
    const float2 dy = float2(0.0, 1.0);
    const float prevEdge = abs(luma3(previousFrame.sample(linearSampler, p + dx).rgb) -
                               luma3(previousFrame.sample(linearSampler, p - dx).rgb)) +
                           abs(luma3(previousFrame.sample(linearSampler, p + dy).rgb) -
                               luma3(previousFrame.sample(linearSampler, p - dy).rgb));
    const float currEdge = abs(luma3(currentFrame.sample(linearSampler, p + dx).rgb) -
                               luma3(currentFrame.sample(linearSampler, p - dx).rgb)) +
                           abs(luma3(currentFrame.sample(linearSampler, p + dy).rgb) -
                               luma3(currentFrame.sample(linearSampler, p - dy).rgb));
    const float mainEdge = abs(luma3(int4Frame.sample(linearSampler, p + dx).rgb) -
                               luma3(int4Frame.sample(linearSampler, p - dx).rgb)) +
                           abs(luma3(int4Frame.sample(linearSampler, p + dy).rgb) -
                               luma3(int4Frame.sample(linearSampler, p - dy).rgb));

    const float motion = length(curr - prev);
    const float edgeDelta = abs(mainEdge - max(prevEdge, currEdge));
    const float temporalError = abs(luma3(main) - luma3(native));
    const float sensitive = clamp(edgeDelta * params.edgeProtect + temporalError * params.temporalProtect + motion * 0.18,
                                  0.0,
                                  1.0);
    const float residualWeight = clamp(params.residualStrength * sensitive, 0.0, 0.24);
    const float3 residual = native - main;
    float3 refined = main + residual * residualWeight;

    const float3 sourceMin = min(prev, curr);
    const float3 sourceMax = max(prev, curr);
    const float refinedMax = max(max(refined.r, refined.g), refined.b);
    const float refinedMin = min(min(refined.r, refined.g), refined.b);
    const float sourceMaxScalar = max(max(sourceMax.r, sourceMax.g), sourceMax.b);
    const float sourceMinScalar = min(min(sourceMin.r, sourceMin.g), sourceMin.b);
    const float overshoot = refinedMax - sourceMaxScalar;
    const float undershoot = sourceMinScalar - refinedMin;
    const float guard = clamp(max(overshoot, undershoot) * 2.0, 0.0, 1.0);
    refined = mix(refined, clamp(refined, sourceMin, sourceMax), guard * 0.45);

    outFrame.write(float4(clamp(refined, 0.0, 1.0), 1.0), gid);
}

kernel void rife_sp4_a1p_blend_refine_flow_bgra(texture2d<float, access::sample> previousFrame [[texture(0)]],
                                                texture2d<float, access::sample> currentFrame [[texture(1)]],
                                                texture2d<float, access::write> outFrame [[texture(2)]],
                                                device const float* flowMask [[buffer(0)]],
                                                constant RIFEMetal4Params& flowParams [[buffer(1)]],
                                                constant SP4RefineParams& refineParams [[buffer(2)]],
                                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= flowParams.width || gid.y >= flowParams.height) {
        return;
    }

    constexpr sampler linearSampler(coord::pixel, address::clamp_to_edge, filter::linear);
    const float2 sourcePos = float2(gid) + 0.5;
    const float2 modelScale = float2(flowParams.modelWidth, flowParams.modelHeight) /
                              float2(flowParams.width, flowParams.height);
    const float2 modelPos = sourcePos * modelScale - 0.5;
    const RIFEMetal4FlowMaskSample fm = sm_metal4_flow_mask_bilinear(flowMask,
                                                                     flowParams.modelWidth,
                                                                     flowParams.modelHeight,
                                                                     modelPos);
    const float3 warpedPrev = previousFrame.sample(linearSampler, sourcePos + fm.flow.xy).rgb;
    const float3 warpedCurr = currentFrame.sample(linearSampler, sourcePos + fm.flow.zw).rgb;
    const float3 prev = previousFrame.sample(linearSampler, sourcePos).rgb;
    const float3 curr = currentFrame.sample(linearSampler, sourcePos).rgb;
    const float t = clamp(flowParams.t, 0.0, 1.0);
    const float3 native = mix(prev, curr, t);
    float3 main = mix(warpedCurr, warpedPrev, clamp(fm.mask, 0.0, 1.0));

    const float2 dx = float2(1.0, 0.0);
    const float2 dy = float2(0.0, 1.0);
    const float prevEdge = abs(luma3(previousFrame.sample(linearSampler, sourcePos + dx).rgb) -
                               luma3(previousFrame.sample(linearSampler, sourcePos - dx).rgb)) +
                           abs(luma3(previousFrame.sample(linearSampler, sourcePos + dy).rgb) -
                               luma3(previousFrame.sample(linearSampler, sourcePos - dy).rgb));
    const float currEdge = abs(luma3(currentFrame.sample(linearSampler, sourcePos + dx).rgb) -
                               luma3(currentFrame.sample(linearSampler, sourcePos - dx).rgb)) +
                           abs(luma3(currentFrame.sample(linearSampler, sourcePos + dy).rgb) -
                               luma3(currentFrame.sample(linearSampler, sourcePos - dy).rgb));
    const float sourceEdge = clamp(max(prevEdge, currEdge) * 2.4, 0.0, 1.0);
    const float warpMismatch = abs(luma3(warpedPrev) - luma3(warpedCurr));
    const float nativeMismatch = abs(luma3(prev) - luma3(curr));
    const float temporalGuard = smoothstep(0.06, 0.22, warpMismatch - nativeMismatch * 0.35);
    const float flowLength = max(length(fm.flow.xy), length(fm.flow.zw));
    const float flowGuard = smoothstep(8.0, 16.0, flowLength);
    const float protect = clamp(sourceEdge * 0.45 + temporalGuard * 0.42 + flowGuard * 0.28, 0.0, 0.72);
    main = mix(main, native, clamp(clamp(flowParams.nativeBlend, 0.0, 0.20) + protect, 0.0, 0.85));

    const float mainEdge = abs(luma3(main) - luma3(native));
    const float motion = length(curr - prev);
    const float temporalError = abs(luma3(main) - luma3(native));
    const float sensitive = clamp(mainEdge * refineParams.edgeProtect +
                                  temporalError * refineParams.temporalProtect +
                                  motion * 0.18,
                                  0.0,
                                  1.0);
    const float residualWeight = clamp(refineParams.residualStrength * sensitive, 0.0, 0.24);
    float3 refined = main + (native - main) * residualWeight;

    const float3 sourceMin = min(prev, curr);
    const float3 sourceMax = max(prev, curr);
    const float refinedMax = max(max(refined.r, refined.g), refined.b);
    const float refinedMin = min(min(refined.r, refined.g), refined.b);
    const float sourceMaxScalar = max(max(sourceMax.r, sourceMax.g), sourceMax.b);
    const float sourceMinScalar = min(min(sourceMin.r, sourceMin.g), sourceMin.b);
    const float overshoot = refinedMax - sourceMaxScalar;
    const float undershoot = sourceMinScalar - refinedMin;
    const float guard = clamp(max(overshoot, undershoot) * 2.0, 0.0, 1.0);
    refined = mix(refined, clamp(refined, sourceMin, sourceMax), guard * 0.45);

    outFrame.write(float4(clamp(refined, 0.0, 1.0), 1.0), gid);
}

kernel void yuv_pack_stub(texture2d<float, access::sample> yTex [[texture(0)]],
                          texture2d<float, access::sample> uvTex [[texture(1)]],
                          texture2d<half, access::write> outTex [[texture(2)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) {
        return;
    }
    constexpr sampler linearSampler(coord::pixel, address::clamp_to_edge, filter::linear);
    const float y = yTex.sample(linearSampler, float2(gid)).r;
    const float2 uv = uvTex.sample(linearSampler, float2(gid) * 0.5).rg - float2(0.5);
    const float3 rgb = float3(y + 1.402 * uv.y,
                              y - 0.344136 * uv.x - 0.714136 * uv.y,
                              y + 1.772 * uv.x);
    outTex.write(half4(half3(clamp(rgb, 0.0, 1.0)), half(1.0)), gid);
}

kernel void fused_yuv420_to_rgb16f_resize_normalize(texture2d<float, access::sample> yTex [[texture(0)]],
                                                    texture2d<float, access::sample> uvTex [[texture(1)]],
                                                    texture2d<half, access::write> outTex [[texture(2)]],
                                                    constant YUVPackParams& params [[buffer(0)]],
                                                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.outWidth || gid.y >= params.outHeight) {
        return;
    }

    constexpr sampler linearSampler(coord::pixel, address::clamp_to_edge, filter::linear);
    const float2 uvOut = (float2(gid) + 0.5) / float2(params.outWidth, params.outHeight);
    const float2 src = uvOut * params.sourceSize;
    const float y = yTex.sample(linearSampler, src).r;
    const float2 chroma = uvTex.sample(linearSampler, src * 0.5).rg;
    const float3 rgb = yuv_to_rgb(y, chroma) * params.normalizeScale + params.normalizeBias;
    outTex.write(half4(half3(rgb), half(1.0)), gid);
}

kernel void fused_scene_duplicate_stats(texture2d<half, access::read> frame0 [[texture(0)]],
                                        texture2d<half, access::read> frame1 [[texture(1)]],
                                        device atomic_uint* stats [[buffer(0)]],
                                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= frame0.get_width() || gid.y >= frame0.get_height()) {
        return;
    }

    const half4 a = frame0.read(gid);
    const half4 b = frame1.read(gid);
    const float3 diff = abs(float3(a.rgb) - float3(b.rgb));
    const float lumaDiff = dot(diff, float3(0.299, 0.587, 0.114));
    const uint scaled = uint(clamp(lumaDiff * 4096.0, 0.0, 4095.0));
    atomic_fetch_add_explicit(&stats[0], scaled, memory_order_relaxed);
    if (lumaDiff < 0.003) {
        atomic_fetch_add_explicit(&stats[1], 1, memory_order_relaxed);
    }
    if (lumaDiff > 0.20) {
        atomic_fetch_add_explicit(&stats[2], 1, memory_order_relaxed);
    }
}

kernel void backward_warp_stub(texture2d<half, access::sample> frameTex [[texture(0)]],
                               texture2d<half, access::sample> flowTex [[texture(1)]],
                               texture2d<half, access::write> outTex [[texture(2)]],
                               uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) {
        return;
    }
    constexpr sampler linearSampler(coord::pixel, address::clamp_to_edge, filter::linear);
    const half2 flow = flowTex.sample(linearSampler, float2(gid)).rg;
    const half4 color = frameTex.sample(linearSampler, float2(gid) + float2(flow));
    outTex.write(color, gid);
}

kernel void fused_flow_upscale_edge_aware(texture2d<half, access::sample> lowFlow [[texture(0)]],
                                          texture2d<half, access::read> guideLuma [[texture(1)]],
                                          texture2d<half, access::write> highFlow [[texture(2)]],
                                          constant FlowUpscaleParams& params [[buffer(0)]],
                                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= highFlow.get_width() || gid.y >= highFlow.get_height()) {
        return;
    }

    constexpr sampler linearSampler(coord::pixel, address::clamp_to_edge, filter::linear);
    const float2 lowPos = (float2(gid) + 0.5) * params.inverseScale;
    float2 flow = float2(lowFlow.sample(linearSampler, lowPos).rg) * params.scale;

    const uint2 left = uint2(max(int(gid.x) - 1, 0), gid.y);
    const uint2 right = uint2(min(gid.x + 1, highFlow.get_width() - 1), gid.y);
    const uint2 up = uint2(gid.x, max(int(gid.y) - 1, 0));
    const uint2 down = uint2(gid.x, min(gid.y + 1, highFlow.get_height() - 1));
    const float gx = abs(float(guideLuma.read(left).r) - float(guideLuma.read(right).r));
    const float gy = abs(float(guideLuma.read(up).r) - float(guideLuma.read(down).r));
    const float edge = clamp((gx + gy) * params.edgeGain, 0.0, 1.0);
    flow *= (1.0 - edge * 0.18);
    highFlow.write(half4(half2(flow), half(edge), half(1.0)), gid);
}

kernel void fused_warp_occlusion_protect_refine(texture2d<half, access::sample> frame0 [[texture(0)]],
                                                texture2d<half, access::sample> frame1 [[texture(1)]],
                                                texture2d<half, access::sample> flow01 [[texture(2)]],
                                                texture2d<half, access::read> sourceGuide [[texture(3)]],
                                                texture2d<half, access::write> outTex [[texture(4)]],
                                                constant BlendProtectParams& params [[buffer(0)]],
                                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) {
        return;
    }

    constexpr sampler linearSampler(coord::pixel, address::clamp_to_edge, filter::linear);
    const float2 p = float2(gid) + 0.5;
    const half4 flowMask = flow01.sample(linearSampler, p);
    const float2 flow = float2(flowMask.rg);
    const float edge = float(flowMask.b);
    const float mask = clamp(float(flowMask.a), 0.0, 1.0);

    const half4 c0 = frame0.sample(linearSampler, p - flow * params.t);
    const half4 c1 = frame1.sample(linearSampler, p + flow * (1.0 - params.t));
    float4 blended = mix(float4(c0), float4(c1), clamp(params.t * mask, 0.0, 1.0));

    const float4 guide = float4(sourceGuide.read(gid));
    const float subtitleMask = smoothstep(params.subtitleThreshold, params.subtitleThreshold + 0.08, max(max(guide.r, guide.g), guide.b) - min(min(guide.r, guide.g), guide.b));
    const float protect = clamp(edge * params.lineGain + subtitleMask, 0.0, 1.0);
    blended = mix(blended, guide, protect * 0.55);

    const float3 sharpened = blended.rgb + (blended.rgb - guide.rgb) * params.refineStrength * (1.0 - protect);
    outTex.write(half4(half3(clamp(sharpened, 0.0, 1.0)), half(blended.a)), gid);
}

kernel void fused_bgra_interpolate_lanczos_present(texture2d<float, access::sample> previousFrame [[texture(0)]],
                                                   texture2d<float, access::sample> currentFrame [[texture(1)]],
                                                   texture2d<float, access::write> outFrame [[texture(2)]],
                                                   constant BGRAInterpolateParams& params [[buffer(0)]],
                                                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.outWidth || gid.y >= params.outHeight) {
        return;
    }

    constexpr sampler linearSampler(coord::pixel, address::clamp_to_edge, filter::linear);
    const float2 src = (float2(gid) + 0.5) * params.inverseUpscale;
    const float t = clamp(params.t, 0.0, 1.0);
    const float4 a = previousFrame.sample(linearSampler, src);
    const float4 b = currentFrame.sample(linearSampler, src);
    float2 bestMotion = float2(0.0);
    float bestScore = 1.0e9;

    for (int y = -6; y <= 6; y += 2) {
        for (int x = -6; x <= 6; x += 2) {
            const float2 motion = float2(x, y) * params.inverseUpscale;
            float score = 0.0;
            for (int py = -1; py <= 1; ++py) {
                for (int px = -1; px <= 1; ++px) {
                    const float2 p = float2(px, py) * params.inverseUpscale;
                    const float3 p0 = previousFrame.sample(linearSampler, src + p - motion * 0.5).rgb;
                    const float3 p1 = currentFrame.sample(linearSampler, src + p + motion * 0.5).rgb;
                    score += abs(luma3(p0) - luma3(p1));
                }
            }
            score += dot(motion, motion) * 0.012;
            if (score < bestScore) {
                bestScore = score;
                bestMotion = motion;
            }
        }
    }

    const float4 wa = previousFrame.sample(linearSampler, src - bestMotion * t);
    const float4 wb = currentFrame.sample(linearSampler, src + bestMotion * (1.0 - t));
    float4 mixed = mix(wa, wb, t);

    const float2 texel = params.inverseUpscale;
    const float4 left = previousFrame.sample(linearSampler, src - float2(texel.x, 0.0));
    const float4 right = previousFrame.sample(linearSampler, src + float2(texel.x, 0.0));
    const float4 up = previousFrame.sample(linearSampler, src - float2(0.0, texel.y));
    const float4 down = previousFrame.sample(linearSampler, src + float2(0.0, texel.y));
    const float edge = clamp(length((right.rgb - left.rgb) + (down.rgb - up.rgb)) * 0.35, 0.0, 1.0);
    mixed.rgb = mix(mixed.rgb, mix(a.rgb, b.rgb, t), edge * 0.18);
    mixed = clamp(mixed, 0.0, 1.0);
    mixed.a = 1.0;
    outFrame.write(mixed, gid);
}

static inline float3 rife_rgb_at(device const float* tensor, uint width, uint height, uint x, uint y) {
    const uint sx = min(x, width - 1);
    const uint sy = min(y, height - 1);
    const uint offset = (sy * width + sx) * 3;
    return float3(tensor[offset + 0], tensor[offset + 1], tensor[offset + 2]);
}

static inline float3 rife_rgb_bilinear(device const float* tensor, uint width, uint height, float2 pos) {
    const float2 base = floor(pos);
    const float2 f = fract(pos);
    const uint x0 = uint(clamp(int(base.x), 0, int(width) - 1));
    const uint y0 = uint(clamp(int(base.y), 0, int(height) - 1));
    const uint x1 = min(x0 + 1, width - 1);
    const uint y1 = min(y0 + 1, height - 1);
    const float3 a = rife_rgb_at(tensor, width, height, x0, y0);
    const float3 b = rife_rgb_at(tensor, width, height, x1, y0);
    const float3 c = rife_rgb_at(tensor, width, height, x0, y1);
    const float3 d = rife_rgb_at(tensor, width, height, x1, y1);
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

kernel void pack_bgra_pair_to_rife_input(texture2d<float, access::sample> previousFrame [[texture(0)]],
                                         texture2d<float, access::sample> currentFrame [[texture(1)]],
                                         device float* outTensor [[buffer(0)]],
                                         constant RIFETextureParams& params [[buffer(1)]],
                                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.modelWidth || gid.y >= params.modelHeight) {
        return;
    }

    constexpr sampler linearSampler(coord::pixel, address::clamp_to_edge, filter::linear);
    const float2 scale = float2(params.width, params.height) / float2(params.modelWidth, params.modelHeight);
    const float2 src = (float2(gid) + 0.5) * scale;
    const float4 a = previousFrame.sample(linearSampler, src);
    const float4 b = currentFrame.sample(linearSampler, src);
    const uint offset = (gid.y * params.modelWidth + gid.x) * 6;
    outTensor[offset + 0] = clamp(a.r, 0.0, 1.0);
    outTensor[offset + 1] = clamp(a.g, 0.0, 1.0);
    outTensor[offset + 2] = clamp(a.b, 0.0, 1.0);
    outTensor[offset + 3] = clamp(b.r, 0.0, 1.0);
    outTensor[offset + 4] = clamp(b.g, 0.0, 1.0);
    outTensor[offset + 5] = clamp(b.b, 0.0, 1.0);
}

kernel void unpack_rife_output_to_bgra(device const float* inTensor [[buffer(0)]],
                                       texture2d<float, access::sample> previousFrame [[texture(0)]],
                                       texture2d<float, access::sample> currentFrame [[texture(1)]],
                                       texture2d<float, access::write> outFrame [[texture(2)]],
                                       constant RIFETextureParams& params [[buffer(1)]],
                                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }

    constexpr sampler linearSampler(coord::pixel, address::clamp_to_edge, filter::linear);
    const float2 modelScale = float2(params.modelWidth, params.modelHeight) / float2(params.width, params.height);
    const float2 modelPos = (float2(gid) + 0.5) * modelScale - 0.5;
    const float2 clampedPos = clamp(modelPos, float2(0.0), float2(params.modelWidth - 1, params.modelHeight - 1));
    float3 rgb = rife_rgb_bilinear(inTensor, params.modelWidth, params.modelHeight, clampedPos);

    const float2 src = float2(gid) + 0.5;
    const float3 nativeBlend = mix(previousFrame.sample(linearSampler, src).rgb,
                                   currentFrame.sample(linearSampler, src).rgb,
                                   0.5);
    rgb = mix(rgb, nativeBlend, 0.06);
    outFrame.write(float4(clamp(rgb, 0.0, 1.0), 1.0), gid);
}

static float4 coreml_flow_at(device const float* flowMask, uint width, uint height, uint x, uint y) {
    const uint offset = (min(y, height - 1) * width + min(x, width - 1)) * 5;
    return float4(flowMask[offset + 0], flowMask[offset + 1], flowMask[offset + 2], flowMask[offset + 3]);
}

static float coreml_mask_at(device const float* flowMask, uint width, uint height, uint x, uint y) {
    const uint offset = (min(y, height - 1) * width + min(x, width - 1)) * 5;
    return flowMask[offset + 4];
}

static float sigmoid_fast(float x) {
    return 1.0 / (1.0 + exp(-x));
}

kernel void clear_rife_coreml_flow_mask(device float* flowMask [[buffer(0)]],
                                        constant RIFECoreMLBlockParams& params [[buffer(1)]],
                                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.modelWidth || gid.y >= params.modelHeight) {
        return;
    }
    const uint offset = (gid.y * params.modelWidth + gid.x) * 5;
    flowMask[offset + 0] = 0.0;
    flowMask[offset + 1] = 0.0;
    flowMask[offset + 2] = 0.0;
    flowMask[offset + 3] = 0.0;
    flowMask[offset + 4] = 0.0;
}

kernel void pack_rife_coreml_block_input(texture2d<float, access::sample> previousFrame [[texture(0)]],
                                         texture2d<float, access::sample> currentFrame [[texture(1)]],
                                         device const float* flowMask [[buffer(0)]],
                                         device float* xTensor [[buffer(1)]],
                                         device float* flowTensor [[buffer(2)]],
                                         constant RIFECoreMLBlockParams& params [[buffer(3)]],
                                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.modelWidth || gid.y >= params.modelHeight) {
        return;
    }

    constexpr sampler linearSampler(coord::pixel, address::clamp_to_edge, filter::linear);
    const float2 sourceScale = float2(params.width, params.height) / float2(params.modelWidth, params.modelHeight);
    const float2 modelBase = float2(gid) + 0.5;
    const float4 flow = coreml_flow_at(flowMask, params.modelWidth, params.modelHeight, gid.x, gid.y);
    const float mask = coreml_mask_at(flowMask, params.modelWidth, params.modelHeight, gid.x, gid.y);
    const bool reverse = params.reverse != 0;
    const float2 firstFlow = reverse ? flow.zw : flow.xy;
    const float2 secondFlow = reverse ? flow.xy : flow.zw;
    const float2 firstPos = (modelBase + firstFlow) * sourceScale;
    const float2 secondPos = (modelBase + secondFlow) * sourceScale;
    const float3 first = reverse ? currentFrame.sample(linearSampler, firstPos).rgb : previousFrame.sample(linearSampler, firstPos).rgb;
    const float3 second = reverse ? previousFrame.sample(linearSampler, secondPos).rgb : currentFrame.sample(linearSampler, secondPos).rgb;
    const float4 flowInput = reverse ? float4(flow.z, flow.w, flow.x, flow.y) : flow;

    const uint pixel = gid.y * params.modelWidth + gid.x;
    const uint xOffset = pixel * 7;
    xTensor[xOffset + 0] = clamp(first.r, 0.0, 1.0);
    xTensor[xOffset + 1] = clamp(first.g, 0.0, 1.0);
    xTensor[xOffset + 2] = clamp(first.b, 0.0, 1.0);
    xTensor[xOffset + 3] = clamp(second.r, 0.0, 1.0);
    xTensor[xOffset + 4] = clamp(second.g, 0.0, 1.0);
    xTensor[xOffset + 5] = clamp(second.b, 0.0, 1.0);
    xTensor[xOffset + 6] = reverse ? -mask : mask;

    const uint flowOffset = pixel * 4;
    flowTensor[flowOffset + 0] = flowInput.x;
    flowTensor[flowOffset + 1] = flowInput.y;
    flowTensor[flowOffset + 2] = flowInput.z;
    flowTensor[flowOffset + 3] = flowInput.w;
}

kernel void accumulate_rife_coreml_block_output(device const float* forwardOut [[buffer(0)]],
                                                device const float* reverseOut [[buffer(1)]],
                                                device float* flowMask [[buffer(2)]],
                                                constant RIFECoreMLBlockParams& params [[buffer(3)]],
                                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.modelWidth || gid.y >= params.modelHeight) {
        return;
    }
    const uint pixel = gid.y * params.modelWidth + gid.x;
    const uint outOffset = pixel * 5;
    const float4 f0 = float4(forwardOut[outOffset + 0], forwardOut[outOffset + 1], forwardOut[outOffset + 2], forwardOut[outOffset + 3]);
    const float4 f1 = float4(reverseOut[outOffset + 0], reverseOut[outOffset + 1], reverseOut[outOffset + 2], reverseOut[outOffset + 3]);
    const float m0 = forwardOut[outOffset + 4];
    const float m1 = reverseOut[outOffset + 4];
    flowMask[outOffset + 0] += (f0.x + f1.z) * 0.5;
    flowMask[outOffset + 1] += (f0.y + f1.w) * 0.5;
    flowMask[outOffset + 2] += (f0.z + f1.x) * 0.5;
    flowMask[outOffset + 3] += (f0.w + f1.y) * 0.5;
    flowMask[outOffset + 4] += (m0 - m1) * 0.5;
}

struct FlowMaskSample {
    float4 flow;
    float mask;
};

static FlowMaskSample flow_mask_bilinear(device const float* flowMask, uint width, uint height, float2 pos) {
    const float2 clamped = clamp(pos, float2(0.0), float2(width - 1, height - 1));
    const uint2 p0 = uint2(floor(clamped));
    const uint2 p1 = uint2(min(p0 + uint2(1), uint2(width - 1, height - 1)));
    const float2 f = fract(clamped);
    const uint o00 = (p0.y * width + p0.x) * 5;
    const uint o10 = (p0.y * width + p1.x) * 5;
    const uint o01 = (p1.y * width + p0.x) * 5;
    const uint o11 = (p1.y * width + p1.x) * 5;
    const float4 af = float4(flowMask[o00 + 0], flowMask[o00 + 1], flowMask[o00 + 2], flowMask[o00 + 3]);
    const float4 bf = float4(flowMask[o10 + 0], flowMask[o10 + 1], flowMask[o10 + 2], flowMask[o10 + 3]);
    const float4 cf = float4(flowMask[o01 + 0], flowMask[o01 + 1], flowMask[o01 + 2], flowMask[o01 + 3]);
    const float4 df = float4(flowMask[o11 + 0], flowMask[o11 + 1], flowMask[o11 + 2], flowMask[o11 + 3]);
    const float am = flowMask[o00 + 4];
    const float bm = flowMask[o10 + 4];
    const float cm = flowMask[o01 + 4];
    const float dm = flowMask[o11 + 4];
    FlowMaskSample out;
    out.flow = mix(mix(af, bf, f.x), mix(cf, df, f.x), f.y);
    out.mask = mix(mix(am, bm, f.x), mix(cm, dm, f.x), f.y);
    return out;
}

kernel void blend_rife_coreml_flow_to_bgra(texture2d<float, access::sample> previousFrame [[texture(0)]],
                                           texture2d<float, access::sample> currentFrame [[texture(1)]],
                                           texture2d<float, access::write> outFrame [[texture(2)]],
                                           device const float* flowMask [[buffer(0)]],
                                           constant RIFECoreMLBlockParams& params [[buffer(1)]],
                                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    constexpr sampler linearSampler(coord::pixel, address::clamp_to_edge, filter::linear);
    const float2 modelScale = float2(params.modelWidth, params.modelHeight) / float2(params.width, params.height);
    const float2 sourceScale = float2(params.width, params.height) / float2(params.modelWidth, params.modelHeight);
    const float2 modelPos = (float2(gid) + 0.5) * modelScale - 0.5;
    const FlowMaskSample fm = flow_mask_bilinear(flowMask, params.modelWidth, params.modelHeight, modelPos);
    const float2 baseModel = modelPos + 0.5;
    const float3 a = previousFrame.sample(linearSampler, (baseModel + fm.flow.xy) * sourceScale).rgb;
    const float3 b = currentFrame.sample(linearSampler, (baseModel + fm.flow.zw) * sourceScale).rgb;
    const float m = sigmoid_fast(fm.mask);
    const float3 nativeBlend = mix(previousFrame.sample(linearSampler, float2(gid) + 0.5).rgb,
                                   currentFrame.sample(linearSampler, float2(gid) + 0.5).rgb,
                                   0.5);
    const float3 rgb = mix(mix(b, a, m), nativeBlend, 0.04);
    outFrame.write(float4(clamp(rgb, 0.0, 1.0), 1.0), gid);
}

kernel void present_stub(texture2d<half, access::read> inTex [[texture(0)]],
                         texture2d<half, access::write> outTex [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) {
        return;
    }
    outTex.write(inTex.read(gid), gid);
}
