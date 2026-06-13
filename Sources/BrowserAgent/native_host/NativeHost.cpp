#include "Core/BrowserProtocol.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>

using Stellaria::Motion::BrowserVideoState;
using Stellaria::Motion::IsDrmOrProtectedSource;
using Stellaria::Motion::ParseBrowserVideoState;
using Stellaria::Motion::SerializeBrowserVideoState;

namespace {

bool ReadMessage(std::string& payload) {
    std::array<unsigned char, 4> lengthBytes{};
    if (!std::cin.read(reinterpret_cast<char*>(lengthBytes.data()), 4)) {
        return false;
    }

    const uint32_t length = static_cast<uint32_t>(lengthBytes[0]) |
                            (static_cast<uint32_t>(lengthBytes[1]) << 8U) |
                            (static_cast<uint32_t>(lengthBytes[2]) << 16U) |
                            (static_cast<uint32_t>(lengthBytes[3]) << 24U);
    payload.assign(length, '\0');
    return static_cast<bool>(std::cin.read(payload.data(), length));
}

void WriteMessage(const std::string& payload) {
    const uint32_t length = static_cast<uint32_t>(payload.size());
    const std::array<unsigned char, 4> lengthBytes{
        static_cast<unsigned char>(length & 0xffU),
        static_cast<unsigned char>((length >> 8U) & 0xffU),
        static_cast<unsigned char>((length >> 16U) & 0xffU),
        static_cast<unsigned char>((length >> 24U) & 0xffU)};
    std::cout.write(reinterpret_cast<const char*>(lengthBytes.data()), 4);
    std::cout.write(payload.data(), static_cast<std::streamsize>(payload.size()));
    std::cout.flush();
}

std::filesystem::path StateFilePath() {
    const char* home = std::getenv("HOME");
    std::filesystem::path base = home != nullptr ? std::filesystem::path(home) : std::filesystem::temp_directory_path();
    return base / "Library" / "Application Support" / "Stellaria Motion" / "browser_state.json";
}

std::filesystem::path OnlineStatusFilePath() {
    const char* home = std::getenv("HOME");
    std::filesystem::path base = home != nullptr ? std::filesystem::path(home) : std::filesystem::temp_directory_path();
    return base / "Library" / "Application Support" / "Stellaria Motion" / "online_status.json";
}

void PersistLatestState(const std::string& payload) {
    const auto path = StateFilePath();
    std::error_code ec;
    std::filesystem::create_directories(path.parent_path(), ec);
    if (ec) {
        return;
    }
    std::ofstream out(path, std::ios::trunc);
    out << payload;
}

std::string ReadOnlineStatus() {
    std::ifstream in(OnlineStatusFilePath());
    if (!in) {
        return "{\"running\":false,\"state\":\"idle\"}";
    }
    std::string payload((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    return payload.empty() ? "{\"running\":false,\"state\":\"idle\"}" : payload;
}

std::string AttachOnlineStatus(std::string payload) {
    if (payload.empty() || payload.back() != '}') {
        return payload;
    }
    payload.pop_back();
    payload += ",\"online\":";
    payload += ReadOnlineStatus();
    payload += "}";
    return payload;
}

} // namespace

int main() {
    std::ios::sync_with_stdio(false);

    std::string payload;
    while (ReadMessage(payload)) {
        auto state = ParseBrowserVideoState(payload);
        if (!state.has_value()) {
            WriteMessage("{\"type\":\"error\",\"reason\":\"invalid video_state payload\"}");
            continue;
        }

        BrowserVideoState reply = *state;
        reply.protectedContent = IsDrmOrProtectedSource(reply);
        const std::string serialized = AttachOnlineStatus(SerializeBrowserVideoState(reply));
        PersistLatestState(serialized);
        WriteMessage(serialized);
    }

    return 0;
}
