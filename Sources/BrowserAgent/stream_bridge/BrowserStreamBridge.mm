#include "BrowserAgent/stream_bridge/BrowserStreamBridge.h"
#include "Core/RealtimeVFISession.h"
#include "VFI/RIFECoreMLRunner.h"
#include "VFI/RIFEMetal4BitRunner.h"
#include "VFI/RIFEMPSGraphRunner.h"
#include "VFI/RIFESP4Runner.h"

#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <VideoToolbox/VideoToolbox.h>
#import <simd/simd.h>

#include <arpa/inet.h>
#include <array>
#include <cmath>
#include <cstring>
#include <cstdlib>
#include <errno.h>
#include <fcntl.h>
#include <limits>
#include <memory>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unordered_map>
#include <unistd.h>
#include <vector>

@interface SMEncodedVideoChunk : NSObject
@property(strong) NSData* data;
@property(strong) NSData* codecDescription;
@property(assign) BOOL keyFrame;
@end

@interface SMProcessedOutputFrame : NSObject
@property(strong) NSData* payload;
@property(strong) SMEncodedVideoChunk* chunk;
@property(assign) NSUInteger width;
@property(assign) NSUInteger height;
@property(assign) uint32_t subIndex;
@property(assign) uint32_t subCount;
@property(assign) uint64_t frameId;
@property(assign) uint64_t processedFrames;
@property(assign) uint64_t receivedFrames;
@property(assign) double targetFPS;
@property(assign) double gpuMs;
@property(assign) int64_t durationUs;
@end

namespace {

constexpr const char* kWebSocketGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
constexpr size_t kMaxPayloadBytes = 12 * 1024 * 1024;
constexpr uint32_t kSMBinaryFrameMagic = 0x31464d53; // "SMF1", little endian
constexpr uint32_t kSMBinaryOutputMagic = 0x314f4d53; // "SMO1", little endian
constexpr uint16_t kSMBinaryFrameVersion = 2;
constexpr uint16_t kSMBinaryOutputVersion = 1;
constexpr size_t kSMBinaryFrameHeaderBytesV1 = 84;
constexpr size_t kSMBinaryFrameHeaderBytes = 92;
constexpr size_t kSMBinaryOutputHeaderBytes = 72;
constexpr uint16_t kSMBinaryFlagKey = 1U << 0U;
constexpr uint16_t kSMBinaryFlagForceReturnKey = 1U << 1U;
constexpr uint16_t kSMBinaryFlagNoCPUReadback = 1U << 2U;
constexpr uint16_t kSMBinaryFlagUnlimited = 1U << 3U;
constexpr uint16_t kSMBinaryFlagHEVCMotionHints = 1U << 6U;
constexpr uint16_t kSMBinaryFlagROIMotionBlocks = 1U << 7U;
constexpr uint16_t kSMBinaryFlagDynamicMultiFrame = 1U << 9U;

enum class SMPowerTierKind : uint8_t {
    Quiet,
    Balanced,
    Quality,
};

struct SMNALUnit {
    const uint8_t* data = nullptr;
    size_t length = 0;
};

struct SMBGRAInterpolateParams {
    uint32_t outWidth;
    uint32_t outHeight;
    simd_float2 inverseUpscale;
    float t;
};

struct SMRIFETextureParams {
    uint32_t width;
    uint32_t height;
    uint32_t modelWidth;
    uint32_t modelHeight;
};

struct SMRIFECoreMLBlockParams {
    uint32_t width;
    uint32_t height;
    uint32_t modelWidth;
    uint32_t modelHeight;
    uint32_t reverse;
};

struct SMRIFEDimensions {
    uint32_t width = 0;
    uint32_t height = 0;
};

bool SMReadExact(int fd, uint8_t* dst, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t n = recv(fd, dst + offset, length - offset, 0);
        if (n <= 0) {
            return false;
        }
        offset += static_cast<size_t>(n);
    }
    return true;
}

bool SMSendAll(int fd, const uint8_t* data, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t n = send(fd, data + offset, length - offset, 0);
        if (n <= 0) {
            return false;
        }
        offset += static_cast<size_t>(n);
    }
    return true;
}

NSString* SMAcceptKey(NSString* key) {
    NSString* joined = [key stringByAppendingString:@(kWebSocketGuid)];
    NSData* input = [joined dataUsingEncoding:NSASCIIStringEncoding];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(input.bytes, static_cast<CC_LONG>(input.length), digest);
    NSData* output = [NSData dataWithBytes:digest length:sizeof(digest)];
    return [output base64EncodedStringWithOptions:0];
}

NSString* SMHeaderValue(NSString* request, NSString* name) {
    NSArray<NSString*>* lines = [request componentsSeparatedByString:@"\r\n"];
    NSString* prefix = [[name lowercaseString] stringByAppendingString:@":"];
    for (NSString* line in lines) {
        NSString* lower = [line lowercaseString];
        if (![lower hasPrefix:prefix]) {
            continue;
        }
        return [[line substringFromIndex:prefix.length] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    return nil;
}

bool SMSendFrame(int fd, uint8_t opcode, NSData* data) {
    uint8_t header[10] = {static_cast<uint8_t>(0x80 | (opcode & 0x0f)), 0, 0, 0, 0, 0, 0, 0, 0, 0};
    size_t headerLength = 2;
    const uint64_t length = data.length;
    if (length <= 125) {
        header[1] = static_cast<uint8_t>(length);
    } else if (length <= 65535) {
        header[1] = 126;
        header[2] = static_cast<uint8_t>((length >> 8) & 0xff);
        header[3] = static_cast<uint8_t>(length & 0xff);
        headerLength = 4;
    } else {
        header[1] = 127;
        for (int i = 0; i < 8; ++i) {
            header[2 + i] = static_cast<uint8_t>((length >> (56 - i * 8)) & 0xff);
        }
        headerLength = 10;
    }
    return SMSendAll(fd, header, headerLength) &&
           SMSendAll(fd, static_cast<const uint8_t*>(data.bytes), data.length);
}

bool SMSendTextFrame(int fd, NSString* text) {
    NSData* data = [text dataUsingEncoding:NSUTF8StringEncoding];
    return SMSendFrame(fd, 0x1, data);
}

bool SMSendBinaryFrame(int fd, NSData* data) {
    return SMSendFrame(fd, 0x2, data);
}

void SMAppendLE16(NSMutableData* data, uint16_t value) {
    const uint16_t le = CFSwapInt16HostToLittle(value);
    [data appendBytes:&le length:sizeof(le)];
}

void SMAppendLE32(NSMutableData* data, uint32_t value) {
    const uint32_t le = CFSwapInt32HostToLittle(value);
    [data appendBytes:&le length:sizeof(le)];
}

void SMAppendLE64(NSMutableData* data, uint64_t value) {
    const uint64_t le = CFSwapInt64HostToLittle(value);
    [data appendBytes:&le length:sizeof(le)];
}

void SMAppendLEDouble(NSMutableData* data, double value) {
    uint64_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    SMAppendLE64(data, bits);
}

uint32_t SMBinaryCodecIdForOutput(NSString* codec, BOOL jpeg) {
    if (jpeg) {
        return 4;
    }
    NSString* normalized = [codec lowercaseString] ?: @"";
    if ([normalized containsString:@"hvc"] || [normalized containsString:@"hev"]) {
        return 2;
    }
    if ([normalized containsString:@"av1"] || [normalized containsString:@"av01"]) {
        return 3;
    }
    return 1;
}

NSData* SMBinaryOutputFrame(NSData* payload,
                            NSData* codecDescription,
                            uint64_t frameId,
                            BOOL keyFrame,
                            BOOL jpeg,
                            NSString* codec,
                            NSUInteger width,
                            NSUInteger height,
                            double duration,
                            double gpuMs,
                            uint64_t processedFrames,
                            uint64_t receivedFrames,
                            uint32_t subIndex,
                            uint32_t subCount) {
    if (payload.length == 0) {
        return nil;
    }
    NSMutableData* out = [NSMutableData dataWithCapacity:kSMBinaryOutputHeaderBytes + codecDescription.length + payload.length];
    SMAppendLE32(out, kSMBinaryOutputMagic);
    SMAppendLE16(out, kSMBinaryOutputVersion);
    SMAppendLE16(out, keyFrame ? kSMBinaryFlagKey : 0);
    SMAppendLE64(out, frameId);
    SMAppendLEDouble(out, duration);
    SMAppendLEDouble(out, gpuMs);
    SMAppendLE32(out, static_cast<uint32_t>(width));
    SMAppendLE32(out, static_cast<uint32_t>(height));
    SMAppendLE32(out, SMBinaryCodecIdForOutput(codec, jpeg));
    SMAppendLE32(out, static_cast<uint32_t>(payload.length));
    SMAppendLE32(out, static_cast<uint32_t>(codecDescription.length));
    SMAppendLE64(out, processedFrames);
    SMAppendLE64(out, receivedFrames);
    const uint32_t reserved = (subIndex & 0xffU) | ((subCount & 0xffU) << 8U);
    [out appendBytes:&reserved length:sizeof(reserved)];
    if (codecDescription.length > 0) {
        [out appendData:codecDescription];
    }
    [out appendData:payload];
    return out;
}

uint8_t SMNALType(const SMNALUnit& unit) {
    return unit.length > 0 ? (unit.data[0] & 0x1f) : 0;
}

uint8_t SMHEVCNALType(const SMNALUnit& unit) {
    return unit.length > 1 ? ((unit.data[0] >> 1) & 0x3f) : 0;
}

std::vector<SMNALUnit> SMFindAnnexBNALUnits(NSData* data) {
    std::vector<SMNALUnit> units;
    const uint8_t* bytes = static_cast<const uint8_t*>(data.bytes);
    const size_t length = data.length;
    auto startCodeLengthAt = [&](size_t i) -> size_t {
        if (i + 3 <= length && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1) {
            return 3;
        }
        if (i + 4 <= length && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 1) {
            return 4;
        }
        return 0;
    };

    size_t cursor = 0;
    while (cursor < length) {
        size_t prefix = 0;
        while (cursor < length && (prefix = startCodeLengthAt(cursor)) == 0) {
            cursor++;
        }
        if (cursor >= length) {
            break;
        }
        const size_t nalStart = cursor + prefix;
        cursor = nalStart;
        while (cursor < length && startCodeLengthAt(cursor) == 0) {
            cursor++;
        }
        size_t nalEnd = cursor;
        while (nalEnd > nalStart && bytes[nalEnd - 1] == 0) {
            nalEnd--;
        }
        if (nalEnd > nalStart) {
            units.push_back(SMNALUnit{bytes + nalStart, nalEnd - nalStart});
        }
    }
    return units;
}

std::vector<SMNALUnit> SMFindLengthPrefixedNALUnits(NSData* data) {
    std::vector<SMNALUnit> units;
    const uint8_t* bytes = static_cast<const uint8_t*>(data.bytes);
    const size_t length = data.length;
    size_t offset = 0;
    while (offset + 4 <= length) {
        uint32_t beLength = 0;
        std::memcpy(&beLength, bytes + offset, sizeof(beLength));
        const uint32_t nalLength = CFSwapInt32BigToHost(beLength);
        offset += 4;
        if (nalLength == 0 || offset + nalLength > length) {
            units.clear();
            return units;
        }
        units.push_back(SMNALUnit{bytes + offset, nalLength});
        offset += nalLength;
    }
    if (offset != length) {
        units.clear();
    }
    return units;
}

void SMAppendLengthPrefixedNAL(NSMutableData* out, const SMNALUnit& unit) {
    const uint32_t beLength = CFSwapInt32HostToBig(static_cast<uint32_t>(unit.length));
    [out appendBytes:&beLength length:sizeof(beLength)];
    [out appendBytes:unit.data length:unit.length];
}

uint16_t SMReadBE16(const uint8_t* bytes, size_t offset) {
    return static_cast<uint16_t>((static_cast<uint16_t>(bytes[offset]) << 8U) |
                                 static_cast<uint16_t>(bytes[offset + 1]));
}

uint16_t SMReadLE16(const uint8_t* bytes, size_t offset) {
    return static_cast<uint16_t>(bytes[offset] | (static_cast<uint16_t>(bytes[offset + 1]) << 8U));
}

uint32_t SMReadLE32(const uint8_t* bytes, size_t offset) {
    uint32_t value = 0;
    std::memcpy(&value, bytes + offset, sizeof(value));
    return CFSwapInt32LittleToHost(value);
}

uint64_t SMReadLE64(const uint8_t* bytes, size_t offset) {
    uint64_t value = 0;
    std::memcpy(&value, bytes + offset, sizeof(value));
    return CFSwapInt64LittleToHost(value);
}

double SMReadLEDouble(const uint8_t* bytes, size_t offset) {
    const uint64_t bits = SMReadLE64(bytes, offset);
    double value = 0.0;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

NSString* SMCodecStringFromBinaryId(uint32_t codec) {
    switch (codec) {
        case 2: return @"hevc";
        case 3: return @"av1";
        case 4: return @"jpeg";
        case 1:
        default: return @"h264";
    }
}

NSString* SMReturnCodecStringFromBinaryId(uint32_t codec) {
    return codec == 2 ? @"hevc" : @"h264";
}

NSString* SMPowerTierStringFromBinaryId(uint32_t tier) {
    switch (tier) {
        case 0: return @"静音";
        case 2: return @"质量";
        case 1:
        default: return @"均衡";
    }
}

SMPowerTierKind SMPowerTierKindFromString(NSString* tier) {
    NSString* normalized = [tier ?: @"" lowercaseString];
    if ([tier localizedCaseInsensitiveContainsString:@"静音"] ||
        [normalized containsString:@"silent"] ||
        [normalized containsString:@"quiet"]) {
        return SMPowerTierKind::Quiet;
    }
    if ([tier localizedCaseInsensitiveContainsString:@"质量"] ||
        [normalized containsString:@"quality"]) {
        return SMPowerTierKind::Quality;
    }
    return SMPowerTierKind::Balanced;
}

CMVideoFormatDescriptionRef SMH264DescriptionFromAVCC(NSData* avcC) {
    if (avcC.length < 7) {
        return nullptr;
    }
    const uint8_t* bytes = static_cast<const uint8_t*>(avcC.bytes);
    size_t offset = 5;
    const uint8_t spsCount = bytes[offset++] & 0x1fU;
    std::vector<std::vector<uint8_t>> storage;
    for (uint8_t i = 0; i < spsCount; ++i) {
        if (offset + 2 > avcC.length) {
            return nullptr;
        }
        const uint16_t length = SMReadBE16(bytes, offset);
        offset += 2;
        if (offset + length > avcC.length) {
            return nullptr;
        }
        storage.emplace_back(bytes + offset, bytes + offset + length);
        offset += length;
    }
    if (offset >= avcC.length) {
        return nullptr;
    }
    const uint8_t ppsCount = bytes[offset++];
    for (uint8_t i = 0; i < ppsCount; ++i) {
        if (offset + 2 > avcC.length) {
            return nullptr;
        }
        const uint16_t length = SMReadBE16(bytes, offset);
        offset += 2;
        if (offset + length > avcC.length) {
            return nullptr;
        }
        storage.emplace_back(bytes + offset, bytes + offset + length);
        offset += length;
    }
    if (storage.size() < 2) {
        return nullptr;
    }
    std::vector<const uint8_t*> pointers;
    std::vector<size_t> sizes;
    pointers.reserve(storage.size());
    sizes.reserve(storage.size());
    for (const auto& nal : storage) {
        pointers.push_back(nal.data());
        sizes.push_back(nal.size());
    }
    CMVideoFormatDescriptionRef description = nullptr;
    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                                                                          pointers.size(),
                                                                          pointers.data(),
                                                                          sizes.data(),
                                                                          4,
                                                                          &description);
    return status == noErr ? description : nullptr;
}

CMVideoFormatDescriptionRef SMHEVCDescriptionFromHVCC(NSData* hvcC) {
    if (hvcC.length < 23) {
        return nullptr;
    }
    const uint8_t* bytes = static_cast<const uint8_t*>(hvcC.bytes);
    size_t offset = 22;
    const uint8_t arrayCount = bytes[offset++];
    std::vector<std::vector<uint8_t>> storage;
    for (uint8_t arrayIndex = 0; arrayIndex < arrayCount; ++arrayIndex) {
        if (offset + 3 > hvcC.length) {
            return nullptr;
        }
        const uint8_t nalType = bytes[offset++] & 0x3fU;
        const uint16_t nalCount = SMReadBE16(bytes, offset);
        offset += 2;
        for (uint16_t nalIndex = 0; nalIndex < nalCount; ++nalIndex) {
            if (offset + 2 > hvcC.length) {
                return nullptr;
            }
            const uint16_t length = SMReadBE16(bytes, offset);
            offset += 2;
            if (offset + length > hvcC.length) {
                return nullptr;
            }
            if (nalType == 32 || nalType == 33 || nalType == 34) {
                storage.emplace_back(bytes + offset, bytes + offset + length);
            }
            offset += length;
        }
    }
    if (storage.size() < 3) {
        return nullptr;
    }
    std::vector<const uint8_t*> pointers;
    std::vector<size_t> sizes;
    pointers.reserve(storage.size());
    sizes.reserve(storage.size());
    for (const auto& nal : storage) {
        pointers.push_back(nal.data());
        sizes.push_back(nal.size());
    }
    CMVideoFormatDescriptionRef description = nullptr;
    OSStatus status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault,
                                                                          pointers.size(),
                                                                          pointers.data(),
                                                                          sizes.data(),
                                                                          4,
                                                                          nullptr,
                                                                          &description);
    return status == noErr ? description : nullptr;
}

uint32_t SMAlign16(NSUInteger value) {
    return static_cast<uint32_t>((value + 15U) & ~15U);
}

uint32_t SMRIFEWidthForHeight(NSUInteger sourceWidth, NSUInteger sourceHeight, uint32_t modelHeight) {
    if (sourceWidth == 0 || sourceHeight == 0 || modelHeight == 0) {
        return SMAlign16(MAX(static_cast<NSUInteger>(16), static_cast<NSUInteger>(modelHeight)));
    }
    const double aspect = static_cast<double>(sourceWidth) / static_cast<double>(sourceHeight);
    const NSUInteger width = static_cast<NSUInteger>(llround(static_cast<double>(modelHeight) * aspect));
    return SMAlign16(MAX(static_cast<NSUInteger>(16), width));
}

uint32_t SMFixedRIFEHeightForSource(NSUInteger sourceHeight, double requestedHeight) {
    double height = requestedHeight > 0.0 ? requestedHeight : 540.0;
    height = MAX(180.0, MIN(2160.0, height));
    if (sourceHeight > 0) {
        height = MIN(height, static_cast<double>(sourceHeight));
    }
    return SMAlign16(static_cast<NSUInteger>(llround(height)));
}


Stellaria::Motion::RealtimePowerTier SMRealtimeTier(SMPowerTierKind tier, BOOL unlimited) {
    if (unlimited) {
        return Stellaria::Motion::RealtimePowerTier::Ultimate;
    }
    switch (tier) {
        case SMPowerTierKind::Quality:
            return Stellaria::Motion::RealtimePowerTier::Quality;
        case SMPowerTierKind::Quiet:
            return Stellaria::Motion::RealtimePowerTier::Quiet;
        case SMPowerTierKind::Balanced:
        default:
            return Stellaria::Motion::RealtimePowerTier::Balanced;
    }
}

double SMStableTargetFPSForSourceFPS(double sourceFPS) {
    (void)sourceFPS;
    return 60.0;
}

MTLSize SMMemoryBoundThreadgroup(id<MTLComputePipelineState> pipeline) {
    const NSUInteger simdWidth = MAX(static_cast<NSUInteger>(1), pipeline.threadExecutionWidth);
    const NSUInteger maxThreads = MAX(simdWidth, MIN(static_cast<NSUInteger>(256), pipeline.maxTotalThreadsPerThreadgroup));
    const NSUInteger width = simdWidth;
    const NSUInteger height = MAX(static_cast<NSUInteger>(1), MIN(static_cast<NSUInteger>(8), maxThreads / width));
    return MTLSizeMake(width, height, 1);
}

[[maybe_unused]] bool SMCoreMLBlocksRealtimeEnabled() {
    const char* enabled = std::getenv("STELLARIA_MOTION_ENABLE_COREML_BLOCKS");
    return enabled != nullptr && std::strcmp(enabled, "1") == 0;
}

std::string SMRIFEModelPath() {
    NSString* resource = [[NSBundle mainBundle] pathForResource:@"flownet"
                                                         ofType:@"safetensors"
                                                    inDirectory:@"Models/RIFE-safetensors"];
    if (resource.length > 0) {
        return std::string(resource.UTF8String);
    }
    if (const char* env = std::getenv("STELLARIA_MOTION_RIFE_MODEL")) {
        return std::string(env);
    }
    return "Models/RIFE-safetensors/flownet.safetensors";
}

std::string SMRIFECoreMLModelPath() {
    NSString* resource = [[NSBundle mainBundle] pathForResource:@"RIFEStudent"
                                                         ofType:@"mlmodelc"
                                                    inDirectory:@"Models/RIFE-CoreML"];
    if (resource.length > 0) {
        return std::string(resource.UTF8String);
    }
    if (const char* env = std::getenv("STELLARIA_MOTION_RIFE_COREML_MODEL")) {
        return std::string(env);
    }
    return "Models/RIFE-CoreML/RIFEStudent.mlmodelc";
}

std::string SMRIFECoreMLBlockModelPath(int block, uint32_t modelWidth, uint32_t modelHeight) {
    NSString* fileName = [NSString stringWithFormat:@"block%d_s%d_%ux%u",
                                                    block,
                                                    block == 0 ? 4 : (block == 1 ? 2 : 1),
                                                    modelWidth,
                                                    modelHeight];
    NSString* resource = [[NSBundle mainBundle] pathForResource:fileName
                                                         ofType:@"mlpackage"
                                                    inDirectory:@"Models/RIFE-CoreML/conv_trunk"];
    if (resource.length > 0) {
        return std::string(resource.UTF8String);
    }
    NSString* fallback = [NSString stringWithFormat:@"Models/RIFE-CoreML/conv_trunk/%@.mlpackage", fileName];
    return std::string(fallback.UTF8String);
}

std::string SMRIFECoreMLContinuousModelPath(uint32_t modelWidth, uint32_t modelHeight) {
    NSString* fileName = [NSString stringWithFormat:@"rife_flow_mask_%ux%u", modelWidth, modelHeight];
    NSString* resource = [[NSBundle mainBundle] pathForResource:fileName
                                                         ofType:@"mlpackage"
                                                    inDirectory:@"Models/RIFE-CoreML/continuous_trunk"];
    if (resource.length > 0) {
        return std::string(resource.UTF8String);
    }
    NSString* compiled = [[NSBundle mainBundle] pathForResource:fileName
                                                         ofType:@"mlmodelc"
                                                    inDirectory:@"Models/RIFE-CoreML/continuous_trunk"];
    if (compiled.length > 0) {
        return std::string(compiled.UTF8String);
    }
    NSString* fallback = [NSString stringWithFormat:@"Models/RIFE-CoreML/continuous_trunk/%@.mlpackage", fileName];
    return std::string(fallback.UTF8String);
}

bool SMRIFECoreMLContinuousModelExists(uint32_t modelWidth, uint32_t modelHeight) {
    const std::string path = SMRIFECoreMLContinuousModelPath(modelWidth, modelHeight);
    return !path.empty() && [[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithUTF8String:path.c_str()]];
}

std::vector<SMRIFEDimensions> SMAvailableRIFECoreMLContinuousDimensions() {
    std::vector<SMRIFEDimensions> dimensions;
    NSMutableArray<NSString*>* directories = [NSMutableArray array];
    NSString* bundled = [[NSBundle mainBundle] pathForResource:@"continuous_trunk"
                                                        ofType:nil
                                                   inDirectory:@"Models/RIFE-CoreML"];
    if (bundled.length > 0) {
        [directories addObject:bundled];
    }
    [directories addObject:@"Models/RIFE-CoreML/continuous_trunk"];

    NSRegularExpression* regex = [NSRegularExpression regularExpressionWithPattern:@"^rife_flow_mask_([0-9]+)x([0-9]+)\\.(mlpackage|mlmodelc)$"
                                                                           options:0
                                                                             error:nil];
    NSFileManager* fileManager = [NSFileManager defaultManager];
    for (NSString* directory in directories) {
        NSArray<NSString*>* entries = [fileManager contentsOfDirectoryAtPath:directory error:nil];
        for (NSString* entry in entries) {
            NSTextCheckingResult* match = [regex firstMatchInString:entry options:0 range:NSMakeRange(0, entry.length)];
            if (match.numberOfRanges < 3) {
                continue;
            }
            const uint32_t width = static_cast<uint32_t>([[entry substringWithRange:[match rangeAtIndex:1]] integerValue]);
            const uint32_t height = static_cast<uint32_t>([[entry substringWithRange:[match rangeAtIndex:2]] integerValue]);
            if (width == 0 || height == 0) {
                continue;
            }
            bool duplicate = false;
            for (const SMRIFEDimensions& existing : dimensions) {
                if (existing.width == width && existing.height == height) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) {
                dimensions.push_back(SMRIFEDimensions{width, height});
            }
        }
    }
    if (dimensions.empty()) {
        dimensions = {
            {656, 368},
            {768, 432},
            {960, 544},
            {976, 544},
        };
    }
    return dimensions;
}

[[maybe_unused]] SMRIFEDimensions SMNearestRIFECoreMLContinuousDimensions(uint32_t requestedWidth,
                                                                          uint32_t requestedHeight,
                                                                          bool unlimited) {
    if (SMRIFECoreMLContinuousModelExists(requestedWidth, requestedHeight)) {
        return SMRIFEDimensions{requestedWidth, requestedHeight};
    }
    const double requestedAspect = requestedHeight > 0
        ? static_cast<double>(requestedWidth) / static_cast<double>(requestedHeight)
        : 16.0 / 9.0;
    SMRIFEDimensions best{requestedWidth, requestedHeight};
    double bestScore = std::numeric_limits<double>::infinity();
    for (const SMRIFEDimensions& candidate : SMAvailableRIFECoreMLContinuousDimensions()) {
        if (!SMRIFECoreMLContinuousModelExists(candidate.width, candidate.height)) {
            continue;
        }
        const double aspect = static_cast<double>(candidate.width) / static_cast<double>(candidate.height);
        const double aspectPenalty = std::abs(aspect - requestedAspect) * 1800.0;
        const double heightPenalty = std::abs(static_cast<double>(candidate.height) - requestedHeight);
        const double widthPenalty = std::abs(static_cast<double>(candidate.width) - requestedWidth) * 0.12;
        const double overshootPenalty = (!unlimited && candidate.height > requestedHeight) ? 1000.0 : 0.0;
        const double score = aspectPenalty + heightPenalty + widthPenalty + overshootPenalty;
        if (score < bestScore) {
            bestScore = score;
            best = candidate;
        }
    }
    return best;
}

void SMVTDecodeOutput(void*,
                      void* sourceFrameRefCon,
                      OSStatus status,
                      VTDecodeInfoFlags,
                      CVImageBufferRef imageBuffer,
                      CMTime,
                      CMTime) {
    if (status != noErr || imageBuffer == nullptr || sourceFrameRefCon == nullptr) {
        return;
    }
    CVPixelBufferRef* output = static_cast<CVPixelBufferRef*>(sourceFrameRefCon);
    if (*output != nullptr) {
        CVPixelBufferRelease(*output);
    }
    *output = CVPixelBufferRetain(static_cast<CVPixelBufferRef>(imageBuffer));
}

void SMVTEncodeOutput(void*,
                      void* sourceFrameRefCon,
                      OSStatus status,
                      VTEncodeInfoFlags,
                      CMSampleBufferRef sampleBuffer) {
    if (status != noErr || sampleBuffer == nullptr || sourceFrameRefCon == nullptr || !CMSampleBufferDataIsReady(sampleBuffer)) {
        return;
    }
    SMEncodedVideoChunk* chunk = (__bridge SMEncodedVideoChunk*)sourceFrameRefCon;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    BOOL keyFrame = YES;
    if (attachments != nullptr && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef attachment = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0));
        keyFrame = !CFDictionaryContainsKey(attachment, kCMSampleAttachmentKey_NotSync);
    }
    chunk.keyFrame = keyFrame;

    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (format != nullptr) {
        NSDictionary* atoms = (__bridge NSDictionary*)CMFormatDescriptionGetExtension(format, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
        NSData* avcC = [atoms[@"avcC"] isKindOfClass:NSData.class] ? atoms[@"avcC"] : nil;
        NSData* hvcC = [atoms[@"hvcC"] isKindOfClass:NSData.class] ? atoms[@"hvcC"] : nil;
        if (hvcC != nil) {
            chunk.codecDescription = hvcC;
        } else if (avcC != nil) {
            chunk.codecDescription = avcC;
        }
    }

    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (block == nullptr) {
        return;
    }
    size_t totalLength = 0;
    char* dataPointer = nullptr;
    OSStatus pointerStatus = CMBlockBufferGetDataPointer(block, 0, nullptr, &totalLength, &dataPointer);
    if (pointerStatus == noErr && dataPointer != nullptr && totalLength > 0) {
        chunk.data = [NSData dataWithBytes:dataPointer length:totalLength];
        return;
    }
    NSMutableData* copy = [NSMutableData dataWithLength:totalLength];
    if (totalLength > 0 && CMBlockBufferCopyDataBytes(block, 0, totalLength, copy.mutableBytes) == noErr) {
        chunk.data = copy;
    }
}

} // namespace

