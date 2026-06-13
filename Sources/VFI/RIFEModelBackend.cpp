#include "VFI/RIFEModelBackend.h"

#include <algorithm>
#include <fstream>
#include <sstream>

namespace Stellaria::Motion {

namespace {

uint64_t ReadLE64(const unsigned char bytes[8]) {
    uint64_t value = 0;
    for (int i = 7; i >= 0; --i) {
        value = (value << 8) | bytes[i];
    }
    return value;
}

uint32_t CountTensorEntries(const std::string& header) {
    uint32_t count = 0;
    size_t cursor = 0;
    while ((cursor = header.find("\"dtype\"", cursor)) != std::string::npos) {
        ++count;
        cursor += 7;
    }
    return count;
}

} // namespace

RIFEModelBackend::RIFEModelBackend(std::filesystem::path modelPath)
    : modelPath_(std::move(modelPath)) {
    InspectSafetensors();
}

std::string RIFEModelBackend::Name() const {
    return ready_ ? "RIFEModelBackend" : "RIFEModelBackend(unavailable)";
}

bool RIFEModelBackend::IsReady() const {
    return ready_;
}

std::string RIFEModelBackend::Diagnostics() const {
    return diagnostics_;
}

void RIFEModelBackend::EnqueueFlowInference(const VFIJob&) {
    // First-stage model backend: asset validation and graph ownership are live;
    // actual MPSGraph/Core ML/Metal command encoding lands behind this contract.
}

void RIFEModelBackend::InspectSafetensors() {
    ready_ = false;
    tensorCount_ = 0;
    modelBytes_ = 0;

    std::error_code ec;
    if (!std::filesystem::exists(modelPath_, ec)) {
        diagnostics_ = "RIFE safetensors missing: " + modelPath_.string();
        return;
    }
    modelBytes_ = static_cast<uint64_t>(std::filesystem::file_size(modelPath_, ec));
    if (ec || modelBytes_ < 16) {
        diagnostics_ = "RIFE safetensors unreadable";
        return;
    }

    std::ifstream input(modelPath_, std::ios::binary);
    unsigned char lengthBytes[8] {};
    input.read(reinterpret_cast<char*>(lengthBytes), sizeof(lengthBytes));
    if (!input) {
        diagnostics_ = "RIFE safetensors header read failed";
        return;
    }

    const uint64_t headerBytes = ReadLE64(lengthBytes);
    if (headerBytes == 0 || headerBytes > modelBytes_ - sizeof(lengthBytes) || headerBytes > 64 * 1024 * 1024) {
        diagnostics_ = "RIFE safetensors header length invalid";
        return;
    }

    std::string header(static_cast<size_t>(headerBytes), '\0');
    input.read(header.data(), static_cast<std::streamsize>(header.size()));
    if (!input) {
        diagnostics_ = "RIFE safetensors header payload read failed";
        return;
    }

    tensorCount_ = CountTensorEntries(header);
    const bool hasRIFEBlocks = header.find("\"block0.") != std::string::npos &&
                               header.find("\"block3.") != std::string::npos;
    const bool hasFloat32Weights = header.find("\"dtype\":\"F32\"") != std::string::npos;
    ready_ = tensorCount_ > 0 && hasRIFEBlocks && hasFloat32Weights;

    std::ostringstream out;
    out << "safetensors=" << modelPath_.filename().string()
        << " tensors=" << tensorCount_
        << " bytes=" << modelBytes_
        << " dtype=" << (hasFloat32Weights ? "F32" : "unknown")
        << " blocks=" << (hasRIFEBlocks ? "rife" : "unknown");
    diagnostics_ = out.str();
}

} // namespace Stellaria::Motion
