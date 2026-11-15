import AVFoundation
import SwiftUI

@main
struct FrigateViewerApp: App {
    @State private var model = AppModel()

    init() {
        // Let recordings play with sound even when the ring/silent switch is on silent.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isConfigured {
                TabView(selection: $model.selectedTab) {
                    CameraGridView()
                        .tabItem { Label("Live", systemImage: "video") }
                        .tag(AppModel.Tab.live)
                    ReviewListView()
                        .tabItem { Label("Review", systemImage: "exclamationmark.bubble") }
                        .tag(AppModel.Tab.review)
                    RecordingsView()
                        .tabItem { Label("Recordings", systemImage: "clock.arrow.circlepath") }
                        .tag(AppModel.Tab.recordings)
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gear") }
                        .tag(AppModel.Tab.settings)
                }
                .task { await model.refresh() }
            } else {
                NavigationStack { ServerSetupView() }
            }
        }
    }
}
