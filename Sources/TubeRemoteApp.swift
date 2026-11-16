import SwiftUI

final class AppModel: ObservableObject {
    let settings: AppSettings
    let browser: Browser
    let viewer: ViewerController
    let remote: RemoteController
    let pairing: Pairing
    @Published var mode: Mode { didSet { apply() } }

    init() {
        let s = AppSettings()
        settings = s
        let p = Pairing(settings: s)
        pairing = p
        let b = Browser()
        browser = b
        viewer = ViewerController(settings: s, pairing: p, browser: b)
        remote = RemoteController(settings: s, pairing: p)
        mode = s.defaultMode
    }

    /// Idempotent: also used to restart networking when the app returns to the foreground.
    func apply() {
        Log.tag = mode == .viewer ? "V" : "R"
        Log.add("apply \(mode.rawValue)")
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
                .environmentObject(model.pairing)
                .environmentObject(ProStore.shared)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var pro: ProStore
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
        .fullScreenCover(isPresented: Binding(get: { !settings.hasOnboarded }, set: { _ in })) {
            OnboardingView()
        }
        .pairingPrompt()
        .onAppear { model.apply() }
        .onChange(of: phase) {
            switch $0 {
            case .active:
                model.apply()
                Log.shared.setCleanExit(false)
            case .background:
                Log.shared.setCleanExit(true)
            default:
                Log.shared.save()
            }
            settings.mirrorForShare(pro: pro.isPro)
        }
    }
}

private extension Mode {
    var symbol: String { self == .viewer ? "tv" : "iphone.radiowaves.left.and.right" }
}

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @State private var choosing = false

    var body: some View {
        VStack {
            if choosing { chooser } else { welcome }
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .animation(.default, value: choosing)
    }

    private var welcome: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Image(systemName: "play.fill").font(.system(size: 48))
                Image(systemName: "wave.3.right").font(.system(size: 34)).opacity(0.6)
            }
                .foregroundStyle(.white)
                .frame(width: 112, height: 112)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .accessibilityHidden(true)
            Text("Welcome to TubeRemote")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 22) {
                feature("paperplane.fill", "Send videos to another device", "Find something on your phone and play it on a bigger screen.")
                feature("slider.horizontal.3", "Control playback from anywhere in the room", "Play, pause, skip and manage the queue from your remote.")
                feature("link", "Pair once, reconnect automatically", "Devices on your network remember each other.")
            }
            Spacer(minLength: 0)
            Button {
                Haptics.tap()
                choosing = true
            } label: {
                Text("Continue").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(.tint)
                .frame(width: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var chooser: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            Text("How will you use this device?")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            card(.viewer, "Viewer", "Plays videos on this screen. Great for an iPad or TV-connected device.")
            card(.remote, "Remote", "Browse YouTube and send videos to a viewer.")
            Text("You can change this later in Settings.\nNext, iOS asks to find devices on your local network. Choose Allow, or your devices cannot see each other.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
    }

    private func card(_ mode: Mode, _ title: String, _ detail: String) -> some View {
        Button {
            Haptics.success()
            settings.defaultMode = mode
            model.mode = mode
            settings.hasOnboarded = true
        } label: {
            HStack(spacing: 16) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                    .frame(width: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(detail)")
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var remote: RemoteController
    @EnvironmentObject var pro: ProStore
    @Environment(\.dismiss) private var dismiss
    @State private var showPaywall = false

    private var version: String {
        let i = Bundle.main.infoDictionary
        return i?["CFBundleShortVersionString"] as? String ?? "-"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("TubeRemote Pro") {
                    if pro.isPro {
                        Label("Pro unlocked", systemImage: "checkmark.seal.fill")
                    } else {
                        Button { showPaywall = true } label: {
                            Label("Unlock TubeRemote Pro", systemImage: "star.fill").font(.headline)
                        }
                    }
                    Button("Restore Purchases") { Task { await pro.restore() } }
                }
                Section {
                    if model.mode == .viewer {
                        QualityRow(value: settings.preferredQuality, enabled: true,
                                   set: { model.viewer.handle(.setPreferredQuality($0), from: nil) }, showPaywall: $showPaywall)
                    } else if let c = remote.active {
                        RemoteQualityRow(client: c, showPaywall: $showPaywall)
                    } else {
                        Text("Choose a viewer to set the quality it starts videos at.").foregroundStyle(.secondary)
                    }
                    if model.mode == .remote {
                        if pro.has(remote.active?.state) {
                            Toggle("Keep the queue on this device", isOn: $settings.saveQueue)
                        } else {
                            Button { showPaywall = true } label: {
                                HStack {
                                    Text("Keep the queue on this device").foregroundStyle(.primary)
                                    GatedBadge()
                                    Spacer()
                                }
                            }
                        }
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("The quality the viewer starts every video at. Highest available picks the best the video offers, up to 4K. Auto lets YouTube choose. Keeping the queue saves it here. A viewer with nothing queued then offers to resume it when you connect.")
                }
                Section {
                    TextField("Device name", text: $settings.deviceName)
                        .onSubmit { model.viewer.rename() }
                } header: {
                    Text("This Device")
                } footer: {
                    Text("Shown to other devices on your network.")
                }
                Section {
                    Picker("Use this device as", selection: Binding(
                        get: { model.mode },
                        set: { model.mode = $0; settings.defaultMode = $0 }
                    )) {
                        ForEach(Mode.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.menu)
                } footer: {
                    Text("A viewer plays videos on this screen. A remote browses YouTube and sends them.")
                }
                Section {
                    Picker("Queue action", selection: $settings.queueAction) {
                        ForEach(QueueAction.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Queue")
                } footer: {
                    Text("What the main send button does when you choose a video. Other options stay available from its menu.")
                }
                Section {
                    if settings.paired.isEmpty {
                        Text("No paired devices yet").foregroundStyle(.secondary)
                    }
                    ForEach(settings.paired) { Label($0.name, systemImage: "link") }
                        .onDelete { settings.paired.remove(atOffsets: $0) }
                } header: {
                    Text("Paired Devices")
                } footer: {
                    Text("Removing a device disconnects it right away.")
                }
                Section("About") {
                    LabeledContent("Version", value: version)
                    LabeledContent("Build", value: build)
                    NavigationLink("Debug Log") { DebugLogView() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .pairingPrompt()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .cancellationAction) {
                    if !settings.paired.isEmpty { EditButton() }
                }
            }
            .sheet(isPresented: $showPaywall) { PaywallView() }
        }
        .onDisappear { model.viewer.rename() }
    }
}
