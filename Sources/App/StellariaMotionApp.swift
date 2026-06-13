import SwiftUI

@main
struct StellariaMotionApp: App {
    var body: some Scene {
        WindowGroup {
            MotionDashboardView()
        }
    }
}

struct MotionDashboardView: View {
    @State private var profile = "Anime"
    @State private var targetFps = 60.0
    @State private var frameMultiplier = 2.0
    @State private var flowHeight = 720.0
    @State private var lineProtect = true
    @State private var subtitleProtect = true
    @State private var refine = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Stellaria Motion")
                .font(.largeTitle.weight(.semibold))

            Picker("Profile", selection: $profile) {
                Text("Anime").tag("Anime")
                Text("General").tag("General")
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Target FPS")
                Slider(value: $targetFps, in: 24...240, step: 1)
                Text("\(Int(targetFps))")
                    .monospacedDigit()
            }

            HStack {
                Text("Frame multiplier")
                Slider(value: $frameMultiplier, in: 1...8, step: 0.5)
                Text(String(format: "%.1fx", frameMultiplier))
                    .monospacedDigit()
            }

            HStack {
                Text("Flow height")
                Slider(value: $flowHeight, in: 540...1440, step: 180)
                Text("\(Int(flowHeight))p")
                    .monospacedDigit()
            }

            Toggle("Line art protection", isOn: $lineProtect)
            Toggle("Subtitle protection", isOn: $subtitleProtect)
            Toggle("Refine pass", isOn: $refine)
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 480)
    }
}

