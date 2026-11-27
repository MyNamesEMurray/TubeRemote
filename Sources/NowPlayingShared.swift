import Foundation
import NowPlaying

@available(iOS 27.0, *)
struct NowPlayingAttributes: RemoteMediaSessionAttributes {
    var id: String
    var viewerName: String
    var videoID: String
    var title: String
    var channel: String
    var isPlaying: Bool
    var position: Double
    var timestamp: Date
    var duration: Double
    var speed: Float
    var live: Bool
    var volume: Float
    var skip: Double
}

enum NowPlayingMailbox {
    static let notification = "com.exaltedpixels.TubeRemote.nowplaying.command"

    private static var dir: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedConfig.group)?
            .appendingPathComponent("nowplaying", isDirectory: true)
    }

    private static func ensureDir() -> URL? {
        guard let d = dir else { return nil }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func markActive() {
        guard let d = ensureDir() else { return }
        try? String(Date().timeIntervalSince1970).write(to: d.appendingPathComponent("active"), atomically: true, encoding: .utf8)
    }

    static var appIsActive: Bool {
        guard let d = dir, let text = try? String(contentsOf: d.appendingPathComponent("active"), encoding: .utf8),
              let t = Double(text) else { return false }
        return Date().timeIntervalSince1970 - t < 3
    }

    static func post(_ command: Command) {
        guard let d = ensureDir(), let data = try? JSONEncoder().encode(command) else { return }
        let name = "cmd-\(String(format: "%.4f", Date().timeIntervalSince1970))-\(UUID().uuidString).json"
        try? data.write(to: d.appendingPathComponent(name), options: .atomic)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(notification as CFString), nil, nil, true)
    }

    static func take() -> [Command] {
        guard let d = dir, let files = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) else { return [] }
        var out: [Command] = []
        for url in files.filter({ $0.lastPathComponent.hasPrefix("cmd-") }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if let data = try? Data(contentsOf: url), let command = try? JSONDecoder().decode(Command.self, from: data) { out.append(command) }
            try? FileManager.default.removeItem(at: url)
        }
        return out
    }
}
