#include "VFI/RIFEMPSGraphRunner.h"

#import <Foundation/Foundation.h>

#include <algorithm>
#include <cassert>
#include <filesystem>
#include <iostream>
#include <vector>

int main() {
    @autoreleasepool {
        using Stellaria::Motion::RIFEMPSGraphRunner;
        std::filesystem::path modelPath = std::filesystem::current_path() / "Models/RIFE-safetensors/flownet.safetensors";
        if (!std::filesystem::exists(modelPath)) {
            modelPath = std::filesystem::current_path().parent_path() / "Models/RIFE-safetensors/flownet.safetensors";
        }
        RIFEMPSGraphRunner runner;
        const uint32_t width = 960;
        const uint32_t height = 544;
        const bool loaded = runner.Load(modelPath.string(), width, height);
        if (!loaded) {
            std::cerr << runner.Diagnostics() << "\n";
        }
        assert(loaded);

        std::vector<double> samples;
        for (int i = 0; i < 4; ++i) {
            const auto result = runner.RunZeroInput();
            if (!result.ok) {
                std::cerr << result.message << "\n";
            }
            assert(result.ok);
            samples.push_back(result.elapsedMs);
        }
        std::sort(samples.begin(), samples.end());
        const double median = samples[samples.size() / 2];
        std::cout << "RIFE MPSGraph perf " << width << "x" << height
                  << " median=" << median << "ms";
        if (median > 33.3) {
            std::cout << " over_realtime_budget";
        }
        std::cout << "\n";
    }
    return 0;
}
