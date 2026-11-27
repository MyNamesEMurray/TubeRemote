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
    private static var suite: UserDefaults? { UserDefaults(suiteName: SharedConfig.group) }

    static func markActive() { suite?.set(Date(), forKey: "appActiveAt") }

    static var appIsActive: Bool {
        suite?.synchronize()
        guard let at = suite?.object(forKey: "appActiveAt") as? Date else { return false }
        return Date().timeIntervalSince(at) < 3
    }

    static func post(_ command: Command) {
        guard let data = try? JSONEncoder().encode(command) else { return }
        suite?.synchronize()
        var list = suite?.array(forKey: "commands") as? [Data] ?? []
        list.append(data)
        suite?.set(list, forKey: "commands")
        suite?.synchronize()
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(notification as CFString), nil, nil, true)
    }

    static func take() -> [Command] {
        suite?.synchronize()
        let list = suite?.array(forKey: "commands") as? [Data] ?? []
        suite?.removeObject(forKey: "commands")
        return list.compactMap { try? JSONDecoder().decode(Command.self, from: $0) }
    }
}