@implementation SMEncodedVideoChunk
@end

@implementation SMProcessedOutputFrame
@end

@interface SMBrowserStreamBridge () {
    std::unique_ptr<Stellaria::Motion::RealtimeVFISession> _realtimeSession;
    std::unordered_map<uint64_t, std::array<std::unique_ptr<Stellaria::Motion::RIFECoreMLBlockRunner>, 3>> _rifeCoreMLBlockRunnerCache;
    std::unordered_map<uint64_t, std::unique_ptr<Stellaria::Motion::RIFECoreMLRunner>> _rifeCoreMLRunnerCache;
    std::unordered_map<uint64_t, std::unique_ptr<Stellaria::Motion::RIFECoreMLFlowMaskRunner>> _rifeCoreMLFlowMaskRunnerCache;
    std::unordered_map<uint64_t, std::unique_ptr<Stellaria::Motion::RIFEMetal4BitRunner>> _rifeMetal4RunnerCache;
    std::unordered_map<uint64_t, std::unique_ptr<Stellaria::Motion::RIFESP4Runner>> _rifeSP4RunnerCache;
    std::unordered_map<uint64_t, std::unique_ptr<Stellaria::Motion::RIFEMPSGraphRunner>> _rifeRunnerCache;
}
@property(atomic, assign, readwrite, getter=isRunning) BOOL running;
@property(atomic, assign, readwrite, getter=isClientConnected) BOOL clientConnected;
@property(atomic, assign, readwrite) uint16_t port;
@property(atomic, assign) int listenSocket;
@property(atomic, assign) uint64_t receivedFrames;
@property(atomic, assign) uint64_t receivedBytes;
@property(atomic, assign) uint64_t processedFrames;
@property(atomic, assign) uint64_t textMessages;
@property(atomic, copy) NSString* lastMessage;
@property(atomic, copy) SMBrowserStreamBridgeProgress progress;
@property(strong) id<MTLDevice> device;
@property(strong) id<MTLCommandQueue> commandQueue;
@property(strong) id<MTLComputePipelineState> interpolatePipeline;
@property(strong) id<MTLComputePipelineState> rifePackPipeline;
@property(strong) id<MTLComputePipelineState> rifeUnpackPipeline;
@property(strong) id<MTLComputePipelineState> rifeCoreMLClearPipeline;
@property(strong) id<MTLComputePipelineState> rifeCoreMLPackPipeline;
@property(strong) id<MTLComputePipelineState> rifeCoreMLAccumulatePipeline;
@property(strong) id<MTLComputePipelineState> rifeCoreMLBlendPipeline;
@property(strong) CIContext* ciContext;
@property(strong) id<MTLTexture> previousTexture;
@property(strong) id<MTLTexture> outputTexture;
@property(assign) CVMetalTextureCacheRef textureCache;
@property(assign) VTDecompressionSessionRef h264Session;
@property(assign) CMVideoFormatDescriptionRef h264FormatDescription;
@property(assign) VTCompressionSessionRef outputEncodeSession;
@property(assign) CVPixelBufferPoolRef outputPixelBufferPool;
@property(assign) NSUInteger outputPixelBufferPoolWidth;
@property(assign) NSUInteger outputPixelBufferPoolHeight;
@property(assign) NSUInteger outputEncodeWidth;
@property(assign) NSUInteger outputEncodeHeight;
@property(assign) CMVideoCodecType outputEncodeCodecType;
@property(assign) double outputEncodeBitrateMbps;
@property(atomic, copy) NSString* outputEncodeCodecString;
@property(atomic, assign) uint64_t hardwareEncodedFrames;
@property(strong) SMEncodedVideoChunk* lastOutputVideoChunk;
@property(strong) NSMutableArray<SMProcessedOutputFrame*>* lastOutputFrames;
@property(assign) Stellaria::Motion::RIFEMPSGraphRunner* rifeRunner;
@property(strong) id<MTLBuffer> rifeInputBuffer;
@property(strong) id<MTLBuffer> rifeOutputBuffer;
@property(strong) id<MTLBuffer> rifeCoreMLInputBuffer;
@property(strong) id<MTLBuffer> rifeCoreMLReverseXBuffer;
@property(strong) id<MTLBuffer> rifeCoreMLFlowInputBuffer;
@property(strong) id<MTLBuffer> rifeCoreMLReverseFlowInputBuffer;
@property(strong) id<MTLBuffer> rifeCoreMLForwardOutputBuffer;
@property(strong) id<MTLBuffer> rifeCoreMLReverseOutputBuffer;
@property(strong) id<MTLBuffer> rifeCoreMLFlowMaskBuffer;
@property(strong) id<MTLTexture> multiTTextureA;
@property(strong) id<MTLTexture> multiTTextureB;
@property(strong) NSMutableArray* multiTTextures;
@property(assign) NSUInteger rifeModelWidth;
@property(assign) NSUInteger rifeModelHeight;
@property(atomic, assign) uint64_t rifeFrames;
@property(atomic, assign) BOOL auxiliaryRIFEPass;
@property(assign) CVPixelBufferRef previousPixelBuffer;
@property(atomic, copy) NSString* pendingPayloadKind;
@property(atomic, copy) NSString* pendingCodec;
@property(atomic, copy) NSString* pendingPayloadCodec;
@property(atomic, strong) NSData* pendingCodecDescription;
@property(atomic, copy) NSString* pendingReturnCodec;
@property(atomic, copy) NSString* pendingModelMode;
@property(atomic, copy) NSString* pendingPowerMode;
@property(atomic, copy) NSString* pendingPowerTier;
@property(atomic, copy) NSString* pendingChunkType;
@property(atomic, assign) double pendingTargetFPS;
@property(atomic, assign) double pendingInputPTS;
@property(atomic, assign) double pendingInputDuration;
@property(atomic, assign) uint32_t pendingInputWidth;
@property(atomic, assign) uint32_t pendingInputHeight;
@property(atomic, assign) double pendingFlowInputHeight;
@property(atomic, assign) double pendingGpuBudgetMs;
@property(atomic, assign) double pendingReturnBitrateMbps;
@property(atomic, assign) uint64_t pendingFrameId;
@property(atomic, assign) BOOL pendingForceReturnKeyframe;
@property(atomic, assign) CFTimeInterval lastAdaptiveChangeTime;
@property(atomic, assign) NSUInteger pendingPayloadBytes;
@property(atomic, assign) BOOL pendingNoCpuReadback;
@property(atomic, assign) BOOL pendingHEVCMotionHints;
@property(atomic, assign) BOOL pendingROIMotionBlocks;
@property(atomic, assign) BOOL pendingDynamicMultiFrame;
@property(atomic, copy) NSString* activePayloadCodec;
@property(atomic, assign) uint32_t activeInputWidth;
@property(atomic, assign) uint32_t activeInputHeight;
@property(atomic, assign) uint64_t hardwareDecodedFrames;
@property(atomic, assign) double lastGpuMs;
@property(atomic, assign) double lastDecodeMs;
@property(atomic, assign) double lastEncodeMs;
@property(atomic, assign) double lastPackMs;
@property(atomic, assign) double lastUnpackMs;
@property(atomic, assign) double lastNativeFrameMs;
@property(atomic, assign) NSUInteger coreMLContinuousFailureCount;
@property(atomic, assign) CFTimeInterval lastCoreMLContinuousFailureTime;
@property(atomic, copy) NSString* rifeBackendName;
@property(atomic, copy) NSString* rifeCoreMLDiagnostics;
@property(atomic, copy) NSString* pendingRIFEBackend;
@property(atomic, assign) CFTimeInterval lastSocketStatusSentAt;
@property(atomic, assign) CFTimeInterval nextOutputSendTime;
@property(atomic, assign) double estimatedSourceFPS;
@property(atomic, assign) double lastInputPTS;
@property(atomic, assign) double nextOutputContentPTS;
@property(atomic, assign) BOOL outputClockPrimed;
@property(strong) NSCondition* outputQueueCondition;
@property(strong) NSMutableArray<SMProcessedOutputFrame*>* outputSendQueue;
@property(strong) NSLock* webSocketSendLock;
@property(atomic, assign) BOOL outputSenderRunning;
@property(atomic, assign) BOOL outputSenderStop;
@property(atomic, assign) BOOL outputPlaybackPaused;
@property(atomic, assign) BOOL outputSenderPrimed;
@property(atomic, assign) int outputClient;
@property(atomic, assign) double outputQueueTargetFPS;
- (BOOL)ensureMetalReady;
- (void)resetVideoDecoder;
- (BOOL)isSceneCutBetweenPreviousBuffer:(CVPixelBufferRef)previous current:(CVPixelBufferRef)current;
- (NSData*)jpegDataFromTexture:(id<MTLTexture>)texture width:(NSUInteger)width height:(NSUInteger)height;
- (SMEncodedVideoChunk*)videoChunkFromTexture:(id<MTLTexture>)texture width:(NSUInteger)width height:(NSUInteger)height;
- (SMEncodedVideoChunk*)videoChunkFromTexture:(id<MTLTexture>)texture width:(NSUInteger)width height:(NSUInteger)height forceKeyFrame:(BOOL)forceKeyFrame;
- (NSData*)processJPEGFrameWithMetal:(NSData*)jpegData;
- (NSData*)processPixelBufferWithMetal:(CVPixelBufferRef)currentBuffer;
- (BOOL)processTexturesWithRIFEPrevious:(id<MTLTexture>)previous current:(id<MTLTexture>)current output:(id<MTLTexture>)output width:(NSUInteger)width height:(NSUInteger)height;
- (BOOL)processTexturesWithRIFEMetal4Previous:(id<MTLTexture>)previous current:(id<MTLTexture>)current output:(id<MTLTexture>)output width:(NSUInteger)width height:(NSUInteger)height;
- (BOOL)processTexturesWithRIFESP4Previous:(id<MTLTexture>)previous current:(id<MTLTexture>)current output:(id<MTLTexture>)output width:(NSUInteger)width height:(NSUInteger)height;
- (BOOL)processTexturesWithRIFESP4Previous:(id<MTLTexture>)previous current:(id<MTLTexture>)current outputs:(NSArray<id<MTLTexture>>*)outputs tValues:(const float*)tValues count:(NSUInteger)count width:(NSUInteger)width height:(NSUInteger)height;
- (BOOL)processTexturesWithRIFECoreMLContinuousPrevious:(id<MTLTexture>)previous current:(id<MTLTexture>)current output:(id<MTLTexture>)output width:(NSUInteger)width height:(NSUInteger)height modelWidth:(NSUInteger)modelWidth modelHeight:(NSUInteger)modelHeight elapsedMs:(double*)elapsedMsOut;
- (BOOL)processTexturesWithRIFECoreMLBlocksPrevious:(id<MTLTexture>)previous current:(id<MTLTexture>)current output:(id<MTLTexture>)output width:(NSUInteger)width height:(NSUInteger)height modelWidth:(NSUInteger)modelWidth modelHeight:(NSUInteger)modelHeight elapsedMs:(double*)elapsedMsOut;
- (std::array<std::unique_ptr<Stellaria::Motion::RIFECoreMLBlockRunner>, 3>*)coreMLBlockRunnersForModelWidth:(NSUInteger)modelWidth height:(NSUInteger)modelHeight;
- (Stellaria::Motion::RIFECoreMLFlowMaskRunner*)coreMLFlowMaskRunnerForModelWidth:(NSUInteger)modelWidth height:(NSUInteger)modelHeight;
- (Stellaria::Motion::RIFECoreMLRunner*)coreMLRunnerForModelWidth:(NSUInteger)modelWidth height:(NSUInteger)modelHeight;
- (Stellaria::Motion::RIFEMetal4BitRunner*)metal4RunnerForModelWidth:(NSUInteger)modelWidth height:(NSUInteger)modelHeight;
- (Stellaria::Motion::RIFESP4Runner*)sp4RunnerForModelWidth:(NSUInteger)modelWidth height:(NSUInteger)modelHeight;
- (Stellaria::Motion::RIFEMPSGraphRunner*)runnerForModelWidth:(NSUInteger)modelWidth height:(NSUInteger)modelHeight;
- (void)updatePendingFrameMeta:(NSData*)payload;
- (BOOL)updatePendingFrameMetaFromBinaryFrame:(NSData*)frame payload:(NSData**)payloadOut;
- (void)updateInputClock;
- (double)outputPrerollSecondsForTargetFPS:(double)fps;
- (double)outputMaxQueueSecondsForTargetFPS:(double)fps;
- (double)outputQueueSecondsLocked;
- (NSArray<SMProcessedOutputFrame*>*)stableOutputFramesFromFrames:(NSArray<SMProcessedOutputFrame*>*)frames targetFPS:(double)targetFPS;
- (void)enqueueOutputFrames:(NSArray<SMProcessedOutputFrame*>*)frames targetFPS:(double)targetFPS;
- (void)trimOutputQueueForInputBackpressure;
- (void)resetOutputQueueAndClock;
- (void)startOutputSenderForClient:(int)client;
- (void)stopOutputSender;
- (void)outputSenderLoop;
- (BOOL)sendOutputFrame:(SMProcessedOutputFrame*)frame client:(int)client;
- (NSData*)processH264AnnexBChunk:(NSData*)chunkData;
- (NSData*)processHEVCAnnexBChunk:(NSData*)chunkData;
@end

@implementation SMBrowserStreamBridge

