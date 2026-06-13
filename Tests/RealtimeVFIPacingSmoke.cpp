#include "Core/RealtimeVFISession.h"

#include <cassert>
#include <cmath>
#include <iostream>

int main() {
    using namespace Stellaria::Motion;

    RealtimeVFIConfig config;
    config.inputSource = RealtimeInputSource::BrowserStream;
    config.backend = RealtimeRIFEBackend::MPSGraphFP16;
    config.targetFPS = 60.0;
    config.prerollSeconds = 0.10;
    config.maxVisibleFrameGapMs = 16.67;
    config.maxPipelineLatencyMs = 16.67;

    RealtimeVFISession session(config);
    session.NoteQueueDepth(6);
    assert(session.HasEnoughPreroll());

    double now = 100.0;
    for (int i = 0; i < 120; ++i) {
        session.NoteOutputFrame(now);
        now += 1.0 / 60.0;
    }

    const RealtimeVFIDiagnostics diagnostics = session.Diagnostics();
    assert(diagnostics.outputFrames == 120);
    assert(diagnostics.cadenceStable);
    assert(diagnostics.maxFrameGapMs < 17.5);
    assert(std::fabs(diagnostics.outputFPS - 60.0) < 0.5);
    session.NotePipelineTiming(11.2, 3.1);
    assert(session.Diagnostics().latencyStable);
    session.NotePipelineTiming(15.0, 3.0);
    assert(!session.Diagnostics().latencyStable);

    session.NoteOutputFrame(now + 0.050);
    assert(!session.Diagnostics().cadenceStable);
    std::cout << session.Summary() << "\n";
    return 0;
}
