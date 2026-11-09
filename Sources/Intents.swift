import AppIntents
import Foundation

enum IntentError: LocalizedError {
    case notPro, noViewer

    var errorDescription: String? {
        switch self {
        case .notPro: return "Siri Shortcuts need TubeRemote Pro. Open TubeRemote to unlock it."
        case .noViewer: return "Couldn't reach a viewer. Make sure a paired viewer is running TubeRemote on the same network."
        }
    }
}

@MainActor
private func sendToViewer(_ cmd: Command) async throws {
    guard ProStore.shared.isPro else { throw IntentError.notPro }
    let deadline = Date().addingTimeInterval(6)
    while Date() < deadline {
        if let model = AppModel.shared {
            model.remote.start()
            let paired = model.remote.devices.filter { model.settings.paired($0.key) != nil }
            if let c = model.remote.active ?? paired.first(where: { $0.connected }) ?? paired.first, c.connected {
                c.send(cmd)
                return
            }
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
    }
    throw IntentError.noViewer
}

struct PauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause TubeRemote"
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult {
        try await sendToViewer(.pause)
        return .result()
    }
}

struct ResumeIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume"
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult {
        try await sendToViewer(.resume)
        return .result()
    }
}

struct NextIntent: AppIntent {
    static var title: LocalizedStringResource = "Next video"
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult {
        try await sendToViewer(.next)
        return .result()
    }
}

struct PreviousIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous video"
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult {
        try await sendToViewer(.previous)
        return .result()
    }
}

struct TubeRemoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PauseIntent(), phrases: ["Pause \(.applicationName)"], shortTitle: "Pause", systemImageName: "pause.fill")
        AppShortcut(intent: ResumeIntent(), phrases: ["Resume \(.applicationName)"], shortTitle: "Resume", systemImageName: "play.fill")
        AppShortcut(intent: NextIntent(), phrases: ["Next video in \(.applicationName)"], shortTitle: "Next video", systemImageName: "forward.fill")
        AppShortcut(intent: PreviousIntent(), phrases: ["Previous video in \(.applicationName)"], shortTitle: "Previous video", systemImageName: "backward.fill")
    }
}