- (instancetype)init {
    self = [super init];
    if (self) {
        _listenSocket = -1;
        _lastMessage = @"idle";
        _outputQueueCondition = [NSCondition new];
        _outputSendQueue = [NSMutableArray array];
        _webSocketSendLock = [NSLock new];
        _outputClient = -1;
        _outputQueueTargetFPS = 60.0;
        _pendingReturnBitrateMbps = 60.0;
        Stellaria::Motion::RealtimeVFIConfig config;
        config.inputSource = Stellaria::Motion::RealtimeInputSource::BrowserStream;
        config.backend = Stellaria::Motion::RealtimeRIFEBackend::MPSGraphFP16;
        config.powerTier = Stellaria::Motion::RealtimePowerTier::Balanced;
        config.targetFPS = 60.0;
        config.flowInputHeight = 540;
        config.prerollSeconds = 0.12;
        config.maxVisibleFrameGapMs = 16.67;
        config.maxPipelineLatencyMs = 16.67;
        _realtimeSession = std::make_unique<Stellaria::Motion::RealtimeVFISession>(config);
    }
    return self;
}

- (void)dealloc {
    [self stop];
    [self resetVideoDecoder];
    _rifeRunner = nullptr;
    _rifeCoreMLBlockRunnerCache.clear();
    _rifeCoreMLRunnerCache.clear();
    _rifeCoreMLFlowMaskRunnerCache.clear();
    _rifeMetal4RunnerCache.clear();
    _rifeRunnerCache.clear();
    if (_textureCache != nullptr) {
        CFRelease(_textureCache);
        _textureCache = nullptr;
    }
}

- (BOOL)startWithPort:(uint16_t)port progress:(SMBrowserStreamBridgeProgress)progress {
    if (self.running) {
        return YES;
    }

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        self.lastMessage = @"socket create failed";
        return NO;
    }

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    sockaddr_in addr {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 ||
        listen(fd, 2) != 0) {
        self.lastMessage = [NSString stringWithFormat:@"bind/listen failed: %d", errno];
        close(fd);
        return NO;
    }

    self.listenSocket = fd;
    self.port = port;
    self.progress = progress;
    self.running = YES;
    self.clientConnected = NO;
    self.receivedFrames = 0;
    self.receivedBytes = 0;
    self.processedFrames = 0;
    self.textMessages = 0;
    [self ensureMetalReady];
    self.lastMessage = @"listening";
    [NSThread detachNewThreadSelector:@selector(serverLoop) toTarget:self withObject:nil];
    [self emit];
    return YES;
}

- (void)stop {
    self.running = NO;
    self.clientConnected = NO;
    [self stopOutputSender];
    int fd = self.listenSocket;
    self.listenSocket = -1;
    if (fd >= 0) {
        shutdown(fd, SHUT_RDWR);
        close(fd);
    }
    [self resetVideoDecoder];
    self.previousTexture = nil;
    self.lastMessage = @"stopped";
    [self emit];
}

- (NSDictionary<NSString*, id>*)snapshot {
    [self.outputQueueCondition lock];
    const NSUInteger queuedFrames = self.outputSendQueue.count;
    const double queuedSeconds = [self outputQueueSecondsLocked];
    const BOOL senderPrimed = self.outputSenderPrimed;
    const BOOL playbackPaused = self.outputPlaybackPaused;
    [self.outputQueueCondition unlock];
    NSString* message = self.lastMessage ?: @"";
    if (_realtimeSession) {
        _realtimeSession->NoteQueueDepth(static_cast<uint32_t>(queuedFrames));
        _realtimeSession->NotePipelineTiming(self.lastGpuMs, self.lastEncodeMs);
        _realtimeSession->NoteBrowserStreamState(message.UTF8String ?: "");
    }
    const Stellaria::Motion::RealtimeVFIDiagnostics realtime =
        _realtimeSession ? _realtimeSession->Diagnostics() : Stellaria::Motion::RealtimeVFIDiagnostics{};
    return @{
        @"running": @(self.running),
        @"connected": @(self.clientConnected),
        @"port": @(self.port),
        @"receivedFrames": @(self.receivedFrames),
        @"receivedBytes": @(self.receivedBytes),
        @"processedFrames": @(self.processedFrames),
        @"hardwareDecodedFrames": @(self.hardwareDecodedFrames),
        @"hardwareEncodedFrames": @(self.hardwareEncodedFrames),
        @"outputQueuedFrames": @(queuedFrames),
        @"outputQueuedSeconds": @(queuedSeconds),
        @"outputSenderPrimed": @(senderPrimed),
        @"outputPlaybackPaused": @(playbackPaused),
        @"payloadKind": self.pendingPayloadKind ?: @"",
        @"codec": self.pendingCodec ?: @"",
        @"payloadCodec": self.pendingPayloadCodec ?: self.activePayloadCodec ?: @"",
        @"outputCodec": self.outputEncodeCodecString ?: @"",
        @"modelMode": self.pendingModelMode ?: @"",
        @"powerMode": self.pendingPowerMode ?: @"",
        @"powerTier": self.pendingPowerTier ?: @"",
        @"chunkType": self.pendingChunkType ?: @"",
        @"rifeFrames": @(self.rifeFrames),
        @"targetFPS": @(self.pendingTargetFPS),
        @"flowInputHeight": @(self.pendingFlowInputHeight),
        @"gpuBudgetMs": @(self.pendingGpuBudgetMs),
        @"returnBitrateMbps": @(self.pendingReturnBitrateMbps),
        @"rifeModelWidth": @(self.rifeModelWidth),
        @"rifeModelHeight": @(self.rifeModelHeight),
        @"payloadBytes": @(self.pendingPayloadBytes),
        @"noCpuReadback": @(self.pendingNoCpuReadback),
        @"hevcMotionHints": @(self.pendingHEVCMotionHints),
        @"roiMotionBlocks": @(self.pendingROIMotionBlocks),
        @"dynamicMultiFrame": @(self.pendingDynamicMultiFrame),
        @"gpuMs": @(self.lastGpuMs),
        @"decodeMs": @(self.lastDecodeMs),
        @"encodeMs": @(self.lastEncodeMs),
        @"packMs": @(self.lastPackMs),
        @"unpackMs": @(self.lastUnpackMs),
        @"nativeFrameMs": @(self.lastNativeFrameMs),
        @"realtimeOutputFPS": @(realtime.outputFPS),
        @"realtimeMaxGapMs": @(realtime.maxFrameGapMs),
        @"realtimeAverageGapMs": @(realtime.averageFrameGapMs),
        @"realtimeQueueSeconds": @(realtime.queueSeconds),
        @"realtimeCadenceStable": @(realtime.cadenceStable),
        @"realtimeBrowserStreamState": [NSString stringWithUTF8String:realtime.browserStreamState.c_str()] ?: @"",
        @"coreMLContinuousFailures": @(self.coreMLContinuousFailureCount),
        @"rifeBackend": self.rifeBackendName ?: @"",
        @"rifeCoreML": self.rifeCoreMLDiagnostics ?: @"",
        @"textMessages": @(self.textMessages),
        @"message": message
    };
}

- (BOOL)ensureMetalReady {
    if (self.interpolatePipeline != nil && self.rifePackPipeline != nil && self.rifeUnpackPipeline != nil && self.commandQueue != nil && self.ciContext != nil) {
        return YES;
    }
    self.device = MTLCreateSystemDefaultDevice();
    self.commandQueue = self.device != nil ? [self.device newCommandQueue] : nil;
    self.ciContext = self.device != nil ? [CIContext contextWithMTLDevice:self.device] : nil;
    if (self.device != nil && self.textureCache == nullptr) {
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, self.device, nullptr, &_textureCache);
    }
    NSError* error = nil;
    NSURL* libraryURL = [[NSBundle mainBundle] URLForResource:@"MotionKernels" withExtension:@"metallib"];
    id<MTLLibrary> library = libraryURL != nil ? [self.device newLibraryWithURL:libraryURL error:&error] : nil;
    id<MTLFunction> function = [library newFunctionWithName:@"fused_bgra_interpolate_lanczos_present"];
    self.interpolatePipeline = function != nil ? [self.device newComputePipelineStateWithFunction:function error:&error] : nil;
    id<MTLFunction> packFunction = [library newFunctionWithName:@"pack_bgra_pair_to_rife_input"];
    id<MTLFunction> unpackFunction = [library newFunctionWithName:@"unpack_rife_output_to_bgra"];
    self.rifePackPipeline = packFunction != nil ? [self.device newComputePipelineStateWithFunction:packFunction error:&error] : nil;
    self.rifeUnpackPipeline = unpackFunction != nil ? [self.device newComputePipelineStateWithFunction:unpackFunction error:&error] : nil;
    id<MTLFunction> clearCoreMLFunction = [library newFunctionWithName:@"clear_rife_coreml_flow_mask"];
    id<MTLFunction> packCoreMLFunction = [library newFunctionWithName:@"pack_rife_coreml_block_input"];
    id<MTLFunction> accumulateCoreMLFunction = [library newFunctionWithName:@"accumulate_rife_coreml_block_output"];
    id<MTLFunction> blendCoreMLFunction = [library newFunctionWithName:@"blend_rife_coreml_flow_to_bgra"];
    self.rifeCoreMLClearPipeline = clearCoreMLFunction != nil ? [self.device newComputePipelineStateWithFunction:clearCoreMLFunction error:&error] : nil;
    self.rifeCoreMLPackPipeline = packCoreMLFunction != nil ? [self.device newComputePipelineStateWithFunction:packCoreMLFunction error:&error] : nil;
    self.rifeCoreMLAccumulatePipeline = accumulateCoreMLFunction != nil ? [self.device newComputePipelineStateWithFunction:accumulateCoreMLFunction error:&error] : nil;
    self.rifeCoreMLBlendPipeline = blendCoreMLFunction != nil ? [self.device newComputePipelineStateWithFunction:blendCoreMLFunction error:&error] : nil;
    if (self.device == nil || self.commandQueue == nil || self.ciContext == nil || self.interpolatePipeline == nil || self.rifePackPipeline == nil || self.rifeUnpackPipeline == nil || self.textureCache == nullptr) {
        self.lastMessage = [NSString stringWithFormat:@"Metal bridge unavailable: %@", error.localizedDescription ?: @"kernel missing"];
        return NO;
    }
    return YES;
}

- (void)resetVideoDecoder {
    if (_h264Session != nullptr) {
        VTDecompressionSessionInvalidate(_h264Session);
        CFRelease(_h264Session);
        _h264Session = nullptr;
    }
    if (_h264FormatDescription != nullptr) {
        CFRelease(_h264FormatDescription);
        _h264FormatDescription = nullptr;
    }
    if (_outputEncodeSession != nullptr) {
        VTCompressionSessionInvalidate(_outputEncodeSession);
        CFRelease(_outputEncodeSession);
        _outputEncodeSession = nullptr;
    }
    if (_outputPixelBufferPool != nullptr) {
        CVPixelBufferPoolRelease(_outputPixelBufferPool);
        _outputPixelBufferPool = nullptr;
    }
    self.outputPixelBufferPoolWidth = 0;
    self.outputPixelBufferPoolHeight = 0;
    self.outputEncodeWidth = 0;
    self.outputEncodeHeight = 0;
    self.outputEncodeCodecType = 0;
    self.outputEncodeCodecString = nil;
    self.hardwareEncodedFrames = 0;
    [self resetOutputQueueAndClock];
    self.estimatedSourceFPS = 0.0;
    self.lastInputPTS = 0.0;
    self.nextOutputContentPTS = 0.0;
    self.outputClockPrimed = NO;
    self.activeInputWidth = 0;
    self.activeInputHeight = 0;
    if (_previousPixelBuffer != nullptr) {
        CVPixelBufferRelease(_previousPixelBuffer);
        _previousPixelBuffer = nullptr;
    }
}

- (BOOL)isSceneCutBetweenPreviousBuffer:(CVPixelBufferRef)previous current:(CVPixelBufferRef)current {
    if (previous == nullptr || current == nullptr ||
        CVPixelBufferGetWidth(previous) != CVPixelBufferGetWidth(current) ||
        CVPixelBufferGetHeight(previous) != CVPixelBufferGetHeight(current)) {
        return YES;
    }
    const size_t width = CVPixelBufferGetWidth(current);
    const size_t height = CVPixelBufferGetHeight(current);
    if (width < 16 || height < 16) {
        return NO;
    }
    if (CVPixelBufferLockBaseAddress(previous, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return NO;
    }
    if (CVPixelBufferLockBaseAddress(current, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(previous, kCVPixelBufferLock_ReadOnly);
        return NO;
    }

    auto sampleLuma = ^uint8_t(CVPixelBufferRef buffer, size_t x, size_t y) {
        const size_t planeCount = CVPixelBufferGetPlaneCount(buffer);
        if (planeCount > 0) {
            const size_t planeWidth = CVPixelBufferGetWidthOfPlane(buffer, 0);
            const size_t planeHeight = CVPixelBufferGetHeightOfPlane(buffer, 0);
            const uint8_t* base = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(buffer, 0));
            const size_t rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
            if (base == nullptr || planeWidth == 0 || planeHeight == 0) {
                return static_cast<uint8_t>(0);
            }
            const size_t sx = MIN(planeWidth - 1, x * planeWidth / MAX(static_cast<size_t>(1), width));
            const size_t sy = MIN(planeHeight - 1, y * planeHeight / MAX(static_cast<size_t>(1), height));
            return base[sy * rowBytes + sx];
        }
        const uint8_t* base = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(buffer));
        const size_t rowBytes = CVPixelBufferGetBytesPerRow(buffer);
        if (base == nullptr || rowBytes == 0) {
            return static_cast<uint8_t>(0);
        }
        const uint8_t* px = base + MIN(height - 1, y) * rowBytes + MIN(width - 1, x) * 4;
        return static_cast<uint8_t>((static_cast<uint16_t>(px[0]) + static_cast<uint16_t>(px[1]) + static_cast<uint16_t>(px[2])) / 3);
    };

    double totalDiff = 0.0;
    NSUInteger changed = 0;
    NSUInteger samples = 0;
    constexpr size_t kGridX = 12;
    constexpr size_t kGridY = 8;
    for (size_t gy = 0; gy < kGridY; ++gy) {
        const size_t y = (gy + 1) * height / (kGridY + 1);
        for (size_t gx = 0; gx < kGridX; ++gx) {
            const size_t x = (gx + 1) * width / (kGridX + 1);
            const int diff = abs(static_cast<int>(sampleLuma(previous, x, y)) - static_cast<int>(sampleLuma(current, x, y)));
            totalDiff += diff;
            changed += diff > 42 ? 1 : 0;
            samples += 1;
        }
    }

    CVPixelBufferUnlockBaseAddress(current, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(previous, kCVPixelBufferLock_ReadOnly);
    if (samples == 0) {
        return NO;
    }
    const double avgDiff = totalDiff / static_cast<double>(samples);
    const double changedRatio = static_cast<double>(changed) / static_cast<double>(samples);
    return (avgDiff > 34.0 && changedRatio > 0.34) || avgDiff > 52.0;
}

- (id<MTLTexture>)textureFromPixelBuffer:(CVPixelBufferRef)buffer textureRef:(CVMetalTextureRef*)textureRefOut {
    if (![self ensureMetalReady] || buffer == nullptr || textureRefOut == nullptr) {
        return nil;
    }
    *textureRefOut = nullptr;
    const size_t width = CVPixelBufferGetWidth(buffer);
    const size_t height = CVPixelBufferGetHeight(buffer);
    CVMetalTextureRef textureRef = nullptr;
    const CVReturn result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                      self.textureCache,
                                                                      buffer,
                                                                      nullptr,
                                                                      MTLPixelFormatBGRA8Unorm,
                                                                      width,
                                                                      height,
                                                                      0,
                                                                      &textureRef);
    if (result != kCVReturnSuccess || textureRef == nullptr) {
        return nil;
    }
    id<MTLTexture> texture = CVMetalTextureGetTexture(textureRef);
    if (texture == nil) {
        CFRelease(textureRef);
        return nil;
    }
    *textureRefOut = textureRef;
    return texture;
}

- (id<MTLTexture>)ensureOutputTextureWithWidth:(NSUInteger)width height:(NSUInteger)height {
    if (self.outputTexture != nil && self.outputTexture.width == width && self.outputTexture.height == height) {
        return self.outputTexture;
    }
    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:width
                                                                                         height:height
                                                                                      mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    descriptor.storageMode = MTLStorageModePrivate;
    self.outputTexture = [self.device newTextureWithDescriptor:descriptor];
    return self.outputTexture;
}

- (id<MTLTexture>)ensureMultiTTextureSlot:(NSUInteger)slot width:(NSUInteger)width height:(NSUInteger)height {
    if (self.multiTTextures == nil) {
        self.multiTTextures = [NSMutableArray array];
        if (self.multiTTextureA != nil) {
            [self.multiTTextures addObject:self.multiTTextureA];
        }
        if (self.multiTTextureB != nil) {
            [self.multiTTextures addObject:self.multiTTextureB];
        }
    }
    while (self.multiTTextures.count <= slot) {
        [self.multiTTextures addObject:(id)[NSNull null]];
    }
    id currentObject = self.multiTTextures[slot];
    id<MTLTexture> current = [currentObject conformsToProtocol:@protocol(MTLTexture)] ? currentObject : nil;
    if (current != nil && current.width == width && current.height == height) {
        return current;
    }
    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:width
                                                                                         height:height
                                                                                      mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    descriptor.storageMode = MTLStorageModePrivate;
    id<MTLTexture> texture = [self.device newTextureWithDescriptor:descriptor];
    self.multiTTextures[slot] = texture ?: (id)[NSNull null];
    if (slot == 0) {
        self.multiTTextureA = texture;
    } else if (slot == 1) {
        self.multiTTextureB = texture;
    }
    return texture;
}

- (BOOL)copyTextureToOutput:(id<MTLTexture>)texture width:(NSUInteger)width height:(NSUInteger)height {
    id<MTLTexture> output = [self ensureOutputTextureWithWidth:width height:height];
    if (texture == nil || output == nil) {
        return NO;
    }
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    [blit copyFromTexture:texture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(width, height, 1)
                toTexture:output
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    return commandBuffer.status == MTLCommandBufferStatusCompleted;
}

- (BOOL)ensureOutputEncodeSessionWithWidth:(NSUInteger)width height:(NSUInteger)height {
    const BOOL wantsHEVC = [[self.pendingReturnCodec lowercaseString] isEqualToString:@"hevc"] ||
                           [[self.pendingReturnCodec lowercaseString] isEqualToString:@"h265"];
    const CMVideoCodecType desiredCodec = wantsHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264;
    const double requestedBitrateMbps = MAX(12.0, MIN(120.0, self.pendingReturnBitrateMbps > 0.0 ? self.pendingReturnBitrateMbps : 60.0));
    if (self.outputEncodeSession != nullptr &&
        self.outputEncodeWidth == width &&
        self.outputEncodeHeight == height &&
        self.outputEncodeCodecType == desiredCodec &&
        fabs(self.outputEncodeBitrateMbps - requestedBitrateMbps) < 0.5) {
        return YES;
    }
    if (_outputEncodeSession != nullptr) {
        VTCompressionSessionInvalidate(_outputEncodeSession);
        CFRelease(_outputEncodeSession);
        _outputEncodeSession = nullptr;
    }
    self.outputEncodeWidth = 0;
    self.outputEncodeHeight = 0;
    self.outputEncodeCodecType = 0;
    self.outputEncodeBitrateMbps = 0.0;
    self.outputEncodeCodecString = nil;
    self.hardwareEncodedFrames = 0;

    CMVideoCodecType codecs[2] = {desiredCodec, desiredCodec == kCMVideoCodecType_HEVC ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC};
    OSStatus status = -1;
    CMVideoCodecType selectedCodec = 0;
    for (CMVideoCodecType codec : codecs) {
        if (codec == kCMVideoCodecType_HEVC && !wantsHEVC) {
            continue;
        }
        if (_outputEncodeSession != nullptr) {
            VTCompressionSessionInvalidate(_outputEncodeSession);
            CFRelease(_outputEncodeSession);
            _outputEncodeSession = nullptr;
        }
        status = VTCompressionSessionCreate(kCFAllocatorDefault,
                                            static_cast<int32_t>(width),
                                            static_cast<int32_t>(height),
                                            codec,
                                            nullptr,
                                            nullptr,
                                            nullptr,
                                            SMVTEncodeOutput,
                                            nullptr,
                                            &_outputEncodeSession);
        if (status == noErr && _outputEncodeSession != nullptr) {
            selectedCodec = codec;
            break;
        }
    }
    if (status != noErr || _outputEncodeSession == nullptr) {
        self.lastMessage = [NSString stringWithFormat:@"VideoToolbox output encode session failed: %d", static_cast<int>(status)];
        return NO;
    }
    VTSessionSetProperty(_outputEncodeSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(_outputEncodeSession, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    const int32_t zeroDelay = 0;
    CFNumberRef zeroDelayNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &zeroDelay);
    if (zeroDelayNumber != nullptr) {
        VTSessionSetProperty(_outputEncodeSession, kVTCompressionPropertyKey_MaxFrameDelayCount, zeroDelayNumber);
        CFRelease(zeroDelayNumber);
    }
    const int32_t expectedFPS = static_cast<int32_t>(MAX(24.0, MIN(240.0, self.pendingTargetFPS > 0.0 ? self.pendingTargetFPS : 60.0)));
    CFNumberRef expectedFPSNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &expectedFPS);
    if (expectedFPSNumber != nullptr) {
        VTSessionSetProperty(_outputEncodeSession, kVTCompressionPropertyKey_ExpectedFrameRate, expectedFPSNumber);
        CFRelease(expectedFPSNumber);
    }
    if (selectedCodec == kCMVideoCodecType_HEVC) {
        VTSessionSetProperty(_outputEncodeSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel);
        self.outputEncodeCodecString = @"hvc1.1.6.L123.B0";
    } else {
        VTSessionSetProperty(_outputEncodeSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel);
        self.outputEncodeCodecString = @"avc1.64002a";
    }
    const int32_t bitrate = static_cast<int32_t>(requestedBitrateMbps * 1000000.0);
    CFNumberRef bitrateNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &bitrate);
    if (bitrateNumber != nullptr) {
        VTSessionSetProperty(_outputEncodeSession, kVTCompressionPropertyKey_AverageBitRate, bitrateNumber);
        CFRelease(bitrateNumber);
    }
    float quality = 0.92f;
    CFNumberRef qualityNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat32Type, &quality);
    if (qualityNumber != nullptr) {
        VTSessionSetProperty(_outputEncodeSession, kVTCompressionPropertyKey_Quality, qualityNumber);
        CFRelease(qualityNumber);
    }
    const int32_t keyframeInterval = expectedFPS;
    CFNumberRef keyframeIntervalNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &keyframeInterval);
    if (keyframeIntervalNumber != nullptr) {
        VTSessionSetProperty(_outputEncodeSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, keyframeIntervalNumber);
        CFRelease(keyframeIntervalNumber);
    }
    VTCompressionSessionPrepareToEncodeFrames(_outputEncodeSession);
    self.outputEncodeWidth = width;
    self.outputEncodeHeight = height;
    self.outputEncodeCodecType = selectedCodec;
    self.outputEncodeBitrateMbps = requestedBitrateMbps;
    return YES;
}

