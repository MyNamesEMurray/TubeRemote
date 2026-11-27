import Combine
import SwiftUI

final class AppModel: ObservableObject {
    let settings: AppSettings
    let browser: Browser
    let viewer: ViewerController
    let remote: RemoteController
    let lock: LockScreenControls
    let pairing: Pairing
    private var lockObs: AnyCancellable?
    private var nowBridge: AnyObject?
    @Published var mode: Mode { didSet { apply() } }

    init() {
        let s = AppSettings()
        settings = s
        let p = Pairing(settings: s)
        pairing = p
        let b = Browser()
        browser = b
        viewer = ViewerController(settings: s, pairing: p, browser: b)
        let r = RemoteController(settings: s, pairing: p)
        remote = r
        lock = LockScreenControls(settings: s, remote: r)
        mode = s.defaultMode
        lockObs = s.$lockScreenControls.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.refreshLock() } }
    }

    private func refreshLock() {
        if #available(iOS 27.0, *) {
            MainActor.assumeIsolated {
                let bridge = nowBridge as? NowPlayingBridge ?? NowPlayingBridge(settings: settings, remote: remote)
                nowBridge = bridge
                bridge.sync(on: mode == .remote && settings.lockScreenControls)
            }
        } else {
            lock.remoteRole = mode == .remote
            lock.sync()
        }
    }

    /// Idempotent: also used to restart networking when the app returns to the foreground.
    func apply() {
        Log.tag = mode == .viewer ? "V" : "R"
        Log.add("apply \(mode.rawValue)")
        refreshLock()
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
            #if DEBUG
            if ScreenshotStage.shot != nil { StagedShot() } else { root }
            #else
            root
            #endif
        }
    }

    private var root: some View {
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
        .onAppear {
            model.apply()
            settings.mirrorForShare(pro: pro.isPro)
        }
        .onChange(of: settings.paired.count) { _ in settings.mirrorForShare(pro: pro.isPro) }
        .onChange(of: pro.isPro) { _ in settings.mirrorForShare(pro: pro.isPro) }
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
            Text("You can change this later in Settings.\nNext, iOS asks to find devices on your local network. Choose Allow, or your devices can't see each other.")
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
    @State private var logTaps = 0
    @State private var lastLogTap = Date.distantPast
    @State private var showLog = false

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
                        .disabled(pro.busy)
                    if let m = pro.message {
                        Text(m).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("This Device") {
                    LabeledContent("Name") {
                        HStack(spacing: 6) {
                            TextField("Device name", text: $settings.deviceName)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(Color.accentColor)
                                .textInputAutocapitalization(.words)
                                .submitLabel(.done)
                                .onSubmit { model.viewer.rename() }
                            Image(systemName: "pencil").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Picker("Use this device as", selection: Binding(
                        get: { model.mode },
                        set: { model.mode = $0; settings.defaultMode = $0 }
                    )) {
                        ForEach(Mode.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                Section("Playback") {
                    if model.mode == .viewer {
                        QualityRow(value: settings.preferredQuality, enabled: true,
                                   set: { model.viewer.handle(.setPreferredQuality($0), from: nil) }, showPaywall: $showPaywall)
                    } else if let c = remote.active {
                        RemoteQualityRow(client: c, showPaywall: $showPaywall)
                    } else {
                        Text("Pick a viewer to change this").foregroundStyle(.secondary)
                    }
                    Picker("Skip button length", selection: $settings.skipSeconds) {
                        ForEach([5, 10, 15, 20, 25, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                    }
                    if model.mode == .remote {
                        if pro.has(remote.active?.state) {
                            Toggle("Lock screen controls", isOn: $settings.lockScreenControls)
                        } else {
                            Button { showPaywall = true } label: {
                                HStack {
                                    Text("Lock screen controls").foregroundStyle(.primary)
                                    GatedBadge()
                                    Spacer()
                                }
                            }
                        }
                    }
                }
                if model.mode == .viewer {
                    Section("Viewer") {
                        Toggle("Hide the status bar", isOn: $settings.hideStatusBar)
                    }
                }
                Section("Interface") {
                    Toggle("Haptic feedback", isOn: $settings.haptics)
                }
                Section("About") {
                    LabeledContent("Version", value: version)
                    LabeledContent("Build", value: build)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            logTaps = Date().timeIntervalSince(lastLogTap) > 2 ? 1 : logTaps + 1
                            lastLogTap = Date()
                            if logTaps >= 5 {
                                logTaps = 0
                                Haptics.success()
                                showLog = true
                            }
                        }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .pairingPrompt()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showPaywall) { PaywallView() }
            .navigationDestination(isPresented: $showLog) { DebugLogView() }
        }
        .onDisappear { model.viewer.rename() }
    }
}
