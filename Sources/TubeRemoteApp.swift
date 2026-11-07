import SwiftUI

final class AppModel: ObservableObject {
    let settings: AppSettings
    let browser = Browser()
    let viewer: ViewerController
    let remote: RemoteController
    @Published var mode: Mode { didSet { apply() } }

    init() {
        let s = AppSettings()
        settings = s
        viewer = ViewerController(settings: s)
        remote = RemoteController(settings: s)
        mode = s.defaultMode
    }

    /// Idempotent: also used to restart networking when the app returns to the foreground.
    func apply() {
        switch mode {
        case .viewer:
            remote.stop()
            browser.pause()
            viewer.start()
        case .remote:
            viewer.stop()
            remote.start()
        }
    }
}

@main
struct TubeRemoteApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .environmentObject(model.browser)
                .environmentObject(model.viewer)
                .environmentObject(model.remote)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var phase
    @State private var showSettings = false

    var body: some View {
        Group {
            if model.mode == .viewer {
                ViewerView(showSettings: $showSettings)
            } else {
                RemoteView(showSettings: $showSettings)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear { model.apply() }
        .onChange(of: phase) { if $0 == .active { model.apply() } }
    }
}

struct ModeMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            Picker("Mode", selection: $model.mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
        } label: {
            Image(systemName: model.mode == .viewer ? "tv" : "iphone.radiowaves.left.and.right")
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("Shown to other devices on your network.")) {
                    TextField("Device name", text: $settings.deviceName)
                        .onSubmit { model.viewer.rename() }
                }
                Section("Defaults") {
                    Picker("Mode on launch", selection: $settings.defaultMode) {
                        ForEach(Mode.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Queue action", selection: $settings.queueAction) {
                        ForEach(QueueAction.allCases) { Text($0.label).tag($0) }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onDisappear { model.viewer.rename() }
    }
}