- (CVPixelBufferRef)newPixelBufferFromTexture:(id<MTLTexture>)texture width:(NSUInteger)width height:(NSUInteger)height {
    if (texture == nil || self.textureCache == nullptr) {
        return nullptr;
    }
    if (self.outputPixelBufferPool == nullptr ||
        self.outputPixelBufferPoolWidth != width ||
        self.outputPixelBufferPoolHeight != height) {
        if (_outputPixelBufferPool != nullptr) {
            CVPixelBufferPoolRelease(_outputPixelBufferPool);
            _outputPixelBufferPool = nullptr;
        }
        NSDictionary* attrs = @{
            (__bridge NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (__bridge NSString*)kCVPixelBufferWidthKey: @(width),
            (__bridge NSString*)kCVPixelBufferHeightKey: @(height),
            (__bridge NSString*)kCVPixelBufferMetalCompatibilityKey: @YES,
            (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        NSDictionary* poolAttrs = @{
            (__bridge NSString*)kCVPixelBufferPoolMinimumBufferCountKey: @3
        };
        CVReturn poolResult = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                                      (__bridge CFDictionaryRef)poolAttrs,
                                                      (__bridge CFDictionaryRef)attrs,
                                                      &_outputPixelBufferPool);
        if (poolResult != kCVReturnSuccess || _outputPixelBufferPool == nullptr) {
            return nullptr;
        }
        self.outputPixelBufferPoolWidth = width;
        self.outputPixelBufferPoolHeight = height;
    }
    CVPixelBufferRef pixelBuffer = nullptr;
    CVReturn result = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                         self.outputPixelBufferPool,
                                                         &pixelBuffer);
    if (result != kCVReturnSuccess || pixelBuffer == nullptr) {
        return nullptr;
    }

    CVMetalTextureRef textureRef = nullptr;
    id<MTLTexture> target = [self textureFromPixelBuffer:pixelBuffer textureRef:&textureRef];
    if (target == nil) {
        if (textureRef != nullptr) {
            CFRelease(textureRef);
        }
        CVPixelBufferRelease(pixelBuffer);
        return nullptr;
    }

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    [blit copyFromTexture:texture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(width, height, 1)
                toTexture:target
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    if (textureRef != nullptr) {
        CFRelease(textureRef);
    }
    if (commandBuffer.status != MTLCommandBufferStatusCompleted) {
        CVPixelBufferRelease(pixelBuffer);
        return nullptr;
    }
    return pixelBuffer;
}

- (std::array<std::unique_ptr<Stellaria::Motion::RIFECoreMLBlockRunner>, 3>*)coreMLBlockRunnersForModelWidth:(NSUInteger)modelWidth height:(NSUInteger)modelHeight {
    const uint64_t key = (static_cast<uint64_t>(modelWidth) << 32U) | static_cast<uint64_t>(modelHeight);
    auto found = _rifeCoreMLBlockRunnerCache.find(key);
    if (found != _rifeCoreMLBlockRunnerCache.end()) {
        for (const auto& runner : found->second) {
            if (!runner || !runner->IsReady()) {
                return nullptr;
            }
        }
        return &found->second;
    }

    std::array<std::unique_ptr<Stellaria::Motion::RIFECoreMLBlockRunner>, 3> runners;
    for (int i = 0; i < 3; ++i) {
        runners[i] = std::make_unique<Stellaria::Motion::RIFECoreMLBlockRunner>();
        const std::string path = SMRIFECoreMLBlockModelPath(i, static_cast<uint32_t>(modelWidth), static_cast<uint32_t>(modelHeight));
        runners[i]->Load(path, static_cast<uint32_t>(modelWidth), static_cast<uint32_t>(modelHeight));
        if (!runners[i]->IsReady()) {
            self.rifeCoreMLDiagnostics = [NSString stringWithFormat:@"block%d: %s", i, runners[i]->Diagnostics().c_str()];
        }
    }
    auto inserted = _rifeCoreMLBlockRunnerCache.emplace(key, std::move(runners));
    if (_rifeCoreMLBlockRunnerCache.size() > 3) {
        for (auto it = _rifeCoreMLBlockRunnerCache.begin(); it != _rifeCoreMLBlockRunnerCache.end(); ++it) {
            if (it->first != key) {
                _rifeCoreMLBlockRunnerCache.erase(it);
                break;
            }
        }
    }
    for (const auto& runner : inserted.first->second) {
        if (!runner || !runner->IsReady()) {
            return nullptr;
        }
    }
    self.rifeCoreMLDiagnostics = [NSString stringWithFormat:@"CoreML blocks ready · %lux%lu",
                                                            static_cast<unsigned long>(modelWidth),
                                                            static_cast<unsigned long>(modelHeight)];
    return &inserted.first->second;
}

- (BOOL)processTexturesWithRIFECoreMLBlocksPrevious:(id<MTLTexture>)previous current:(id<MTLTexture>)current output:(id<MTLTexture>)output width:(NSUInteger)width height:(NSUInteger)height modelWidth:(NSUInteger)modelWidth modelHeight:(NSUInteger)modelHeight elapsedMs:(double*)elapsedMsOut {
    if (previous == nil || current == nil || output == nil ||
        self.rifeCoreMLClearPipeline == nil ||
        self.rifeCoreMLPackPipeline == nil ||
        self.rifeCoreMLAccumulatePipeline == nil ||
        self.rifeCoreMLBlendPipeline == nil) {
        return NO;
    }
    auto* runners = [self coreMLBlockRunnersForModelWidth:modelWidth height:modelHeight];
    if (runners == nullptr) {
        return NO;
    }

    const NSUInteger pixels = modelWidth * modelHeight;
    const NSUInteger xBytes = pixels * 7 * sizeof(float);
    const NSUInteger flowBytes = pixels * 4 * sizeof(float);
    const NSUInteger blockOutBytes = pixels * 5 * sizeof(float);
    if (self.rifeCoreMLInputBuffer == nil || self.rifeCoreMLInputBuffer.length < xBytes) {
        self.rifeCoreMLInputBuffer = [self.device newBufferWithLength:xBytes options:MTLResourceStorageModeShared];
    }
    if (self.rifeCoreMLReverseXBuffer == nil || self.rifeCoreMLReverseXBuffer.length < xBytes) {
        self.rifeCoreMLReverseXBuffer = [self.device newBufferWithLength:xBytes options:MTLResourceStorageModeShared];
    }
    if (self.rifeCoreMLFlowInputBuffer == nil || self.rifeCoreMLFlowInputBuffer.length < flowBytes) {
        self.rifeCoreMLFlowInputBuffer = [self.device newBufferWithLength:flowBytes options:MTLResourceStorageModeShared];
    }
    if (self.rifeCoreMLReverseFlowInputBuffer == nil || self.rifeCoreMLReverseFlowInputBuffer.length < flowBytes) {
        self.rifeCoreMLReverseFlowInputBuffer = [self.device newBufferWithLength:flowBytes options:MTLResourceStorageModeShared];
    }
    if (self.rifeCoreMLForwardOutputBuffer == nil || self.rifeCoreMLForwardOutputBuffer.length < blockOutBytes) {
        self.rifeCoreMLForwardOutputBuffer = [self.device newBufferWithLength:blockOutBytes options:MTLResourceStorageModeShared];
    }
    if (self.rifeCoreMLReverseOutputBuffer == nil || self.rifeCoreMLReverseOutputBuffer.length < blockOutBytes) {
        self.rifeCoreMLReverseOutputBuffer = [self.device newBufferWithLength:blockOutBytes options:MTLResourceStorageModeShared];
    }
    if (self.rifeCoreMLFlowMaskBuffer == nil || self.rifeCoreMLFlowMaskBuffer.length < blockOutBytes) {
        self.rifeCoreMLFlowMaskBuffer = [self.device newBufferWithLength:blockOutBytes options:MTLResourceStorageModeShared];
    }
    if (self.rifeCoreMLInputBuffer == nil || self.rifeCoreMLReverseXBuffer == nil ||
        self.rifeCoreMLFlowInputBuffer == nil || self.rifeCoreMLReverseFlowInputBuffer == nil ||
        self.rifeCoreMLForwardOutputBuffer == nil || self.rifeCoreMLReverseOutputBuffer == nil ||
        self.rifeCoreMLFlowMaskBuffer == nil) {
        self.lastMessage = @"CoreML block buffer allocation failed";
        return NO;
    }

    const CFTimeInterval start = CACurrentMediaTime();
    SMRIFECoreMLBlockParams params{
        .width = static_cast<uint32_t>(width),
        .height = static_cast<uint32_t>(height),
        .modelWidth = static_cast<uint32_t>(modelWidth),
        .modelHeight = static_cast<uint32_t>(modelHeight),
        .reverse = 0,
    };
    auto dispatchSize = MTLSizeMake(modelWidth, modelHeight, 1);

    id<MTLCommandBuffer> clearCommand = [self.commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> clear = [clearCommand computeCommandEncoder];
    [clear setComputePipelineState:self.rifeCoreMLClearPipeline];
    [clear setBuffer:self.rifeCoreMLFlowMaskBuffer offset:0 atIndex:0];
    [clear setBytes:&params length:sizeof(params) atIndex:1];
    NSUInteger clearWide = self.rifeCoreMLClearPipeline.threadExecutionWidth;
    NSUInteger clearHigh = MAX(1, self.rifeCoreMLClearPipeline.maxTotalThreadsPerThreadgroup / clearWide);
    [clear dispatchThreads:dispatchSize threadsPerThreadgroup:MTLSizeMake(clearWide, clearHigh, 1)];
    [clear endEncoding];
    [clearCommand commit];
    [clearCommand waitUntilCompleted];
    if (clearCommand.status != MTLCommandBufferStatusCompleted) {
        self.lastMessage = @"CoreML flow clear failed";
        return NO;
    }

    for (int block = 0; block < 3; ++block) {
        id<MTLCommandBuffer> packCommand = [self.commandQueue commandBuffer];
        id<MTLComputeCommandEncoder> pack = [packCommand computeCommandEncoder];
        [pack setComputePipelineState:self.rifeCoreMLPackPipeline];
        [pack setTexture:previous atIndex:0];
        [pack setTexture:current atIndex:1];
        params.reverse = 0;
        [pack setBuffer:self.rifeCoreMLFlowMaskBuffer offset:0 atIndex:0];
        [pack setBuffer:self.rifeCoreMLInputBuffer offset:0 atIndex:1];
        [pack setBuffer:self.rifeCoreMLFlowInputBuffer offset:0 atIndex:2];
        [pack setBytes:&params length:sizeof(params) atIndex:3];
        NSUInteger packWide = self.rifeCoreMLPackPipeline.threadExecutionWidth;
        NSUInteger packHigh = MAX(1, self.rifeCoreMLPackPipeline.maxTotalThreadsPerThreadgroup / packWide);
        [pack dispatchThreads:dispatchSize threadsPerThreadgroup:MTLSizeMake(packWide, packHigh, 1)];
        params.reverse = 1;
        [pack setBuffer:self.rifeCoreMLReverseXBuffer offset:0 atIndex:1];
        [pack setBuffer:self.rifeCoreMLReverseFlowInputBuffer offset:0 atIndex:2];
        [pack setBytes:&params length:sizeof(params) atIndex:3];
        [pack dispatchThreads:dispatchSize threadsPerThreadgroup:MTLSizeMake(packWide, packHigh, 1)];
        [pack endEncoding];
        [packCommand commit];
        [packCommand waitUntilCompleted];
        if (packCommand.status != MTLCommandBufferStatusCompleted) {
            self.lastMessage = @"CoreML block input pack failed";
            return NO;
        }

        Stellaria::Motion::RIFEMPSGraphRunResult forward =
            (*runners)[block]->RunWithBuffers((__bridge void*)self.rifeCoreMLInputBuffer,
                                              (__bridge void*)self.rifeCoreMLFlowInputBuffer,
                                              (__bridge void*)self.rifeCoreMLForwardOutputBuffer);
        if (!forward.ok) {
            self.lastMessage = [NSString stringWithFormat:@"CoreML block%d forward failed: %s", block, forward.message.c_str()];
            return NO;
        }
        Stellaria::Motion::RIFEMPSGraphRunResult reverse =
            (*runners)[block]->RunWithBuffers((__bridge void*)self.rifeCoreMLReverseXBuffer,
                                              (__bridge void*)self.rifeCoreMLReverseFlowInputBuffer,
                                              (__bridge void*)self.rifeCoreMLReverseOutputBuffer);
        if (!reverse.ok) {
            self.lastMessage = [NSString stringWithFormat:@"CoreML block%d reverse failed: %s", block, reverse.message.c_str()];
            return NO;
        }

        id<MTLCommandBuffer> accCommand = [self.commandQueue commandBuffer];
        id<MTLComputeCommandEncoder> acc = [accCommand computeCommandEncoder];
        [acc setComputePipelineState:self.rifeCoreMLAccumulatePipeline];
        params.reverse = 0;
        [acc setBuffer:self.rifeCoreMLForwardOutputBuffer offset:0 atIndex:0];
        [acc setBuffer:self.rifeCoreMLReverseOutputBuffer offset:0 atIndex:1];
        [acc setBuffer:self.rifeCoreMLFlowMaskBuffer offset:0 atIndex:2];
        [acc setBytes:&params length:sizeof(params) atIndex:3];
        NSUInteger accWide = self.rifeCoreMLAccumulatePipeline.threadExecutionWidth;
        NSUInteger accHigh = MAX(1, self.rifeCoreMLAccumulatePipeline.maxTotalThreadsPerThreadgroup / accWide);
        [acc dispatchThreads:dispatchSize threadsPerThreadgroup:MTLSizeMake(accWide, accHigh, 1)];
        [acc endEncoding];
        [accCommand commit];
        [accCommand waitUntilCompleted];
        if (accCommand.status != MTLCommandBufferStatusCompleted) {
            self.lastMessage = @"CoreML block accumulation failed";
            return NO;
        }
    }

    id<MTLCommandBuffer> blendCommand = [self.commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> blend = [blendCommand computeCommandEncoder];
    [blend setComputePipelineState:self.rifeCoreMLBlendPipeline];
    [blend setTexture:previous atIndex:0];
    [blend setTexture:current atIndex:1];
    [blend setTexture:output atIndex:2];
    params.reverse = 0;
    [blend setBuffer:self.rifeCoreMLFlowMaskBuffer offset:0 atIndex:0];
    [blend setBytes:&params length:sizeof(params) atIndex:1];
    NSUInteger blendWide = self.rifeCoreMLBlendPipeline.threadExecutionWidth;
    NSUInteger blendHigh = MAX(1, self.rifeCoreMLBlendPipeline.maxTotalThreadsPerThreadgroup / blendWide);
    [blend dispatchThreads:MTLSizeMake(width, height, 1) threadsPerThreadgroup:MTLSizeMake(blendWide, blendHigh, 1)];
    [blend endEncoding];
    [blendCommand commit];
    [blendCommand waitUntilCompleted];
    if (blendCommand.status != MTLCommandBufferStatusCompleted) {
        self.lastMessage = @"CoreML block blend failed";
        return NO;
    }

    if (elapsedMsOut != nullptr) {
        *elapsedMsOut = (CACurrentMediaTime() - start) * 1000.0;
    }
    return YES;
}

- (Stellaria::Motion::RIFECoreMLFlowMaskRunner*)coreMLFlowMaskRunnerForModelWidth:(NSUInteger)modelWidth height:(NSUInteger)modelHeight {
    const uint64_t key = (static_cast<uint64_t>(modelWidth) << 32U) | static_cast<uint64_t>(modelHeight);
    auto found = _rifeCoreMLFlowMaskRunnerCache.find(key);
    if (found != _rifeCoreMLFlowMaskRunnerCache.end()) {
        Stellaria::Motion::RIFECoreMLFlowMaskRunner* cached = found->second.get();
        return cached->IsReady() ? cached : nullptr;
    }
    auto runner = std::make_unique<Stellaria::Motion::RIFECoreMLFlowMaskRunner>();
    runner->Load(SMRIFECoreMLContinuousModelPath(static_cast<uint32_t>(modelWidth), static_cast<uint32_t>(modelHeight)),
                 static_cast<uint32_t>(modelWidth),
                 static_cast<uint32_t>(modelHeight));
    self.rifeCoreMLDiagnostics = [NSString stringWithUTF8String:runner->Diagnostics().c_str()];
    Stellaria::Motion::RIFECoreMLFlowMaskRunner* ptr = runner.get();
    const BOOL ready = ptr->IsReady();
    _rifeCoreMLFlowMaskRunnerCache[key] = std::move(runner);
    if (_rifeCoreMLFlowMaskRunnerCache.size() > 3) {
        for (auto it = _rifeCoreMLFlowMaskRunnerCache.begin(); it != _rifeCoreMLFlowMaskRunnerCache.end(); ++it) {
            if (it->first != key) {
                _rifeCoreMLFlowMaskRunnerCache.erase(it);
                break;
            }
        }
    }
    return ready ? ptr : nullptr;
}

- (BOOL)processTexturesWithRIFECoreMLContinuousPrevious:(id<MTLTexture>)previous current:(id<MTLTexture>)current output:(id<MTLTexture>)output width:(NSUInteger)width height:(NSUInteger)height modelWidth:(NSUInteger)modelWidth modelHeight:(NSUInteger)modelHeight elapsedMs:(double*)elapsedMsOut {
    if (previous == nil || current == nil || output == nil ||
        self.rifePackPipeline == nil ||
        self.rifeCoreMLBlendPipeline == nil) {
        return NO;
    }
    Stellaria::Motion::RIFECoreMLFlowMaskRunner* runner = [self coreMLFlowMaskRunnerForModelWidth:modelWidth height:modelHeight];
    if (runner == nullptr || !runner->IsReady()) {
        return NO;
    }

    const NSUInteger pixels = modelWidth * modelHeight;
    const NSUInteger inputBytes = pixels * 6 * sizeof(float);
    const NSUInteger flowMaskBytes = pixels * 5 * sizeof(float);
    if (self.rifeInputBuffer == nil || self.rifeInputBuffer.length < inputBytes) {
        self.rifeInputBuffer = [self.device newBufferWithLength:inputBytes options:MTLResourceStorageModeShared];
    }
    if (self.rifeCoreMLFlowMaskBuffer == nil || self.rifeCoreMLFlowMaskBuffer.length < flowMaskBytes) {
        self.rifeCoreMLFlowMaskBuffer = [self.device newBufferWithLength:flowMaskBytes options:MTLResourceStorageModeShared];
    }
    if (self.rifeInputBuffer == nil || self.rifeCoreMLFlowMaskBuffer == nil) {
        self.lastMessage = @"CoreML continuous buffer allocation failed";
        return NO;
    }

    SMRIFETextureParams packParams{
        .width = static_cast<uint32_t>(width),
        .height = static_cast<uint32_t>(height),
        .modelWidth = static_cast<uint32_t>(modelWidth),
        .modelHeight = static_cast<uint32_t>(modelHeight),
    };
    CFTimeInterval start = CACurrentMediaTime();
    const CFTimeInterval packStart = CACurrentMediaTime();
    id<MTLCommandBuffer> packCommand = [self.commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> pack = [packCommand computeCommandEncoder];
    [pack setComputePipelineState:self.rifePackPipeline];
    [pack setTexture:previous atIndex:0];
    [pack setTexture:current atIndex:1];
    [pack setBuffer:self.rifeInputBuffer offset:0 atIndex:0];
    [pack setBytes:&packParams length:sizeof(packParams) atIndex:1];
    const MTLSize packThreadgroup = SMMemoryBoundThreadgroup(self.rifePackPipeline);
    [pack dispatchThreads:MTLSizeMake(modelWidth, modelHeight, 1)
    threadsPerThreadgroup:packThreadgroup];
    [pack endEncoding];
    [packCommand commit];
    self.lastPackMs = (CACurrentMediaTime() - packStart) * 1000.0;

    Stellaria::Motion::RIFEMPSGraphRunResult result =
        runner->RunWithBuffers((__bridge void*)self.rifeInputBuffer,
                               (__bridge void*)self.rifeCoreMLFlowMaskBuffer);
    if (!result.ok) {
        self.lastMessage = [NSString stringWithFormat:@"CoreML continuous failed: %s", result.message.c_str()];
        return NO;
    }

    SMRIFECoreMLBlockParams blendParams{
        .width = static_cast<uint32_t>(width),
        .height = static_cast<uint32_t>(height),
        .modelWidth = static_cast<uint32_t>(modelWidth),
        .modelHeight = static_cast<uint32_t>(modelHeight),
        .reverse = 0,
    };
    id<MTLCommandBuffer> blendCommand = [self.commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> blend = [blendCommand computeCommandEncoder];
    [blend setComputePipelineState:self.rifeCoreMLBlendPipeline];
    [blend setTexture:previous atIndex:0];
    [blend setTexture:current atIndex:1];
    [blend setTexture:output atIndex:2];
    [blend setBuffer:self.rifeCoreMLFlowMaskBuffer offset:0 atIndex:0];
    [blend setBytes:&blendParams length:sizeof(blendParams) atIndex:1];
    const MTLSize blendThreadgroup = SMMemoryBoundThreadgroup(self.rifeCoreMLBlendPipeline);
    [blend dispatchThreads:MTLSizeMake(width, height, 1) threadsPerThreadgroup:blendThreadgroup];
    [blend endEncoding];
    [blendCommand commit];
    [blendCommand waitUntilCompleted];
    if (blendCommand.status != MTLCommandBufferStatusCompleted) {
        self.lastMessage = @"CoreML continuous blend failed";
        return NO;
    }
    if (elapsedMsOut != nullptr) {
        *elapsedMsOut = (CACurrentMediaTime() - start) * 1000.0;
    }
    return YES;
}

- (Stellaria::Motion::RIFECoreMLRunner*)coreMLRunnerForModelWidth:(NSUInteger)modelWidth height:(NSUInteger)modelHeight {
    const uint64_t key = (static_cast<uint64_t>(modelWidth) << 32U) | static_cast<uint64_t>(modelHeight);
    auto found = _rifeCoreMLRunnerCache.find(key);
    if (found != _rifeCoreMLRunnerCache.end()) {
        Stellaria::Motion::RIFECoreMLRunner* cached = found->second.get();
        return cached->IsReady() ? cached : nullptr;
    }
    auto runner = std::make_unique<Stellaria::Motion::RIFECoreMLRunner>();
    runner->Load(SMRIFECoreMLModelPath(), static_cast<uint32_t>(modelWidth), static_cast<uint32_t>(modelHeight));
    self.rifeCoreMLDiagnostics = [NSString stringWithUTF8String:runner->Diagnostics().c_str()];
    Stellaria::Motion::RIFECoreMLRunner* ptr = runner.get();
    const BOOL ready = ptr->IsReady();
    _rifeCoreMLRunnerCache[key] = std::move(runner);
    if (_rifeCoreMLRunnerCache.size() > 5) {
        for (auto it = _rifeCoreMLRunnerCache.begin(); it != _rifeCoreMLRunnerCache.end(); ++it) {
            if (it->first != key) {
                _rifeCoreMLRunnerCache.erase(it);
                break;
            }
        }
    }
    return ready ? ptr : nullptr;
}

- (Stellaria::Motion::RIFEMPSGraphRunner*)runnerForModelWidth:(NSUInteger)modelWidth height:(NSUInteger)modelHeight {
    const uint64_t key = (static_cast<uint64_t>(modelWidth) << 32U) | static_cast<uint64_t>(modelHeight);
    auto found = _rifeRunnerCache.find(key);
    if (found != _rifeRunnerCache.end()) {
        return found->second.get();
    }
    auto runner = std::make_unique<Stellaria::Motion::RIFEMPSGraphRunner>();
    if (!runner->Load(SMRIFEModelPath(), static_cast<uint32_t>(modelWidth), static_cast<uint32_t>(modelHeight))) {
        self.lastMessage = [NSString stringWithFormat:@"RIFE unavailable: %s", runner->Diagnostics().c_str()];
        return nullptr;
    }
    runner->SetCommandQueue((__bridge void*)self.commandQueue);
    Stellaria::Motion::RIFEMPSGraphRunner* ptr = runner.get();
    _rifeRunnerCache[key] = std::move(runner);
    if (_rifeRunnerCache.size() > 5) {
        for (auto it = _rifeRunnerCache.begin(); it != _rifeRunnerCache.end(); ++it) {
            if (it->first != key) {
                _rifeRunnerCache.erase(it);
                break;
            }
        }
    }
    return ptr;
}

- (Stellaria::Motion::RIFEMetal4BitRunner*)metal4RunnerForModelWidth:(NSUInteger)modelWidth height:(NSUInteger)modelHeight {
    const uint64_t key = (static_cast<uint64_t>(modelWidth) << 32U) | static_cast<uint64_t>(modelHeight);
    auto found = _rifeMetal4RunnerCache.find(key);
    if (found != _rifeMetal4RunnerCache.end()) {
        return found->second->IsReady() ? found->second.get() : nullptr;
    }
    auto runner = std::make_unique<Stellaria::Motion::RIFEMetal4BitRunner>();
    runner->SetCommandQueue((__bridge void*)self.commandQueue);
    if (!runner->Load(SMRIFEModelPath(), static_cast<uint32_t>(modelWidth), static_cast<uint32_t>(modelHeight))) {
        self.lastMessage = [NSString stringWithFormat:@"Metal INT4 unavailable: %s", runner->Diagnostics().c_str()];
        return nullptr;
    }
    self.rifeCoreMLDiagnostics = [NSString stringWithUTF8String:runner->Diagnostics().c_str()];
    Stellaria::Motion::RIFEMetal4BitRunner* ptr = runner.get();
    _rifeMetal4RunnerCache[key] = std::move(runner);
    if (_rifeMetal4RunnerCache.size() > 5) {
        for (auto it = _rifeMetal4RunnerCache.begin(); it != _rifeMetal4RunnerCache.end(); ++it) {
            if (it->first != key) {
                _rifeMetal4RunnerCache.erase(it);
                break;
            }
        }
    }
    return ptr;
}

- (Stellaria::Motion::RIFESP4Runner*)sp4RunnerForModelWidth:(NSUInteger)modelWidth height:(NSUInteger)modelHeight {
    const uint64_t key = (static_cast<uint64_t>(modelWidth) << 32U) | static_cast<uint64_t>(modelHeight);
    auto found = _rifeSP4RunnerCache.find(key);
    if (found != _rifeSP4RunnerCache.end()) {
        return found->second->IsReady() ? found->second.get() : nullptr;
    }
    auto runner = std::make_unique<Stellaria::Motion::RIFESP4Runner>();
    runner->SetCommandQueue((__bridge void*)self.commandQueue);
    if (!runner->Load(SMRIFEModelPath(), static_cast<uint32_t>(modelWidth), static_cast<uint32_t>(modelHeight))) {
        self.lastMessage = [NSString stringWithFormat:@"SP4 unavailable: %s", runner->Diagnostics().c_str()];
        return nullptr;
    }
    self.rifeCoreMLDiagnostics = [NSString stringWithUTF8String:runner->Diagnostics().c_str()];
    Stellaria::Motion::RIFESP4Runner* ptr = runner.get();
    _rifeSP4RunnerCache[key] = std::move(runner);
    if (_rifeSP4RunnerCache.size() > 5) {
        for (auto it = _rifeSP4RunnerCache.begin(); it != _rifeSP4RunnerCache.end(); ++it) {
            if (it->first != key) {
                _rifeSP4RunnerCache.erase(it);
                break;
            }
        }
    }
    return ptr;
}

- (BOOL)processTexturesWithRIFEMetal4Previous:(id<MTLTexture>)previous current:(id<MTLTexture>)current output:(id<MTLTexture>)output width:(NSUInteger)width height:(NSUInteger)height {
    if (previous == nil || current == nil || output == nil) {
        return NO;
    }
    const double requestedHeight = self.pendingFlowInputHeight > 0.0 ? self.pendingFlowInputHeight : 540.0;
    const NSUInteger modelHeight = MAX(static_cast<NSUInteger>(128), static_cast<NSUInteger>(SMFixedRIFEHeightForSource(height, requestedHeight)));
    const NSUInteger modelWidth = SMRIFEWidthForHeight(width, height, static_cast<uint32_t>(modelHeight));
    Stellaria::Motion::RIFEMetal4BitRunner* runner = [self metal4RunnerForModelWidth:modelWidth height:modelHeight];
    if (runner == nullptr || !runner->IsReady()) {
        return NO;
    }
    const Stellaria::Motion::RIFEMetal4BitRunResult result =
        runner->RunTextures((__bridge void*)previous,
                            (__bridge void*)current,
                            (__bridge void*)output,
                            static_cast<uint32_t>(width),
                            static_cast<uint32_t>(height));
    if (!result.ok) {
        self.lastMessage = [NSString stringWithFormat:@"Metal INT4 failed: %s", result.message.c_str()];
        return NO;
    }
    self.rifeModelWidth = modelWidth;
    self.rifeModelHeight = modelHeight;
    self.lastGpuMs = result.elapsedMs;
    self.lastPackMs = 0.0;
    self.lastUnpackMs = 0.0;
    self.rifeBackendName = @"Metal INT4/GPU";
    self.rifeCoreMLDiagnostics = [NSString stringWithUTF8String:runner->Diagnostics().c_str()];
    self.rifeFrames += 1;
    self.lastMessage = [NSString stringWithFormat:@"Metal INT4 RIFE frame processed · %lux%lu · %.1fms",
                        static_cast<unsigned long>(modelWidth),
                        static_cast<unsigned long>(modelHeight),
                        result.elapsedMs];
    return YES;
}

- (BOOL)processTexturesWithRIFESP4Previous:(id<MTLTexture>)previous current:(id<MTLTexture>)current output:(id<MTLTexture>)output width:(NSUInteger)width height:(NSUInteger)height {
    if (previous == nil || current == nil || output == nil) {
        return NO;
    }
    const double requestedHeight = self.pendingFlowInputHeight > 0.0 ? self.pendingFlowInputHeight : 540.0;
    const NSUInteger modelHeight = MAX(static_cast<NSUInteger>(128), static_cast<NSUInteger>(SMFixedRIFEHeightForSource(height, requestedHeight)));
    const NSUInteger modelWidth = SMRIFEWidthForHeight(width, height, static_cast<uint32_t>(modelHeight));
    Stellaria::Motion::RIFESP4Runner* runner = [self sp4RunnerForModelWidth:modelWidth height:modelHeight];
    if (runner == nullptr || !runner->IsReady()) {
        return NO;
    }
    const Stellaria::Motion::RIFESP4RunResult result =
        runner->RunTextures((__bridge void*)previous,
                            (__bridge void*)current,
                            (__bridge void*)output,
                            static_cast<uint32_t>(width),
                            static_cast<uint32_t>(height));
    if (!result.ok) {
        self.lastMessage = [NSString stringWithFormat:@"SP4 failed: %s", result.message.c_str()];
        return NO;
    }
    self.rifeModelWidth = modelWidth;
    self.rifeModelHeight = modelHeight;
    self.lastGpuMs = result.elapsedMs;
    self.lastPackMs = 0.0;
    self.lastUnpackMs = 0.0;
    self.rifeBackendName = @"Stellaria SP4";
    self.rifeCoreMLDiagnostics = [NSString stringWithUTF8String:runner->Diagnostics().c_str()];
    self.rifeFrames += 1;
    self.lastMessage = [NSString stringWithFormat:@"SP4 frame processed · %lux%lu · %.1fms",
                        static_cast<unsigned long>(modelWidth),
                        static_cast<unsigned long>(modelHeight),
                        result.elapsedMs];
    return YES;
}

- (BOOL)processTexturesWithRIFESP4Previous:(id<MTLTexture>)previous current:(id<MTLTexture>)current outputs:(NSArray<id<MTLTexture>>*)outputs tValues:(const float*)tValues count:(NSUInteger)count width:(NSUInteger)width height:(NSUInteger)height {
    if (previous == nil || current == nil || outputs.count == 0 || tValues == nullptr) {
        return NO;
    }
    const double requestedHeight = self.pendingFlowInputHeight > 0.0 ? self.pendingFlowInputHeight : 360.0;
    const double budget = self.pendingGpuBudgetMs > 0.0 ? self.pendingGpuBudgetMs : 12.0;
    const double fps = self.pendingTargetFPS > 1.0 ? self.pendingTargetFPS : 60.0;
    const double budgetScale = budget < 14.0 ? 0.82 : (budget < 17.0 ? 0.92 : 1.0);
    const double fpsScale = fps >= 119.0 ? 0.72 : 1.0;
    const NSUInteger sourceCapped = static_cast<NSUInteger>(MIN(static_cast<double>(height), requestedHeight * budgetScale * fpsScale));
    NSUInteger modelHeight = MAX(static_cast<NSUInteger>(128), static_cast<NSUInteger>(SMAlign16(sourceCapped)));
    NSUInteger modelWidth = SMRIFEWidthForHeight(width, height, static_cast<uint32_t>(modelHeight));
    Stellaria::Motion::RIFESP4Runner* runner = [self sp4RunnerForModelWidth:modelWidth height:modelHeight];
    if (runner == nullptr || !runner->IsReady()) {
        return NO;
    }

    const NSUInteger outputCount = MIN(count, outputs.count);
    std::vector<void*> outputPointers;
    outputPointers.reserve(outputCount);
    for (NSUInteger i = 0; i < outputCount; ++i) {
        id<MTLTexture> texture = outputs[i];
        if (texture == nil) {
            return NO;
        }
        outputPointers.push_back((__bridge void*)texture);
    }

    const Stellaria::Motion::RIFESP4RunResult result =
        runner->RunTexturesAtTValues((__bridge void*)previous,
                                     (__bridge void*)current,
                                     outputPointers.data(),
                                     tValues,
                                     static_cast<uint32_t>(outputPointers.size()),
                                     static_cast<uint32_t>(width),
                                     static_cast<uint32_t>(height));
    self.rifeBackendName = @"Stellaria SP4";
    self.rifeModelWidth = modelWidth;
    self.rifeModelHeight = modelHeight;
    if (!result.ok) {
        self.lastMessage = [NSString stringWithFormat:@"SP4 batch failed: %s", result.message.c_str()];
        return NO;
    }
    self.lastGpuMs = result.elapsedMs;
    self.rifeFrames += 1;
    self.lastMessage = [NSString stringWithFormat:@"SP4 batch processed · %lux%lu · %lu slots · %.1fms",
                        static_cast<unsigned long>(modelWidth),
                        static_cast<unsigned long>(modelHeight),
                        static_cast<unsigned long>(outputPointers.size()),
                        result.elapsedMs];
    return YES;
}

- (BOOL)processTexturesWithRIFEPrevious:(id<MTLTexture>)previous current:(id<MTLTexture>)current output:(id<MTLTexture>)output width:(NSUInteger)width height:(NSUInteger)height {
    if (previous == nil || current == nil || output == nil || self.rifePackPipeline == nil || self.rifeUnpackPipeline == nil) {
        return NO;
    }
    const BOOL auxiliaryPass = self.auxiliaryRIFEPass;
    const double requestedHeight = self.pendingFlowInputHeight > 0.0 ? self.pendingFlowInputHeight : 540.0;
    NSUInteger modelHeight = SMFixedRIFEHeightForSource(height, requestedHeight);
    NSUInteger modelWidth = SMRIFEWidthForHeight(width, height, static_cast<uint32_t>(modelHeight));
    const NSUInteger inputBytes = modelWidth * modelHeight * 6 * sizeof(float);
    const NSUInteger outputBytes = modelWidth * modelHeight * 3 * sizeof(float);
    if (self.rifeInputBuffer == nil || self.rifeInputBuffer.length < inputBytes) {
        self.rifeInputBuffer = [self.device newBufferWithLength:inputBytes options:MTLResourceStorageModePrivate];
    }
    if (self.rifeOutputBuffer == nil || self.rifeOutputBuffer.length < outputBytes) {
        self.rifeOutputBuffer = [self.device newBufferWithLength:outputBytes options:MTLResourceStorageModePrivate];
    }
    if (self.rifeInputBuffer == nil || self.rifeOutputBuffer == nil) {
        self.lastMessage = @"RIFE tensor buffer allocation failed";
        return NO;
    }
    self.rifeModelWidth = modelWidth;
    self.rifeModelHeight = modelHeight;

    SMRIFETextureParams params{
        .width = static_cast<uint32_t>(width),
        .height = static_cast<uint32_t>(height),
        .modelWidth = static_cast<uint32_t>(modelWidth),
        .modelHeight = static_cast<uint32_t>(modelHeight),
    };

    id<MTLCommandBuffer> packCommand = [self.commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> pack = [packCommand computeCommandEncoder];
    [pack setComputePipelineState:self.rifePackPipeline];
    [pack setTexture:previous atIndex:0];
    [pack setTexture:current atIndex:1];
    [pack setBuffer:self.rifeInputBuffer offset:0 atIndex:0];
    [pack setBytes:&params length:sizeof(params) atIndex:1];
    const MTLSize packThreadgroup = SMMemoryBoundThreadgroup(self.rifePackPipeline);
    [pack dispatchThreads:MTLSizeMake(modelWidth, modelHeight, 1)
    threadsPerThreadgroup:packThreadgroup];
    [pack endEncoding];
    [packCommand commit];

    Stellaria::Motion::RIFEMPSGraphRunner* runner = [self runnerForModelWidth:modelWidth height:modelHeight];
    if (runner == nullptr || !runner->IsReady()) {
        return NO;
    }
    self.rifeRunner = runner;
    Stellaria::Motion::RIFEMPSGraphRunResult result =
        runner->RunWithBuffers((__bridge void*)self.rifeInputBuffer, (__bridge void*)self.rifeOutputBuffer);
    if (!auxiliaryPass) {
        self.rifeBackendName = @"MPSGraph/GPU";
    }
    if (!result.ok) {
        self.lastMessage = [NSString stringWithFormat:@"RIFE inference failed: %s", result.message.c_str()];
        return NO;
    }

    const CFTimeInterval unpackStart = CACurrentMediaTime();
    id<MTLCommandBuffer> unpackCommand = [self.commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> unpack = [unpackCommand computeCommandEncoder];
    [unpack setComputePipelineState:self.rifeUnpackPipeline];
    [unpack setBuffer:self.rifeOutputBuffer offset:0 atIndex:0];
    [unpack setTexture:previous atIndex:0];
    [unpack setTexture:current atIndex:1];
    [unpack setTexture:output atIndex:2];
    [unpack setBytes:&params length:sizeof(params) atIndex:1];
    const MTLSize unpackThreadgroup = SMMemoryBoundThreadgroup(self.rifeUnpackPipeline);
    [unpack dispatchThreads:MTLSizeMake(width, height, 1)
      threadsPerThreadgroup:unpackThreadgroup];
    [unpack endEncoding];
    [unpackCommand commit];
    [unpackCommand waitUntilCompleted];
    self.lastUnpackMs = (CACurrentMediaTime() - unpackStart) * 1000.0;
    if (unpackCommand.status != MTLCommandBufferStatusCompleted) {
        self.lastMessage = @"RIFE output unpack failed";
        return NO;
    }
    self.lastGpuMs = result.elapsedMs;
    self.rifeFrames += 1;
    if (!auxiliaryPass) {
        self.lastMessage = [NSString stringWithFormat:@"RIFE %@ frame processed · %lux%lu model",
                                                       self.rifeBackendName ?: @"MPSGraph/GPU",
                                                       static_cast<unsigned long>(modelWidth),
                                                       static_cast<unsigned long>(modelHeight)];
    }
    return YES;
}

- (SMEncodedVideoChunk*)videoChunkFromTexture:(id<MTLTexture>)texture width:(NSUInteger)width height:(NSUInteger)height {
    return [self videoChunkFromTexture:texture width:width height:height forceKeyFrame:NO];
}

- (SMEncodedVideoChunk*)videoChunkFromTexture:(id<MTLTexture>)texture width:(NSUInteger)width height:(NSUInteger)height forceKeyFrame:(BOOL)forceKeyFrame {
    if (![self ensureOutputEncodeSessionWithWidth:width height:height]) {
        return nil;
    }
    const CFTimeInterval encodeStart = CACurrentMediaTime();
    CVPixelBufferRef pixelBuffer = [self newPixelBufferFromTexture:texture width:width height:height];
    if (pixelBuffer == nullptr) {
        self.lastMessage = @"VideoToolbox output pixel buffer failed";
        return nil;
    }

    SMEncodedVideoChunk* chunk = [SMEncodedVideoChunk new];
    const BOOL earlyReturnFrames = self.hardwareEncodedFrames < 3 || self.processedFrames < 3 || !self.outputSenderPrimed;
    const BOOL requestedKeyFrame = forceKeyFrame || self.pendingForceReturnKeyframe || earlyReturnFrames || self.hardwareEncodedFrames % 15 == 0;
    NSDictionary* frameProps = requestedKeyFrame
        ? @{(__bridge NSString*)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES}
        : nil;
    const int32_t fps = static_cast<int32_t>(MAX(24.0, MIN(240.0, self.pendingTargetFPS > 0.0 ? self.pendingTargetFPS : 60.0)));
    const CMTime pts = CMTimeMake(static_cast<int64_t>(self.hardwareEncodedFrames), fps);
    OSStatus status = VTCompressionSessionEncodeFrame(self.outputEncodeSession,
                                                      pixelBuffer,
                                                      pts,
                                                      CMTimeMake(1, fps),
                                                      (__bridge CFDictionaryRef)frameProps,
                                                      (__bridge void*)chunk,
                                                      nullptr);
    VTCompressionSessionCompleteFrames(self.outputEncodeSession, kCMTimeInvalid);
    self.lastEncodeMs = (CACurrentMediaTime() - encodeStart) * 1000.0;
    CVPixelBufferRelease(pixelBuffer);
    if (status != noErr || chunk.data.length == 0) {
        self.lastMessage = [NSString stringWithFormat:@"VideoToolbox output encode failed: %d", static_cast<int>(status)];
        return nil;
    }
    if (requestedKeyFrame) {
        chunk.keyFrame = YES;
        self.pendingForceReturnKeyframe = NO;
    }
    self.hardwareEncodedFrames += 1;
    return chunk;
}

- (void)appendOutputPayload:(NSData*)payload
                      chunk:(SMEncodedVideoChunk*)chunk
                      width:(NSUInteger)width
                     height:(NSUInteger)height
                   subIndex:(uint32_t)subIndex
                   subCount:(uint32_t)subCount {
    if (payload.length == 0) {
        return;
    }
    if (self.lastOutputFrames == nil) {
        self.lastOutputFrames = [NSMutableArray array];
    }
    SMProcessedOutputFrame* frame = [SMProcessedOutputFrame new];
    frame.payload = payload;
    frame.chunk = chunk;
    frame.width = width;
    frame.height = height;
    frame.subIndex = subIndex;
    frame.subCount = subCount;
    frame.frameId = self.pendingFrameId;
    frame.targetFPS = self.pendingTargetFPS;
    frame.durationUs = llround(1000000.0 / MAX(24.0, MIN(240.0, self.pendingTargetFPS > 0.0 ? self.pendingTargetFPS : 60.0)));
    frame.gpuMs = self.lastGpuMs;
    frame.processedFrames = self.processedFrames;
    frame.receivedFrames = self.receivedFrames;
    [self.lastOutputFrames addObject:frame];
}

- (void)updateInputClock {
    double instantFPS = 0.0;
    if (self.pendingInputDuration > 1000.0 && self.pendingInputDuration < 1000000.0) {
        instantFPS = 1000000.0 / self.pendingInputDuration;
    } else if (self.pendingInputPTS > 0.0 && self.lastInputPTS > 0.0) {
        const double delta = self.pendingInputPTS - self.lastInputPTS;
        if (delta > 1000.0 && delta < 1000000.0) {
            instantFPS = 1000000.0 / delta;
        }
    }
    if (instantFPS > 1.0 && instantFPS < 240.0) {
        self.estimatedSourceFPS = self.estimatedSourceFPS > 1.0
            ? self.estimatedSourceFPS * 0.65 + instantFPS * 0.35
            : instantFPS;
    }
    if (self.pendingInputPTS > 0.0) {
        self.lastInputPTS = self.pendingInputPTS;
    }
}

- (double)outputPrerollSecondsForTargetFPS:(double)fps {
    (void)fps;
    return 0.0;
}

- (double)outputMaxQueueSecondsForTargetFPS:(double)fps {
    (void)fps;
    return 0.55;
}

- (double)outputQueueSecondsLocked {
    const double fps = MAX(24.0, MIN(240.0, self.outputQueueTargetFPS > 0.0 ? self.outputQueueTargetFPS : 60.0));
    return static_cast<double>(self.outputSendQueue.count) / fps;
}

- (void)resetOutputQueueAndClock {
    [self.outputQueueCondition lock];
    [self.outputSendQueue removeAllObjects];
    self.nextOutputSendTime = 0.0;
    self.nextOutputContentPTS = 0.0;
    self.outputClockPrimed = NO;
    self.outputSenderPrimed = NO;
    self.pendingForceReturnKeyframe = YES;
    [self.outputQueueCondition broadcast];
    [self.outputQueueCondition unlock];
}

- (NSArray<SMProcessedOutputFrame*>*)stableOutputFramesFromFrames:(NSArray<SMProcessedOutputFrame*>*)frames targetFPS:(double)targetFPS {
    if (frames.count == 0) {
        return @[];
    }
    NSArray<SMProcessedOutputFrame*>* sorted = [frames sortedArrayUsingComparator:^NSComparisonResult(SMProcessedOutputFrame* a, SMProcessedOutputFrame* b) {
        if (a.subIndex < b.subIndex) {
            return NSOrderedAscending;
        }
        if (a.subIndex > b.subIndex) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
    (void)targetFPS;
    self.outputClockPrimed = YES;
    return sorted;
}

- (void)enqueueOutputFrames:(NSArray<SMProcessedOutputFrame*>*)frames targetFPS:(double)targetFPS {
    if (frames.count == 0) {
        return;
    }
    [self.outputQueueCondition lock];
    self.outputQueueTargetFPS = MAX(24.0, MIN(240.0, targetFPS > 0.0 ? targetFPS : 60.0));
    for (SMProcessedOutputFrame* frame in frames) {
        if (frame.chunk.data.length == 0 || frame.payload.length == 0) {
            continue;
        }
        frame.targetFPS = self.outputQueueTargetFPS;
        frame.durationUs = llround(1000000.0 / self.outputQueueTargetFPS);
        frame.gpuMs = self.lastGpuMs;
        frame.processedFrames = self.processedFrames;
        frame.receivedFrames = self.receivedFrames;
        [self.outputSendQueue addObject:frame];
    }
    const double maxQueueSeconds = [self outputMaxQueueSecondsForTargetFPS:self.outputQueueTargetFPS];
    const NSUInteger hardLimit = static_cast<NSUInteger>(MAX(4.0, ceil(self.outputQueueTargetFPS * maxQueueSeconds)));
    while (self.outputSendQueue.count > hardLimit) {
        [self.outputSendQueue removeObjectAtIndex:0];
    }
    if (_realtimeSession) {
        _realtimeSession->NoteQueueDepth(static_cast<uint32_t>(self.outputSendQueue.count));
        _realtimeSession->NotePipelineTiming(self.lastGpuMs, self.lastEncodeMs);
    }
    [self.outputQueueCondition broadcast];
    [self.outputQueueCondition unlock];
}

- (void)trimOutputQueueForInputBackpressure {
    const double fps = MAX(24.0, MIN(240.0, self.pendingTargetFPS > 0.0 ? self.pendingTargetFPS : 60.0));
    const double maxQueueSeconds = [self outputMaxQueueSecondsForTargetFPS:fps];
    [self.outputQueueCondition lock];
    self.outputQueueTargetFPS = fps;
    const NSUInteger hardLimit = static_cast<NSUInteger>(MAX(2.0, ceil(fps * maxQueueSeconds)));
    while (self.outputSendQueue.count > hardLimit) {
        [self.outputSendQueue removeObjectAtIndex:0];
    }
    if (_realtimeSession) {
        _realtimeSession->NoteQueueDepth(static_cast<uint32_t>(self.outputSendQueue.count));
    }
    [self.outputQueueCondition broadcast];
    [self.outputQueueCondition unlock];
}

- (void)startOutputSenderForClient:(int)client {
    [self.outputQueueCondition lock];
    self.outputClient = client;
    self.outputSenderStop = NO;
    self.outputPlaybackPaused = NO;
    if (!self.outputSenderRunning) {
        self.outputSenderRunning = YES;
        [NSThread detachNewThreadSelector:@selector(outputSenderLoop) toTarget:self withObject:nil];
    }
    [self.outputQueueCondition broadcast];
    [self.outputQueueCondition unlock];
}

- (void)stopOutputSender {
    [self.outputQueueCondition lock];
    self.outputSenderStop = YES;
    self.outputPlaybackPaused = YES;
    [self.outputSendQueue removeAllObjects];
    if (_realtimeSession) {
        _realtimeSession->NoteQueueDepth(0);
    }
    self.outputSenderPrimed = NO;
    self.nextOutputSendTime = 0.0;
    [self.outputQueueCondition broadcast];
    [self.outputQueueCondition unlock];
}

- (void)outputSenderLoop {
    @autoreleasepool {
        while (self.running) {
            SMProcessedOutputFrame* frame = nil;
            int client = -1;
            [self.outputQueueCondition lock];
            while (self.running && !self.outputSenderStop) {
                if (self.outputPlaybackPaused) {
                    [self.outputSendQueue removeAllObjects];
                    self.outputSenderPrimed = NO;
                    self.nextOutputSendTime = 0.0;
                    [self.outputQueueCondition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                    continue;
                }
                if (self.outputSendQueue.count == 0) {
                    self.nextOutputSendTime = 0.0;
                    [self.outputQueueCondition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
                    continue;
                }
                self.outputSenderPrimed = YES;
                frame = self.outputSendQueue.firstObject;
                [self.outputSendQueue removeObjectAtIndex:0];
                if (_realtimeSession) {
                    _realtimeSession->NoteQueueDepth(static_cast<uint32_t>(self.outputSendQueue.count));
                }
                client = self.outputClient;
                [self.outputQueueCondition broadcast];
                break;
            }
            const BOOL shouldStop = self.outputSenderStop || !self.running;
            [self.outputQueueCondition unlock];
            if (shouldStop) {
                break;
            }
            if (frame == nil || client < 0) {
                continue;
            }
            if (self.outputPlaybackPaused || self.outputSenderStop) {
                self.nextOutputSendTime = 0.0;
                continue;
            }
            if (![self sendOutputFrame:frame client:client]) {
                self.lastMessage = @"browser output send failed";
                [self stopOutputSender];
                break;
            }
            if (_realtimeSession) {
                _realtimeSession->NoteOutputFrame(CACurrentMediaTime());
            }
            self.nextOutputSendTime = 0.0;
        }
        [self.outputQueueCondition lock];
        self.outputSenderRunning = NO;
        [self.outputQueueCondition broadcast];
        [self.outputQueueCondition unlock];
    }
}

- (BOOL)sendOutputFrame:(SMProcessedOutputFrame*)frame client:(int)client {
    if (frame == nil) {
        return YES;
    }
    const double fps = MAX(24.0, MIN(240.0, frame.targetFPS > 0.0 ? frame.targetFPS : 60.0));
    SMEncodedVideoChunk* outputChunk = frame.chunk;
    if (outputChunk.data.length == 0 || frame.payload.length == 0) {
        self.lastMessage = @"hardware output encoder unavailable";
        return NO;
    }
    NSString* outputCodec = self.outputEncodeCodecString ?: @"avc1.64002a";
    NSUInteger outputWidth = frame.width > 0 ? frame.width : self.outputEncodeWidth;
    NSUInteger outputHeight = frame.height > 0 ? frame.height : self.outputEncodeHeight;
    NSData* framedOutput = SMBinaryOutputFrame(frame.payload,
                                               outputChunk.codecDescription,
                                               frame.frameId,
                                               outputChunk.keyFrame,
                                               NO,
                                               outputCodec,
                                               outputWidth,
                                               outputHeight,
                                               frame.durationUs > 0 ? frame.durationUs : llround(1000000.0 / fps),
                                               frame.gpuMs,
                                               frame.processedFrames,
                                               frame.receivedFrames,
                                               frame.subIndex,
                                               frame.subCount);
    [self.webSocketSendLock lock];
    const BOOL sent = SMSendBinaryFrame(client, framedOutput ?: frame.payload);
    [self.webSocketSendLock unlock];
    return sent;
}

- (NSData*)processPixelBufferWithMetal:(CVPixelBufferRef)currentBuffer {
    if (![self ensureMetalReady] || currentBuffer == nullptr) {
        return nil;
    }
    self.lastOutputVideoChunk = nil;
    self.lastOutputFrames = nil;
    CVMetalTextureRef currentRef = nullptr;
    id<MTLTexture> current = [self textureFromPixelBuffer:currentBuffer textureRef:&currentRef];
    if (current == nil) {
        if (currentRef != nullptr) {
            CFRelease(currentRef);
        }
        self.lastMessage = @"VideoToolbox texture import failed";
        return nil;
    }

    const NSUInteger width = CVPixelBufferGetWidth(currentBuffer);
    const NSUInteger height = CVPixelBufferGetHeight(currentBuffer);
    if (self.previousPixelBuffer == nullptr ||
        CVPixelBufferGetWidth(self.previousPixelBuffer) != width ||
        CVPixelBufferGetHeight(self.previousPixelBuffer) != height) {
        if (self.previousPixelBuffer != nullptr) {
            CVPixelBufferRelease(self.previousPixelBuffer);
        }
        [self resetOutputQueueAndClock];
        self.pendingForceReturnKeyframe = YES;
        const double targetFPS = MAX(24.0, MIN(60.0, self.pendingTargetFPS > 0.0 ? self.pendingTargetFPS : 60.0));
        const double targetIntervalUs = 1000000.0 / targetFPS;
        if (self.pendingInputPTS > 0.0) {
            self.nextOutputContentPTS = self.pendingInputPTS + targetIntervalUs;
        }
        self.previousPixelBuffer = CVPixelBufferRetain(currentBuffer);
        self.lastGpuMs = 0.0;
        NSData* firstFrame = nil;
        if ([self copyTextureToOutput:current width:width height:height]) {
            SMEncodedVideoChunk* encoded = [self videoChunkFromTexture:self.outputTexture width:width height:height forceKeyFrame:YES];
            if (encoded.data.length > 0) {
                self.lastOutputVideoChunk = encoded;
                firstFrame = encoded.data;
            } else if (!self.pendingNoCpuReadback) {
                firstFrame = [self jpegDataFromTexture:self.outputTexture width:width height:height];
            }
        }
        CFRelease(currentRef);
        return firstFrame;
    }

    CVMetalTextureRef previousRef = nullptr;
    id<MTLTexture> previous = [self textureFromPixelBuffer:self.previousPixelBuffer textureRef:&previousRef];
    id<MTLTexture> output = [self ensureOutputTextureWithWidth:width height:height];
    if (previous == nil || output == nil) {
        if (previousRef != nullptr) {
            CFRelease(previousRef);
        }
        CFRelease(currentRef);
        self.lastMessage = @"VideoToolbox previous texture import failed";
        return nil;
    }

    if ([self isSceneCutBetweenPreviousBuffer:self.previousPixelBuffer current:currentBuffer]) {
        [self resetOutputQueueAndClock];
        self.pendingForceReturnKeyframe = YES;
        const double targetFPS = MAX(24.0, MIN(60.0, self.pendingTargetFPS > 0.0 ? self.pendingTargetFPS : 60.0));
        const double targetIntervalUs = 1000000.0 / targetFPS;
        if (self.pendingInputPTS > 0.0) {
            self.nextOutputContentPTS = self.pendingInputPTS + targetIntervalUs;
        }
        NSData* currentFrame = nil;
        if ([self copyTextureToOutput:current width:width height:height]) {
            SMEncodedVideoChunk* encoded = [self videoChunkFromTexture:self.outputTexture width:width height:height forceKeyFrame:YES];
            if (encoded.data.length > 0) {
                self.lastOutputVideoChunk = encoded;
                currentFrame = encoded.data;
            } else if (!self.pendingNoCpuReadback) {
                currentFrame = [self jpegDataFromTexture:self.outputTexture width:width height:height];
            }
        }
        CVPixelBufferRelease(self.previousPixelBuffer);
        self.previousPixelBuffer = CVPixelBufferRetain(currentBuffer);
        if (previousRef != nullptr) {
            CFRelease(previousRef);
        }
        CFRelease(currentRef);
        self.lastGpuMs = 0.0;
        self.lastMessage = @"scene cut reset · current keyframe returned";
        return currentFrame;
    }

    const BOOL wantsSP4 = [self.pendingRIFEBackend isEqualToString:@"stellaria_sp4_a1p"];
    const BOOL wantsMetal4 = [self.pendingRIFEBackend isEqualToString:@"metal_int4_experimental"];
    const double sourceFPS = self.estimatedSourceFPS > 1.0 ? self.estimatedSourceFPS : 24.0;
    const double targetFPS = MAX(24.0, MIN(60.0, self.pendingTargetFPS > 0.0 ? self.pendingTargetFPS : 60.0));
    const double sourceIntervalUs = 1000000.0 / MAX(1.0, sourceFPS);
    const double targetIntervalUs = 1000000.0 / targetFPS;
    const double currentPTS = self.pendingInputPTS > 0.0
        ? self.pendingInputPTS
        : static_cast<double>(MAX(static_cast<uint64_t>(1), self.pendingFrameId)) * sourceIntervalUs;
    double inputIntervalUs = (self.pendingInputDuration > 1000.0 && self.pendingInputDuration < 1000000.0)
        ? self.pendingInputDuration
        : sourceIntervalUs;
    double previousPTS = currentPTS - inputIntervalUs;
    if (!(currentPTS > previousPTS)) {
        previousPTS = currentPTS - sourceIntervalUs;
        inputIntervalUs = sourceIntervalUs;
    }
    const double resetGuardUs = MAX(sourceIntervalUs, inputIntervalUs);
    if (self.nextOutputContentPTS <= previousPTS + 1.0 ||
        self.nextOutputContentPTS > currentPTS + resetGuardUs) {
        self.nextOutputContentPTS = previousPTS + targetIntervalUs;
    }
    std::vector<float> interpolationTValues;
    BOOL includeCurrentEnd = NO;
    constexpr size_t kMaxBrowserCatchupSubframes = 8;
    while (self.nextOutputContentPTS <= currentPTS + targetIntervalUs * 0.25 &&
           interpolationTValues.size() + (includeCurrentEnd ? 1U : 0U) < kMaxBrowserCatchupSubframes) {
        const double t = (self.nextOutputContentPTS - previousPTS) / MAX(1.0, currentPTS - previousPTS);
        if (t >= 0.995) {
            includeCurrentEnd = YES;
        } else if (t > 0.005) {
            interpolationTValues.push_back(static_cast<float>(MAX(0.0, MIN(0.995, t))));
        }
        self.nextOutputContentPTS += targetIntervalUs;
    }
    if (interpolationTValues.empty() && !includeCurrentEnd) {
        interpolationTValues.push_back(0.5f);
    }

    NSMutableArray<id<MTLTexture>>* interpolationTextures = [NSMutableArray array];
    BOOL madeOutput = includeCurrentEnd && interpolationTValues.empty();
    if (wantsSP4 && !interpolationTValues.empty()) {
        for (NSUInteger i = 0; i < interpolationTValues.size(); ++i) {
            id<MTLTexture> slot = i == 0 ? output : [self ensureMultiTTextureSlot:i - 1 width:width height:height];
            if (slot != nil) {
                [interpolationTextures addObject:slot];
            }
        }
        if (interpolationTextures.count == interpolationTValues.size()) {
            NSArray<id<MTLTexture>>* outputs = [interpolationTextures copy];
            madeOutput = [self processTexturesWithRIFESP4Previous:previous
                                                          current:current
                                                          outputs:outputs
                                                          tValues:interpolationTValues.data()
                                                            count:interpolationTValues.size()
                                                            width:width
                                                           height:height];
        } else {
            madeOutput = NO;
        }
    }
    if (!madeOutput && !interpolationTValues.empty()) {
        madeOutput = wantsSP4
            ? [self processTexturesWithRIFESP4Previous:previous current:current output:output width:width height:height]
            : (wantsMetal4
            ? [self processTexturesWithRIFEMetal4Previous:previous current:current output:output width:width height:height]
            : [self processTexturesWithRIFEPrevious:previous current:current output:output width:width height:height]);
        if (madeOutput) {
            [interpolationTextures removeAllObjects];
            [interpolationTextures addObject:output];
        }
    }
    if (madeOutput) {
        NSData* primary = nil;
        const uint32_t outputSubCount = static_cast<uint32_t>(interpolationTextures.count + (includeCurrentEnd ? 1U : 0U));
        uint32_t subIndex = 1;
        for (id<MTLTexture> interpolated in interpolationTextures) {
            SMEncodedVideoChunk* encoded = [self videoChunkFromTexture:interpolated width:width height:height forceKeyFrame:NO];
            if (encoded.data.length > 0) {
                self.lastOutputVideoChunk = encoded;
                [self appendOutputPayload:encoded.data chunk:encoded width:width height:height subIndex:subIndex subCount:outputSubCount];
                primary = primary ?: encoded.data;
            }
            subIndex += 1;
        }
        if (includeCurrentEnd) {
            SMEncodedVideoChunk* encodedEnd = [self videoChunkFromTexture:current width:width height:height forceKeyFrame:NO];
            if (encodedEnd.data.length > 0) {
                [self appendOutputPayload:encodedEnd.data chunk:encodedEnd width:width height:height subIndex:subIndex subCount:outputSubCount];
                primary = primary ?: encodedEnd.data;
            }
        }

        CVPixelBufferRelease(self.previousPixelBuffer);
        self.previousPixelBuffer = CVPixelBufferRetain(currentBuffer);
        if (previousRef != nullptr) {
            CFRelease(previousRef);
        }
        CFRelease(currentRef);
        if (primary.length > 0) {
            return primary;
        }
        return self.pendingNoCpuReadback ? nil : [self jpegDataFromTexture:output width:width height:height];
    }
    if (previousRef != nullptr) {
        CFRelease(previousRef);
    }
    CFRelease(currentRef);
    self.lastMessage = self.lastMessage.length > 0 ? self.lastMessage : @"required RIFE frame failed";
    return nil;
}

- (BOOL)ensureH264SessionWithUnits:(const std::vector<SMNALUnit>&)units {
    std::vector<const uint8_t*> parameterSetPointers;
    std::vector<size_t> parameterSetSizes;
    for (const SMNALUnit& unit : units) {
        const uint8_t type = SMNALType(unit);
        if (type == 7 || type == 8) {
            parameterSetPointers.push_back(unit.data);
            parameterSetSizes.push_back(unit.length);
        }
    }
    if (parameterSetPointers.size() >= 2) {
        CMVideoFormatDescriptionRef description = nullptr;
        OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                                                                              parameterSetPointers.size(),
                                                                              parameterSetPointers.data(),
                                                                              parameterSetSizes.data(),
                                                                              4,
                                                                              &description);
        if (status == noErr && description != nullptr) {
            if (self.h264Session != nullptr) {
                VTDecompressionSessionInvalidate(self.h264Session);
                CFRelease(self.h264Session);
                self.h264Session = nullptr;
            }
            if (self.h264FormatDescription != nullptr) {
                CFRelease(self.h264FormatDescription);
            }
            self.h264FormatDescription = description;
        }
    }
    if (self.h264FormatDescription == nullptr && self.pendingCodecDescription.length > 0) {
        CMVideoFormatDescriptionRef description = SMH264DescriptionFromAVCC(self.pendingCodecDescription);
        if (description != nullptr) {
            self.h264FormatDescription = description;
            self.lastMessage = @"H.264 session configured from codecDescription";
        }
    }
    if (self.h264FormatDescription == nullptr) {
        return NO;
    }
    if (self.h264Session != nullptr) {
        return YES;
    }

    NSDictionary* attributes = @{
        (__bridge NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (__bridge NSString*)kCVPixelBufferMetalCompatibilityKey: @YES,
        (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    VTDecompressionOutputCallbackRecord callback{
        .decompressionOutputCallback = SMVTDecodeOutput,
        .decompressionOutputRefCon = nullptr,
    };
    OSStatus status = VTDecompressionSessionCreate(kCFAllocatorDefault,
                                                   self.h264FormatDescription,
                                                   nullptr,
                                                   (__bridge CFDictionaryRef)attributes,
                                                   &callback,
                                                   &_h264Session);
    if (status != noErr || self.h264Session == nullptr) {
        self.lastMessage = [NSString stringWithFormat:@"VideoToolbox H.264 session failed: %d", static_cast<int>(status)];
        return NO;
    }
    VTSessionSetProperty(self.h264Session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    return YES;
}

- (NSData*)processH264AnnexBChunk:(NSData*)chunkData {
    if (chunkData.length == 0) {
        return nil;
    }
    std::vector<SMNALUnit> units = SMFindAnnexBNALUnits(chunkData);
    if (units.empty()) {
        units = SMFindLengthPrefixedNALUnits(chunkData);
    }
    if (units.empty()) {
        self.lastMessage = [NSString stringWithFormat:@"H.264 NAL parse failed · %lu bytes", static_cast<unsigned long>(chunkData.length)];
        return nil;
    }
    if (![self ensureH264SessionWithUnits:units]) {
        self.lastMessage = @"Waiting for H.264 parameter sets";
        return nil;
    }

    NSMutableData* sampleBytes = [NSMutableData data];
    for (const SMNALUnit& unit : units) {
        const uint8_t type = SMNALType(unit);
        if (type == 7 || type == 8 || type == 9) {
            continue;
        }
        SMAppendLengthPrefixedNAL(sampleBytes, unit);
    }
    if (sampleBytes.length == 0) {
        self.lastMessage = @"H.264 metadata chunk received";
        return nil;
    }

    CMBlockBufferRef blockBuffer = nullptr;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                         nullptr,
                                                         sampleBytes.length,
                                                         kCFAllocatorDefault,
                                                         nullptr,
                                                         0,
                                                         sampleBytes.length,
                                                         0,
                                                         &blockBuffer);
    if (status == noErr) {
        status = CMBlockBufferReplaceDataBytes(sampleBytes.bytes, blockBuffer, 0, sampleBytes.length);
    }
    if (status != noErr || blockBuffer == nullptr) {
        if (blockBuffer != nullptr) {
            CFRelease(blockBuffer);
        }
        self.lastMessage = [NSString stringWithFormat:@"H.264 block buffer failed: %d", static_cast<int>(status)];
        return nil;
    }

    CMSampleBufferRef sampleBuffer = nullptr;
    const size_t sampleSize = sampleBytes.length;
    status = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                       blockBuffer,
                                       self.h264FormatDescription,
                                       1,
                                       0,
                                       nullptr,
                                       1,
                                       &sampleSize,
                                       &sampleBuffer);
    CFRelease(blockBuffer);
    if (status != noErr || sampleBuffer == nullptr) {
        if (sampleBuffer != nullptr) {
            CFRelease(sampleBuffer);
        }
        self.lastMessage = [NSString stringWithFormat:@"H.264 sample buffer failed: %d", static_cast<int>(status)];
        return nil;
    }

    CVPixelBufferRef decoded = nullptr;
    VTDecodeFrameFlags flags = 0;
    VTDecodeInfoFlags infoFlags = 0;
    const CFTimeInterval decodeStart = CACurrentMediaTime();
    status = VTDecompressionSessionDecodeFrame(self.h264Session,
                                               sampleBuffer,
                                               flags,
                                               &decoded,
                                               &infoFlags);
    VTDecompressionSessionWaitForAsynchronousFrames(self.h264Session);
    self.lastDecodeMs = (CACurrentMediaTime() - decodeStart) * 1000.0;
    CFRelease(sampleBuffer);
    if (status != noErr) {
        self.lastMessage = [NSString stringWithFormat:@"VideoToolbox H.264 decode failed: %d", static_cast<int>(status)];
        return nil;
    }
    if (decoded == nullptr) {
        self.lastMessage = @"Waiting for H.264 keyframe";
        return nil;
    }
    self.hardwareDecodedFrames += 1;
    NSData* output = [self processPixelBufferWithMetal:decoded];
    CVPixelBufferRelease(decoded);
    return output;
}

- (BOOL)ensureHEVCSessionWithUnits:(const std::vector<SMNALUnit>&)units {
    std::vector<const uint8_t*> parameterSetPointers;
    std::vector<size_t> parameterSetSizes;
    for (const SMNALUnit& unit : units) {
        const uint8_t type = SMHEVCNALType(unit);
        if (type == 32 || type == 33 || type == 34) {
            parameterSetPointers.push_back(unit.data);
            parameterSetSizes.push_back(unit.length);
        }
    }
    if (parameterSetPointers.size() >= 3) {
        CMVideoFormatDescriptionRef description = nullptr;
        OSStatus status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault,
                                                                              parameterSetPointers.size(),
                                                                              parameterSetPointers.data(),
                                                                              parameterSetSizes.data(),
                                                                              4,
                                                                              nullptr,
                                                                              &description);
        if (status == noErr && description != nullptr) {
            if (self.h264Session != nullptr) {
                VTDecompressionSessionInvalidate(self.h264Session);
                CFRelease(self.h264Session);
                self.h264Session = nullptr;
            }
            if (self.h264FormatDescription != nullptr) {
                CFRelease(self.h264FormatDescription);
            }
            self.h264FormatDescription = description;
        }
    }
    if (self.h264FormatDescription == nullptr && self.pendingCodecDescription.length > 0) {
        CMVideoFormatDescriptionRef description = SMHEVCDescriptionFromHVCC(self.pendingCodecDescription);
        if (description != nullptr) {
            self.h264FormatDescription = description;
            self.lastMessage = @"HEVC session configured from codecDescription";
        }
    }
    if (self.h264FormatDescription == nullptr) {
        return NO;
    }
    if (self.h264Session != nullptr) {
        return YES;
    }

    NSDictionary* attributes = @{
        (__bridge NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (__bridge NSString*)kCVPixelBufferMetalCompatibilityKey: @YES,
        (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    VTDecompressionOutputCallbackRecord callback{
        .decompressionOutputCallback = SMVTDecodeOutput,
        .decompressionOutputRefCon = nullptr,
    };
    OSStatus status = VTDecompressionSessionCreate(kCFAllocatorDefault,
                                                   self.h264FormatDescription,
                                                   nullptr,
                                                   (__bridge CFDictionaryRef)attributes,
                                                   &callback,
                                                   &_h264Session);
    if (status != noErr || self.h264Session == nullptr) {
        self.lastMessage = [NSString stringWithFormat:@"VideoToolbox HEVC session failed: %d", static_cast<int>(status)];
        return NO;
    }
    VTSessionSetProperty(self.h264Session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    return YES;
}

- (NSData*)processHEVCAnnexBChunk:(NSData*)chunkData {
    if (chunkData.length == 0) {
        return nil;
    }
    std::vector<SMNALUnit> units = SMFindAnnexBNALUnits(chunkData);
    if (units.empty()) {
        units = SMFindLengthPrefixedNALUnits(chunkData);
    }
    if (units.empty()) {
        self.lastMessage = [NSString stringWithFormat:@"HEVC NAL parse failed · %lu bytes", static_cast<unsigned long>(chunkData.length)];
        return nil;
    }
    if (![self ensureHEVCSessionWithUnits:units]) {
        self.lastMessage = @"Waiting for HEVC parameter sets";
        return nil;
    }

    NSMutableData* sampleBytes = [NSMutableData data];
    for (const SMNALUnit& unit : units) {
        const uint8_t type = SMHEVCNALType(unit);
        if (type == 32 || type == 33 || type == 34 || type == 35) {
            continue;
        }
        SMAppendLengthPrefixedNAL(sampleBytes, unit);
    }
    if (sampleBytes.length == 0) {
        self.lastMessage = @"HEVC metadata chunk received";
        return nil;
    }

    CMBlockBufferRef blockBuffer = nullptr;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                         nullptr,
                                                         sampleBytes.length,
                                                         kCFAllocatorDefault,
                                                         nullptr,
                                                         0,
                                                         sampleBytes.length,
                                                         0,
                                                         &blockBuffer);
    if (status == noErr) {
        status = CMBlockBufferReplaceDataBytes(sampleBytes.bytes, blockBuffer, 0, sampleBytes.length);
    }
    if (status != noErr || blockBuffer == nullptr) {
        if (blockBuffer != nullptr) {
            CFRelease(blockBuffer);
        }
        self.lastMessage = [NSString stringWithFormat:@"HEVC block buffer failed: %d", static_cast<int>(status)];
        return nil;
    }

    CMSampleBufferRef sampleBuffer = nullptr;
    const size_t sampleSize = sampleBytes.length;
    status = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                       blockBuffer,
                                       self.h264FormatDescription,
                                       1,
                                       0,
                                       nullptr,
                                       1,
                                       &sampleSize,
                                       &sampleBuffer);
    CFRelease(blockBuffer);
    if (status != noErr || sampleBuffer == nullptr) {
        if (sampleBuffer != nullptr) {
            CFRelease(sampleBuffer);
        }
        self.lastMessage = [NSString stringWithFormat:@"HEVC sample buffer failed: %d", static_cast<int>(status)];
        return nil;
    }

    CVPixelBufferRef decoded = nullptr;
    VTDecodeInfoFlags infoFlags = 0;
    const CFTimeInterval decodeStart = CACurrentMediaTime();
    status = VTDecompressionSessionDecodeFrame(self.h264Session,
                                               sampleBuffer,
                                               0,
                                               &decoded,
                                               &infoFlags);
    VTDecompressionSessionWaitForAsynchronousFrames(self.h264Session);
    self.lastDecodeMs = (CACurrentMediaTime() - decodeStart) * 1000.0;
    CFRelease(sampleBuffer);
    if (status != noErr) {
        self.lastMessage = [NSString stringWithFormat:@"VideoToolbox HEVC decode failed: %d", static_cast<int>(status)];
        return nil;
    }
    if (decoded == nullptr) {
        self.lastMessage = @"Waiting for HEVC keyframe";
        return nil;
    }
    self.hardwareDecodedFrames += 1;
    NSData* output = [self processPixelBufferWithMetal:decoded];
    CVPixelBufferRelease(decoded);
    return output;
}

- (void)updatePendingFrameMeta:(NSData*)payload {
    NSDictionary* object = nil;
    if (payload.length > 0) {
        object = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
    }
    if (![object isKindOfClass:NSDictionary.class]) {
        return;
    }
    NSString* type = [object[@"type"] isKindOfClass:NSString.class] ? object[@"type"] : nil;
    if ([type isEqualToString:@"playback_state"]) {
        const BOOL paused = [object[@"paused"] respondsToSelector:@selector(boolValue)] ? [object[@"paused"] boolValue] : NO;
        self.outputPlaybackPaused = paused;
        if (paused) {
            [self resetOutputQueueAndClock];
            self.lastMessage = @"playback paused";
        } else {
            [self.outputQueueCondition lock];
            self.outputPlaybackPaused = NO;
            self.outputSenderPrimed = NO;
            self.nextOutputSendTime = 0.0;
            [self.outputQueueCondition broadcast];
            [self.outputQueueCondition unlock];
            self.lastMessage = @"playback resumed";
        }
        return;
    }
    if ([type isEqualToString:@"bridge_config"]) {
        NSString* powerMode = [object[@"powerMode"] isKindOfClass:NSString.class] ? object[@"powerMode"] : @"adaptive";
        NSString* powerTier = [object[@"powerTier"] isKindOfClass:NSString.class] ? object[@"powerTier"] : @"均衡";
        NSString* rifeBackend = [object[@"rifeBackend"] isKindOfClass:NSString.class] ? object[@"rifeBackend"] : @"stellaria_sp4_a1p";
        const double targetFPS = [object[@"targetFPS"] respondsToSelector:@selector(doubleValue)] ? [object[@"targetFPS"] doubleValue] : 60.0;
        const double flowInputHeight = [object[@"flowInputHeight"] respondsToSelector:@selector(doubleValue)] ? [object[@"flowInputHeight"] doubleValue] : 540.0;
        const double gpuBudgetMs = [object[@"gpuBudgetMs"] respondsToSelector:@selector(doubleValue)] ? [object[@"gpuBudgetMs"] doubleValue] : 14.0;
        const double returnBitrateMbps = [object[@"returnBitrateMbps"] respondsToSelector:@selector(doubleValue)] ? [object[@"returnBitrateMbps"] doubleValue] : 60.0;
        self.pendingModelMode = @"rife";
        self.pendingPowerMode = [powerMode localizedCaseInsensitiveContainsString:@"unlimited"] ? @"unlimited" : @"adaptive";
        self.pendingPowerTier = powerTier;
        self.pendingRIFEBackend = rifeBackend.length > 0 ? rifeBackend : @"stellaria_sp4_a1p";
        self.pendingTargetFPS = MAX(24.0, MIN(240.0, targetFPS));
        self.pendingFlowInputHeight = MAX(180.0, MIN(2160.0, flowInputHeight));
        self.pendingGpuBudgetMs = MAX(4.0, MIN(40.0, gpuBudgetMs));
        self.pendingReturnBitrateMbps = MAX(12.0, MIN(120.0, returnBitrateMbps));
        self.pendingNoCpuReadback = [object[@"noCpuReadback"] respondsToSelector:@selector(boolValue)] ? [object[@"noCpuReadback"] boolValue] : YES;
        self.pendingHEVCMotionHints = [object[@"hevcMotionHints"] respondsToSelector:@selector(boolValue)] ? [object[@"hevcMotionHints"] boolValue] : YES;
        self.pendingROIMotionBlocks = [object[@"roiMotionBlocks"] respondsToSelector:@selector(boolValue)] ? [object[@"roiMotionBlocks"] boolValue] : NO;
        self.pendingDynamicMultiFrame = [object[@"dynamicMultiFrame"] respondsToSelector:@selector(boolValue)] ? [object[@"dynamicMultiFrame"] boolValue] : NO;
        if (_realtimeSession) {
            Stellaria::Motion::RealtimeVFIConfig config;
            config.inputSource = Stellaria::Motion::RealtimeInputSource::BrowserStream;
            if ([self.pendingRIFEBackend isEqualToString:@"stellaria_sp4_a1p"]) {
                config.backend = Stellaria::Motion::RealtimeRIFEBackend::StellariaSP4A1P;
            } else if ([self.pendingRIFEBackend isEqualToString:@"metal_int4_experimental"]) {
                config.backend = Stellaria::Motion::RealtimeRIFEBackend::MetalInt4Experimental;
            } else if ([self.pendingRIFEBackend isEqualToString:@"mpsgraph_fp32_debug"]) {
                config.backend = Stellaria::Motion::RealtimeRIFEBackend::MPSGraphFP32Debug;
            } else {
                config.backend = Stellaria::Motion::RealtimeRIFEBackend::MPSGraphFP16;
            }
            config.powerTier = SMRealtimeTier(SMPowerTierKindFromString(self.pendingPowerTier),
                                              [self.pendingPowerMode isEqualToString:@"unlimited"]);
            config.targetFPS = self.pendingTargetFPS;
            config.flowInputHeight = static_cast<uint32_t>(self.pendingFlowInputHeight);
            config.prerollSeconds = [self outputPrerollSecondsForTargetFPS:self.pendingTargetFPS];
            config.maxVisibleFrameGapMs = 16.67;
            config.maxPipelineLatencyMs = 16.67;
            _realtimeSession->Configure(config);
            _realtimeSession->NoteBrowserStreamState("browser stream capture");
        }
        self.lastMessage = @"browser stream config updated";
        return;
    }
    if (![type isEqualToString:@"frame_meta"]) {
        return;
    }
    NSString* payloadKind = [object[@"payloadKind"] isKindOfClass:NSString.class] ? object[@"payloadKind"] : @"webcodecs_video_chunk";
    if (![payloadKind isEqualToString:@"webcodecs_video_chunk"]) {
        payloadKind = @"webcodecs_video_chunk";
    }
    NSString* codec = [object[@"codec"] isKindOfClass:NSString.class] ? object[@"codec"] : @"";
    NSString* payloadCodec = [object[@"payloadCodec"] isKindOfClass:NSString.class] ? object[@"payloadCodec"] : @"";
    NSString* returnCodec = [object[@"returnCodec"] isKindOfClass:NSString.class] ? object[@"returnCodec"] : @"h264";
    NSString* powerMode = [object[@"powerMode"] isKindOfClass:NSString.class] ? object[@"powerMode"] : @"adaptive";
    NSString* powerTier = [object[@"powerTier"] isKindOfClass:NSString.class] ? object[@"powerTier"] : @"";
    NSString* rifeBackend = [object[@"rifeBackend"] isKindOfClass:NSString.class] ? object[@"rifeBackend"] : self.pendingRIFEBackend ?: @"mpsgraph_fp16_target";
    NSString* chunkType = [object[@"chunkType"] isKindOfClass:NSString.class] ? object[@"chunkType"] : @"";
    NSArray* codecDescriptionArray = [object[@"codecDescription"] isKindOfClass:NSArray.class] ? object[@"codecDescription"] : nil;
    const uint64_t frameId = [object[@"frameId"] respondsToSelector:@selector(unsignedLongLongValue)] ? [object[@"frameId"] unsignedLongLongValue] : 0;
    const double targetFPS = [object[@"targetFPS"] respondsToSelector:@selector(doubleValue)] ? [object[@"targetFPS"] doubleValue] : 60.0;
    const double pts = [object[@"timestamp"] respondsToSelector:@selector(doubleValue)] ? [object[@"timestamp"] doubleValue] : 0.0;
    const double duration = [object[@"duration"] respondsToSelector:@selector(doubleValue)] ? [object[@"duration"] doubleValue] : 0.0;
    const uint32_t inputWidth = [object[@"width"] respondsToSelector:@selector(unsignedIntValue)] ? [object[@"width"] unsignedIntValue] : 0;
    const uint32_t inputHeight = [object[@"height"] respondsToSelector:@selector(unsignedIntValue)] ? [object[@"height"] unsignedIntValue] : 0;
    const double flowInputHeight = [object[@"flowInputHeight"] respondsToSelector:@selector(doubleValue)] ? [object[@"flowInputHeight"] doubleValue] : 540.0;
    const double gpuBudgetMs = [object[@"gpuBudgetMs"] respondsToSelector:@selector(doubleValue)] ? [object[@"gpuBudgetMs"] doubleValue] : 14.0;
    const double returnBitrateMbps = [object[@"returnBitrateMbps"] respondsToSelector:@selector(doubleValue)] ? [object[@"returnBitrateMbps"] doubleValue] : 60.0;
    const BOOL noCpuReadback = [object[@"noCpuReadback"] respondsToSelector:@selector(boolValue)] ? [object[@"noCpuReadback"] boolValue] : YES;
    const BOOL forceReturnKeyframe = [object[@"forceReturnKeyframe"] respondsToSelector:@selector(boolValue)] ? [object[@"forceReturnKeyframe"] boolValue] : NO;
    const BOOL hevcMotionHints = [object[@"hevcMotionHints"] respondsToSelector:@selector(boolValue)] ? [object[@"hevcMotionHints"] boolValue] : YES;
    const BOOL roiMotionBlocks = [object[@"roiMotionBlocks"] respondsToSelector:@selector(boolValue)] ? [object[@"roiMotionBlocks"] boolValue] : NO;
    const BOOL dynamicMultiFrame = [object[@"dynamicMultiFrame"] respondsToSelector:@selector(boolValue)] ? [object[@"dynamicMultiFrame"] boolValue] : NO;
    if (payloadCodec.length > 0 && self.activePayloadCodec.length > 0 && ![payloadCodec isEqualToString:self.activePayloadCodec]) {
        [self resetVideoDecoder];
        self.pendingCodecDescription = nil;
    }
    if (inputWidth > 0 && inputHeight > 0 &&
        self.activeInputWidth > 0 && self.activeInputHeight > 0 &&
        (self.activeInputWidth != inputWidth || self.activeInputHeight != inputHeight)) {
        [self resetVideoDecoder];
        self.pendingCodecDescription = nil;
        self.pendingForceReturnKeyframe = YES;
        self.lastMessage = @"input geometry changed · decoder reset";
    }
    self.pendingPayloadKind = payloadKind;
    self.pendingCodec = codec;
    self.pendingPayloadCodec = payloadCodec;
    if (codecDescriptionArray.count > 0) {
        NSMutableData* codecDescription = [NSMutableData dataWithCapacity:codecDescriptionArray.count];
        for (id value in codecDescriptionArray) {
            if ([value respondsToSelector:@selector(unsignedCharValue)]) {
                uint8_t byte = [value unsignedCharValue];
                [codecDescription appendBytes:&byte length:1];
            }
        }
        if (codecDescription.length > 0) {
            self.pendingCodecDescription = codecDescription;
        }
    }
    self.pendingReturnCodec = returnCodec;
    self.pendingModelMode = @"rife";
    self.pendingPowerMode = [powerMode localizedCaseInsensitiveContainsString:@"unlimited"] ? @"unlimited" : @"adaptive";
    self.pendingPowerTier = powerTier;
    self.pendingRIFEBackend = rifeBackend.length > 0 ? rifeBackend : @"mpsgraph_fp16_target";
    self.pendingChunkType = chunkType;
    self.pendingFrameId = frameId;
    self.pendingTargetFPS = MAX(24.0, MIN(240.0, targetFPS));
    self.pendingInputWidth = inputWidth;
    self.pendingInputHeight = inputHeight;
    self.pendingInputPTS = pts;
    self.pendingInputDuration = duration;
    self.pendingFlowInputHeight = MAX(180.0, MIN(2160.0, flowInputHeight));
    self.pendingGpuBudgetMs = MAX(4.0, MIN(40.0, gpuBudgetMs));
    self.pendingReturnBitrateMbps = MAX(12.0, MIN(120.0, returnBitrateMbps));
    self.pendingForceReturnKeyframe = self.pendingForceReturnKeyframe || forceReturnKeyframe;
    self.pendingHEVCMotionHints = hevcMotionHints;
    self.pendingROIMotionBlocks = roiMotionBlocks;
    self.pendingDynamicMultiFrame = dynamicMultiFrame;
    self.pendingNoCpuReadback = noCpuReadback;
    if (payloadCodec.length > 0) {
        self.activePayloadCodec = payloadCodec;
    }
    if (inputWidth > 0 && inputHeight > 0) {
        self.activeInputWidth = inputWidth;
        self.activeInputHeight = inputHeight;
    }
}

- (BOOL)updatePendingFrameMetaFromBinaryFrame:(NSData*)frame payload:(NSData**)payloadOut {
    if (frame.length < kSMBinaryFrameHeaderBytesV1 || payloadOut == nullptr) {
        return NO;
    }
    const uint8_t* bytes = static_cast<const uint8_t*>(frame.bytes);
    const uint16_t version = SMReadLE16(bytes, 4);
    if (SMReadLE32(bytes, 0) != kSMBinaryFrameMagic ||
        (version != 1 && version != kSMBinaryFrameVersion)) {
        return NO;
    }
    const size_t headerBytes = version >= 2 ? kSMBinaryFrameHeaderBytes : kSMBinaryFrameHeaderBytesV1;
    if (frame.length < headerBytes) {
        return NO;
    }

    const uint16_t flags = SMReadLE16(bytes, 6);
    const uint64_t frameId = SMReadLE64(bytes, 8);
    const double pts = SMReadLEDouble(bytes, 16);
    const double duration = SMReadLEDouble(bytes, 24);
    const uint32_t width = SMReadLE32(bytes, 32);
    const uint32_t height = SMReadLE32(bytes, 36);
    const uint32_t codec = SMReadLE32(bytes, 40);
    const uint32_t payloadBytes = SMReadLE32(bytes, 44);
    const double targetFPS = SMReadLEDouble(bytes, 48);
    const double flowInputHeight = SMReadLEDouble(bytes, 56);
    const double gpuBudgetMs = SMReadLEDouble(bytes, 64);
    const uint32_t powerTier = SMReadLE32(bytes, 72);
    const uint32_t codecDescriptionBytes = SMReadLE32(bytes, 76);
    const uint32_t returnCodec = SMReadLE32(bytes, 80);
    const double returnBitrateMbps = version >= 2 ? SMReadLEDouble(bytes, 84) : 60.0;
    const uint64_t bodyOffset = static_cast<uint64_t>(headerBytes) + static_cast<uint64_t>(codecDescriptionBytes);
    const uint64_t requiredLength = bodyOffset + static_cast<uint64_t>(payloadBytes);
    if (requiredLength > frame.length || payloadBytes == 0) {
        self.lastMessage = @"binary frame header invalid";
        *payloadOut = [NSData data];
        return YES;
    }

    NSString* payloadCodec = SMCodecStringFromBinaryId(codec);
    if (payloadCodec.length > 0 && self.activePayloadCodec.length > 0 && ![payloadCodec isEqualToString:self.activePayloadCodec]) {
        [self resetVideoDecoder];
        self.pendingCodecDescription = nil;
    }
    if (width > 0 && height > 0 &&
        self.activeInputWidth > 0 && self.activeInputHeight > 0 &&
        (self.activeInputWidth != width || self.activeInputHeight != height)) {
        [self resetVideoDecoder];
        self.pendingCodecDescription = nil;
        self.pendingForceReturnKeyframe = YES;
        self.lastMessage = @"input geometry changed · decoder reset";
    }
    self.pendingPayloadKind = @"webcodecs_video_chunk";
    self.pendingCodec = payloadCodec;
    self.pendingPayloadCodec = payloadCodec;
    self.pendingReturnCodec = SMReturnCodecStringFromBinaryId(returnCodec);
    self.pendingModelMode = @"rife";
    self.pendingPowerMode = (flags & kSMBinaryFlagUnlimited) ? @"unlimited" : @"adaptive";
    self.pendingPowerTier = SMPowerTierStringFromBinaryId(powerTier);
    self.pendingChunkType = (flags & kSMBinaryFlagKey) ? @"key" : @"delta";
    self.pendingFrameId = frameId;
    self.pendingTargetFPS = MAX(24.0, MIN(240.0, targetFPS > 0.0 ? targetFPS : 60.0));
    self.pendingInputWidth = width;
    self.pendingInputHeight = height;
    self.pendingInputPTS = pts;
    self.pendingInputDuration = duration;
    self.pendingFlowInputHeight = MAX(180.0, MIN(2160.0, flowInputHeight > 0.0 ? flowInputHeight : 540.0));
    self.pendingGpuBudgetMs = MAX(4.0, MIN(40.0, gpuBudgetMs > 0.0 ? gpuBudgetMs : 14.0));
    self.pendingReturnBitrateMbps = MAX(12.0, MIN(120.0, returnBitrateMbps > 0.0 ? returnBitrateMbps : 60.0));
    self.pendingForceReturnKeyframe = self.pendingForceReturnKeyframe || ((flags & kSMBinaryFlagForceReturnKey) != 0);
    self.pendingNoCpuReadback = (flags & kSMBinaryFlagNoCPUReadback) != 0;
    self.pendingHEVCMotionHints = (flags & kSMBinaryFlagHEVCMotionHints) != 0;
    self.pendingROIMotionBlocks = (flags & kSMBinaryFlagROIMotionBlocks) != 0;
    self.pendingDynamicMultiFrame = (flags & kSMBinaryFlagDynamicMultiFrame) != 0;
    if (codecDescriptionBytes > 0) {
        self.pendingCodecDescription = [frame subdataWithRange:NSMakeRange(headerBytes, codecDescriptionBytes)];
    }
    self.activePayloadCodec = payloadCodec;
    if (width > 0 && height > 0) {
        self.activeInputWidth = width;
        self.activeInputHeight = height;
    }
    *payloadOut = [frame subdataWithRange:NSMakeRange(static_cast<NSUInteger>(bodyOffset), payloadBytes)];
    return YES;
}

- (id<MTLTexture>)textureFromJPEGData:(NSData*)data width:(NSUInteger*)widthOut height:(NSUInteger*)heightOut {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
    if (source == nullptr) {
        return nil;
    }
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
    CFRelease(source);
    if (image == nullptr) {
        return nil;
    }

    const NSUInteger width = CGImageGetWidth(image);
    const NSUInteger height = CGImageGetHeight(image);
    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:width
                                                                                         height:height
                                                                                      mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [self.device newTextureWithDescriptor:descriptor];
    if (texture != nil) {
        CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        const NSUInteger bytesPerRow = width * 4;
        NSMutableData* bgra = [NSMutableData dataWithLength:bytesPerRow * height];
        CGContextRef context = CGBitmapContextCreate(bgra.mutableBytes,
                                                     width,
                                                     height,
                                                     8,
                                                     bytesPerRow,
                                                     colorSpace,
                                                     static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little) |
                                                         static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedFirst));
        if (colorSpace != nullptr) {
            CGColorSpaceRelease(colorSpace);
        }
        if (context == nullptr) {
            CGImageRelease(image);
            return nil;
        }
        CGContextDrawImage(context, CGRectMake(0.0, 0.0, width, height), image);
        [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                    mipmapLevel:0
                      withBytes:bgra.bytes
                    bytesPerRow:bytesPerRow];
        CGContextRelease(context);
        if (widthOut != nullptr) {
            *widthOut = width;
        }
        if (heightOut != nullptr) {
            *heightOut = height;
        }
    }
    CGImageRelease(image);
    return texture;
}

- (NSData*)jpegDataFromTexture:(id<MTLTexture>)texture width:(NSUInteger)width height:(NSUInteger)height {
    if (texture == nil || width == 0 || height == 0) {
        return nil;
    }
    const NSUInteger bytesPerRow = width * 4;
    NSMutableData* pixels = [NSMutableData dataWithLength:bytesPerRow * height];
    [texture getBytes:pixels.mutableBytes
          bytesPerRow:bytesPerRow
           fromRegion:MTLRegionMake2D(0, 0, width, height)
          mipmapLevel:0];
    NSMutableData* rgba = [NSMutableData dataWithLength:bytesPerRow * height];
    const uint8_t* src = static_cast<const uint8_t*>(pixels.bytes);
    uint8_t* dst = static_cast<uint8_t*>(rgba.mutableBytes);
    const NSUInteger pixelCount = width * height;
    for (NSUInteger i = 0; i < pixelCount; ++i) {
        const NSUInteger p = i * 4;
        dst[p + 0] = src[p + 2];
        dst[p + 1] = src[p + 1];
        dst[p + 2] = src[p + 0];
        dst[p + 3] = 255;
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)rgba);
    const CGBitmapInfo bitmapInfo = static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Big) |
                                    static_cast<CGBitmapInfo>(kCGImageAlphaNoneSkipLast);
    CGImageRef image = CGImageCreate(width,
                                     height,
                                     8,
                                     32,
                                     bytesPerRow,
                                     colorSpace,
                                     bitmapInfo,
                                     provider,
                                     nullptr,
                                     false,
                                     kCGRenderingIntentDefault);
    NSMutableData* jpeg = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg,
                                                                        CFSTR("public.jpeg"),
                                                                        1,
                                                                        nullptr);
    if (destination != nullptr && image != nullptr) {
        NSDictionary* options = @{(__bridge NSString*)kCGImageDestinationLossyCompressionQuality: @0.92};
        CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)options);
        CGImageDestinationFinalize(destination);
    }
    if (destination != nullptr) {
        CFRelease(destination);
    }
    if (image != nullptr) {
        CGImageRelease(image);
    }
    if (provider != nullptr) {
        CGDataProviderRelease(provider);
    }
    if (colorSpace != nullptr) {
        CGColorSpaceRelease(colorSpace);
    }
    return jpeg.length > 0 ? jpeg : nil;
}

- (NSData*)processJPEGFrameWithMetal:(NSData*)jpegData {
    if (![self ensureMetalReady]) {
        return jpegData;
    }
    self.lastOutputVideoChunk = nil;
    NSUInteger width = 0;
    NSUInteger height = 0;
    id<MTLTexture> current = [self textureFromJPEGData:jpegData width:&width height:&height];
    if (current == nil || width == 0 || height == 0) {
        self.lastMessage = @"JPEG decode failed";
        return nil;
    }
    if (self.previousTexture == nil ||
        self.previousTexture.width != width ||
        self.previousTexture.height != height) {
        self.previousTexture = current;
        self.lastGpuMs = 0.0;
        SMEncodedVideoChunk* encoded = [self videoChunkFromTexture:current width:width height:height];
        if (encoded.data.length > 0) {
            self.lastOutputVideoChunk = encoded;
            return encoded.data;
        }
        return self.pendingNoCpuReadback ? nil : jpegData;
    }

    if (self.outputTexture == nil || self.outputTexture.width != width || self.outputTexture.height != height) {
        MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                              width:width
                                                                                             height:height
                                                                                          mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        descriptor.storageMode = MTLStorageModeShared;
        self.outputTexture = [self.device newTextureWithDescriptor:descriptor];
    }

    if ([self processTexturesWithRIFEPrevious:self.previousTexture current:current output:self.outputTexture width:width height:height]) {
        self.previousTexture = current;
        SMEncodedVideoChunk* encoded = [self videoChunkFromTexture:self.outputTexture width:width height:height];
        if (encoded.data.length > 0) {
            self.lastOutputVideoChunk = encoded;
            return encoded.data;
        }
        if (self.pendingNoCpuReadback) {
            return nil;
        }
        NSData* output = [self jpegDataFromTexture:self.outputTexture width:width height:height];
        return output ?: jpegData;
    }
    self.lastMessage = self.lastMessage.length > 0 ? self.lastMessage : @"required RIFE JPEG frame failed";
    return nil;
}

- (void)emit {
    SMBrowserStreamBridgeProgress handler = self.progress;
    if (handler == nil) {
        return;
    }
    NSDictionary<NSString*, id>* snapshot = [self snapshot];
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(snapshot);
    });
}

- (void)serverLoop {
    @autoreleasepool {
        while (self.running) {
            sockaddr_in clientAddr {};
            socklen_t len = sizeof(clientAddr);
            int client = accept(self.listenSocket, reinterpret_cast<sockaddr*>(&clientAddr), &len);
            if (client < 0) {
                if (self.running) {
                    self.lastMessage = [NSString stringWithFormat:@"accept failed: %d", errno];
                    [self emit];
                }
                continue;
            }
            [self handleClient:client];
            close(client);
        }
    }
}

- (BOOL)performHandshake:(int)client {
    NSMutableData* requestData = [NSMutableData data];
    uint8_t buffer[512];
    while (requestData.length < 8192) {
        ssize_t n = recv(client, buffer, sizeof(buffer), 0);
        if (n <= 0) {
            return NO;
        }
        [requestData appendBytes:buffer length:static_cast<NSUInteger>(n)];
        NSString* request = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding];
        if ([request containsString:@"\r\n\r\n"]) {
            NSString* key = SMHeaderValue(request, @"Sec-WebSocket-Key");
            if (key.length == 0) {
                return NO;
            }
            NSString* acceptKey = SMAcceptKey(key);
            NSString* response = [NSString stringWithFormat:
                @"HTTP/1.1 101 Switching Protocols\r\n"
                 "Upgrade: websocket\r\n"
                 "Connection: Upgrade\r\n"
                 "Sec-WebSocket-Accept: %@\r\n"
                 "Access-Control-Allow-Origin: *\r\n\r\n", acceptKey];
            NSData* responseData = [response dataUsingEncoding:NSASCIIStringEncoding];
            return SMSendAll(client, static_cast<const uint8_t*>(responseData.bytes), responseData.length);
        }
    }
    return NO;
}

- (void)handleClient:(int)client {
    if (![self performHandshake:client]) {
        self.lastMessage = @"websocket handshake failed";
        [self emit];
        return;
    }

    self.clientConnected = YES;
    self.lastMessage = @"browser stream connected";
    [self emit];
    [self startOutputSenderForClient:client];
    [self.webSocketSendLock lock];
    SMSendTextFrame(client, @"{\"type\":\"bridge_status\",\"connected\":true}");
    [self.webSocketSendLock unlock];

    while (self.running) {
        uint8_t header[2] {};
        if (!SMReadExact(client, header, sizeof(header))) {
            break;
        }
        const uint8_t opcode = header[0] & 0x0f;
        const bool masked = (header[1] & 0x80) != 0;
        uint64_t length = header[1] & 0x7f;
        if (length == 126) {
            uint8_t ext[2] {};
            if (!SMReadExact(client, ext, sizeof(ext))) {
                break;
            }
            length = (static_cast<uint64_t>(ext[0]) << 8) | ext[1];
        } else if (length == 127) {
            uint8_t ext[8] {};
            if (!SMReadExact(client, ext, sizeof(ext))) {
                break;
            }
            length = 0;
            for (uint8_t byte : ext) {
                length = (length << 8) | byte;
            }
        }
        if (length > kMaxPayloadBytes) {
            self.lastMessage = @"payload too large";
            break;
        }

        uint8_t mask[4] {};
        if (masked && !SMReadExact(client, mask, sizeof(mask))) {
            break;
        }
        NSMutableData* payload = [NSMutableData dataWithLength:static_cast<NSUInteger>(length)];
        if (length > 0 && !SMReadExact(client, static_cast<uint8_t*>(payload.mutableBytes), static_cast<size_t>(length))) {
            break;
        }
        if (masked) {
            uint8_t* bytes = static_cast<uint8_t*>(payload.mutableBytes);
            for (NSUInteger i = 0; i < payload.length; ++i) {
                bytes[i] ^= mask[i & 3U];
            }
        }

        if (opcode == 0x8) {
            break;
        }
        if (opcode == 0x1) {
            self.textMessages += 1;
            [self updatePendingFrameMeta:payload];
            if (self.lastMessage.length == 0) {
                self.lastMessage = @"metadata received";
            }
        } else if (opcode == 0x2) {
            [self trimOutputQueueForInputBackpressure];
            if (self.outputSenderStop) {
                break;
            }
            if (self.outputPlaybackPaused) {
                self.lastMessage = @"frame ignored while paused";
                continue;
            }
            NSData* framePayload = payload;
            const BOOL binaryFramed = [self updatePendingFrameMetaFromBinaryFrame:payload payload:&framePayload];
            if (binaryFramed && framePayload.length == 0) {
                self.lastMessage = @"binary frame payload missing";
                continue;
            }
            self.receivedFrames += 1;
            self.receivedBytes += framePayload.length;
            self.pendingPayloadBytes = framePayload.length;
            [self updateInputClock];
            self.pendingTargetFPS = SMStableTargetFPSForSourceFPS(self.estimatedSourceFPS > 1.0 ? self.estimatedSourceFPS : self.pendingTargetFPS * 0.5);
            const CFTimeInterval nativeFrameStart = CACurrentMediaTime();
            NSData* processed = nil;
            if ([self.pendingPayloadKind isEqualToString:@"webcodecs_video_chunk"]) {
                if ([self.pendingPayloadCodec isEqualToString:@"hevc"]) {
                    processed = [self processHEVCAnnexBChunk:framePayload];
                } else if ([self.pendingPayloadCodec isEqualToString:@"h264"] || self.pendingPayloadCodec.length == 0) {
                    processed = [self processH264AnnexBChunk:framePayload];
                } else {
                    self.lastMessage = [NSString stringWithFormat:@"%@ input decode not implemented", self.pendingPayloadCodec ?: @"compressed"];
                }
                if (processed != nil) {
                    self.lastMessage = @"hardware video chunk processed";
                }
            } else {
                self.lastMessage = @"browser input must be hardware video chunk";
            }
            self.pendingPayloadKind = nil;
            self.pendingCodec = nil;
            self.pendingPayloadCodec = nil;
            self.pendingModelMode = nil;
            self.lastNativeFrameMs = (CACurrentMediaTime() - nativeFrameStart) * 1000.0;
            if (processed != nil) {
                self.processedFrames += 1;
                self.lastMessage = @"frame processed";
                const double metaFPS = self.pendingTargetFPS;
                NSArray<SMProcessedOutputFrame*>* outputFrames = self.lastOutputFrames.count > 0
                    ? [self.lastOutputFrames copy]
                    : nil;
                if (outputFrames.count == 0) {
                    SMProcessedOutputFrame* frame = [SMProcessedOutputFrame new];
                    frame.payload = processed;
                    frame.chunk = self.lastOutputVideoChunk;
                    frame.width = self.outputEncodeWidth;
                    frame.height = self.outputEncodeHeight;
                    frame.subIndex = 1;
                    frame.subCount = 2;
                    frame.frameId = self.pendingFrameId;
                    frame.targetFPS = metaFPS;
                    frame.durationUs = llround(1000000.0 / MAX(24.0, MIN(240.0, metaFPS > 0.0 ? metaFPS : 60.0)));
                    frame.gpuMs = self.lastGpuMs;
                    frame.processedFrames = self.processedFrames;
                    frame.receivedFrames = self.receivedFrames;
                    outputFrames = @[frame];
                }
                NSArray<SMProcessedOutputFrame*>* stableFrames = [self stableOutputFramesFromFrames:outputFrames targetFPS:metaFPS];
                [self enqueueOutputFrames:stableFrames targetFPS:metaFPS];
            } else {
                NSString* detail = self.lastMessage.length > 0 ? self.lastMessage : @"unknown";
                self.lastMessage = [NSString stringWithFormat:@"frame process failed: %@", detail];
            }
        }

        const CFTimeInterval statusNow = CACurrentMediaTime();
        if (statusNow - self.lastSocketStatusSentAt > 0.5) {
            self.lastSocketStatusSentAt = statusNow;
            NSDictionary<NSString*, id>* snapshot = [self snapshot];
            NSData* json = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
            NSString* text = json != nil ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"{\"type\":\"bridge_status\"}";
            [self.webSocketSendLock lock];
            const BOOL sentStatus = SMSendTextFrame(client, [NSString stringWithFormat:@"{\"type\":\"bridge_status\",\"snapshot\":%@}", text]);
            [self.webSocketSendLock unlock];
            if (!sentStatus) {
                break;
            }
        }
        [self emit];
    }

    [self stopOutputSender];
    self.clientConnected = NO;
    self.lastMessage = @"browser stream disconnected";
    [self emit];
}

@end
