#include "VFI/RIFEMPSGraphRunner.h"

#include <cassert>
#include <filesystem>
#include <iostream>

int main() {
    using Stellaria::Motion::RIFEMPSGraphRunner;
    std::filesystem::path modelPath = std::filesystem::current_path() / "Models/RIFE-safetensors/flownet.safetensors";
    if (!std::filesystem::exists(modelPath)) {
        modelPath = std::filesystem::current_path().parent_path() / "Models/RIFE-safetensors/flownet.safetensors";
    }
    RIFEMPSGraphRunner runner;
    const bool loaded = runner.Load(modelPath.string(), 32, 32);
    if (!loaded) {
        std::cerr << runner.Diagnostics() << "\n";
    }
    assert(loaded);
    assert(runner.IsReady());

    const auto result = runner.RunZeroInput();
    if (!result.ok) {
        std::cerr << result.message << "\n";
    }
    assert(result.ok);
    assert(result.width == 32);
    assert(result.height == 32);
    assert(result.outputChannels == 3);
    std::cout << result.message << " " << result.elapsedMs << "ms\n";
    return 0;
}
