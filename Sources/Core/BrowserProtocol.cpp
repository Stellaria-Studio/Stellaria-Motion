#include "Core/BrowserProtocol.h"

#include <charconv>
#include <sstream>
#include <string_view>

namespace Stellaria::Motion {
namespace {

std::string EscapeJson(std::string_view value) {
    std::string out;
    out.reserve(value.size() + 8);
    for (const char ch : value) {
        switch (ch) {
            case '\\': out += "\\\\"; break;
            case '"': out += "\\\""; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default: out += ch; break;
        }
    }
    return out;
}

std::optional<std::string> ExtractString(const std::string& json, std::string_view key) {
    const std::string needle = "\"" + std::string(key) + "\"";
    size_t pos = json.find(needle);
    if (pos == std::string::npos) {
        return std::nullopt;
    }
    pos = json.find(':', pos);
    if (pos == std::string::npos) {
        return std::nullopt;
    }
    pos = json.find('"', pos);
    if (pos == std::string::npos) {
        return std::nullopt;
    }
    ++pos;

    std::string value;
    bool escape = false;
    for (; pos < json.size(); ++pos) {
        const char ch = json[pos];
        if (escape) {
            value += ch;
            escape = false;
            continue;
        }
        if (ch == '\\') {
            escape = true;
            continue;
        }
        if (ch == '"') {
            return value;
        }
        value += ch;
    }

    return std::nullopt;
}

template <typename T>
std::optional<T> ExtractNumber(const std::string& json, std::string_view key) {
    const std::string needle = "\"" + std::string(key) + "\"";
    size_t pos = json.find(needle);
    if (pos == std::string::npos) {
        return std::nullopt;
    }
    pos = json.find(':', pos);
    if (pos == std::string::npos) {
        return std::nullopt;
    }
    ++pos;
    while (pos < json.size() && std::isspace(static_cast<unsigned char>(json[pos]))) {
        ++pos;
    }
    const size_t start = pos;
    while (pos < json.size() && (std::isdigit(static_cast<unsigned char>(json[pos])) ||
                                 json[pos] == '-' || json[pos] == '+' || json[pos] == '.')) {
        ++pos;
    }

    T value{};
    const auto begin = json.data() + start;
    const auto end = json.data() + pos;
    const auto result = std::from_chars(begin, end, value);
    if (result.ec != std::errc{}) {
        return std::nullopt;
    }
    return value;
}

std::optional<bool> ExtractBool(const std::string& json, std::string_view key) {
    const std::string needle = "\"" + std::string(key) + "\"";
    size_t pos = json.find(needle);
    if (pos == std::string::npos) {
        return std::nullopt;
    }
    pos = json.find(':', pos);
    if (pos == std::string::npos) {
        return std::nullopt;
    }
    ++pos;
    while (pos < json.size() && std::isspace(static_cast<unsigned char>(json[pos]))) {
        ++pos;
    }
    if (json.compare(pos, 4, "true") == 0) {
        return true;
    }
    if (json.compare(pos, 5, "false") == 0) {
        return false;
    }
    return std::nullopt;
}

} // namespace

std::string SerializeBrowserVideoState(const BrowserVideoState& state) {
    std::ostringstream out;
    out << "{";
    out << "\"type\":\"" << EscapeJson(state.type) << "\",";
    out << "\"tabId\":" << state.tabId << ",";
    out << "\"url\":\"" << EscapeJson(state.url) << "\",";
    out << "\"src\":\"" << EscapeJson(state.src) << "\",";
    out << "\"sentAtMs\":" << state.sentAtMs << ",";
    out << "\"currentTime\":" << state.currentTime << ",";
    out << "\"playbackRate\":" << state.playbackRate << ",";
    out << "\"paused\":" << (state.paused ? "true" : "false") << ",";
    out << "\"readyState\":" << state.readyState << ",";
    out << "\"videoWidth\":" << state.videoWidth << ",";
    out << "\"videoHeight\":" << state.videoHeight << ",";
    out << "\"rect\":{";
    out << "\"x\":" << state.rect.x << ",";
    out << "\"y\":" << state.rect.y << ",";
    out << "\"width\":" << state.rect.width << ",";
    out << "\"height\":" << state.rect.height << "},";
    out << "\"fullscreen\":" << (state.fullscreen ? "true" : "false") << ",";
    out << "\"protectedContent\":" << (state.protectedContent ? "true" : "false") << ",";
    out << "\"encrypted\":" << (state.encrypted ? "true" : "false") << ",";
    out << "\"agentVersion\":\"" << EscapeJson(state.agentVersion) << "\",";
    out << "\"overlayFrameSource\":\"" << EscapeJson(state.overlayFrameSource) << "\",";
    out << "\"overlayLastDrawError\":\"" << EscapeJson(state.overlayLastDrawError) << "\",";
    out << "\"overlayInputFPS\":" << state.overlayInputFPS << ",";
    out << "\"overlayOutputFPS\":" << state.overlayOutputFPS << ",";
    out << "\"overlayProcessedFrames\":" << state.overlayProcessedFrames;
    out << "}";
    return out.str();
}

std::optional<BrowserVideoState> ParseBrowserVideoState(const std::string& json) {
    BrowserVideoState state;
    state.type = ExtractString(json, "type").value_or("");
    if (state.type != "video_state") {
        return std::nullopt;
    }

    state.tabId = ExtractNumber<int64_t>(json, "tabId").value_or(0);
    state.url = ExtractString(json, "url").value_or("");
    state.src = ExtractString(json, "src").value_or("");
    state.sentAtMs = ExtractNumber<double>(json, "sentAtMs").value_or(0.0);
    state.currentTime = ExtractNumber<double>(json, "currentTime").value_or(0.0);
    state.playbackRate = ExtractNumber<double>(json, "playbackRate").value_or(1.0);
    state.paused = ExtractBool(json, "paused").value_or(true);
    state.readyState = ExtractNumber<double>(json, "readyState").value_or(0.0);
    state.videoWidth = ExtractNumber<double>(json, "videoWidth").value_or(0.0);
    state.videoHeight = ExtractNumber<double>(json, "videoHeight").value_or(0.0);
    state.rect.x = ExtractNumber<double>(json, "x").value_or(0.0);
    state.rect.y = ExtractNumber<double>(json, "y").value_or(0.0);
    state.rect.width = ExtractNumber<double>(json, "width").value_or(0.0);
    state.rect.height = ExtractNumber<double>(json, "height").value_or(0.0);
    state.fullscreen = ExtractBool(json, "fullscreen").value_or(false);
    state.protectedContent = ExtractBool(json, "protectedContent").value_or(false);
    state.encrypted = ExtractBool(json, "encrypted").value_or(false);
    state.agentVersion = ExtractString(json, "version").value_or("");
    state.overlayFrameSource = ExtractString(json, "overlayFrameSource").value_or("");
    state.overlayLastDrawError = ExtractString(json, "overlayLastDrawError").value_or("");
    state.overlayInputFPS = ExtractNumber<double>(json, "overlayInputFPS").value_or(0.0);
    state.overlayOutputFPS = ExtractNumber<double>(json, "overlayOutputFPS").value_or(0.0);
    state.overlayProcessedFrames = ExtractNumber<double>(json, "overlayProcessedFrames").value_or(0.0);
    return state;
}

bool IsDrmOrProtectedSource(const BrowserVideoState& state) {
    if (state.protectedContent) {
        return true;
    }

    const std::string combined = state.url + " " + state.src;
    return combined.find("widevine") != std::string::npos ||
           combined.find("fairplay") != std::string::npos ||
           combined.find("playready") != std::string::npos ||
           combined.find("encrypted-media") != std::string::npos;
}

} // namespace Stellaria::Motion
