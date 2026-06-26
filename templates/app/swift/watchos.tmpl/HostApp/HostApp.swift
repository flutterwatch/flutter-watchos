import SwiftUI

// Minimal iOS host application.
//
// App Store Connect has no standalone "watchOS" submission path: even an
// independent watch app must be uploaded as an iOS-platform archive that
// embeds the watch app under `<HostApp>.app/Watch/`. This host exists solely
// to provide that iOS container. It carries no product logic — the real app
// is the embedded watchOS Runner.
@main
struct {{titleCaseProjectName}}HostApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "applewatch")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("{{titleCaseProjectName}}")
                .font(.title.bold())
            Text("This app runs on Apple Watch. Open it from your watch.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
        .padding()
    }
}
