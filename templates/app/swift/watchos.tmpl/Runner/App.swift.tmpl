import SwiftUI

@main
struct {{titleCaseProjectName}}App: App {
    var body: some Scene {
        WindowGroup {
            #if arch(arm64_32)
            // 32-bit watches (Series 4–8 / SE) are not supported.
            UnsupportedDeviceView()
            #else
            FlutterHostView()
            #endif
        }
    }
}

// Shown on 32-bit watches (Series 4–8 / SE), which this app does not support.
struct UnsupportedDeviceView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("{{titleCaseProjectName}}")
                .font(.headline)
            Text("Requires Apple Watch Series 9 or later.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#if !arch(arm64_32)
struct FlutterHostView: View {
    @ObservedObject var runner = FlutterRunner.shared
    @State private var crownValue: Double = 0.0
    @State private var lastCrownValue: Double = 0.0
    @FocusState private var isFocused: Bool

    var body: some View {
        GeometryReader { _ in
            Group {
                if let frame = runner.frame {
                    Image(decorative: frame, scale: runner.pixelRatio)
                        .resizable()
                        .frame(width: runner.sizePoints.width, height: runner.sizePoints.height)
                } else {
                    Text("Starting Flutter…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { runner.touch(at: $0.location, ended: false) }
                    .onEnded { runner.touch(at: $0.location, ended: true) }
            )
            .focusable()
            .focused($isFocused)
            .digitalCrownRotation(
                $crownValue,
                from: -10000.0,
                through: 10000.0,
                by: 0.05,
                sensitivity: .high,
                isContinuous: true,
                isHapticFeedbackEnabled: false
            )
            .onChange(of: crownValue) { oldValue, newValue in
                let delta = newValue - oldValue
                lastCrownValue = newValue
                runner.sendCrownDelta(delta)
            }
        }
        .ignoresSafeArea()
        ._statusBarHidden()
        .onAppear {
            FlutterRunner.shared.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isFocused = true
            }
        }
    }
}
#endif  // arch(arm64_32)

