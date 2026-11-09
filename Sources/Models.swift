import Foundation

enum Mode: String, CaseIterable, Identifiable {
    case viewer, remote
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum QueueAction: String, CaseIterable, Identifiable {
    case playNow, playNext, addToEnd
    var id: String { rawValue }

    var label: String {
        switch self {
        case .playNow: return "Play now"
        case .playNext: return "Play next"
        case .addToEnd: return "Add to end of queue"
        }
    }

    func title(on target: String) -> String {
        switch self {
        case .playNow: return "Play on \(target)"
        case .playNext: return "Play next on \(target)"
        case .addToEnd: return "Add to end of queue on \(target)"
        }
    }

    var icon: String {
        switch self {
        case .playNow: return "play.fill"
        case .playNext: return "text.insert"
        case .addToEnd: return "text.append"
        }
    }

    func command(_ item: VideoItem) -> Command {
        switch self {
        case .playNow: return .play(item)
        case .playNext: return .playNext(item)
        case .addToEnd: return .enqueue(item)
        }
    }
}

struct VideoItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var videoID: String
    var title: String
    var channel: String
    var duration: Double?

    var thumbnailURL: URL { URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg")! }
    /// Same video with a new queue-entry id, so one video can sit in the queue twice.
    var fresh: VideoItem { var c = self; c.id = UUID(); return c }
    /// videoID is interpolated into JS on the viewer, and arrives over the network: whitelist it.
    var isValid: Bool { videoID.range(of: "^[A-Za-z0-9_-]{6,20}$", options: .regularExpression) != nil }
}

struct ViewerState: Codable, Equatable {
    var deviceName: String
    var current: VideoItem?
    var isPlaying: Bool
    var position: Double
    var duration: Double
    var volume: Float
    var muted: Bool
    var queue: [VideoItem]
    var history: [VideoItem]
}

enum Command: Codable {
    case play(VideoItem), playNext(VideoItem), enqueue(VideoItem)
    case pause, resume
    case seek(Double), skip(Double)
    case next, previous
    case setVolume(Float), setMuted(Bool)
    case remove(UUID), reorder([UUID]), playQueueItem(UUID)
    case clearQueue, clearHistory
}

struct PairedDevice: Codable, Identifiable {
    var id: String { key }
    let key: String
    var name: String
    let secret: Data
}

/// Same message in both directions: each side sends its ephemeral public key, then its yes/no.
enum PairMessage: Codable {
    case key(pub: Data, deviceKey: String, name: String)
    case decision(Bool)
}

/// Remote -> viewer.
enum ClientMessage: Codable {
    case hello(name: String, key: String)
    case auth(Data)
    case ping
    case pair(PairMessage)
    case command(Command)
}

/// Viewer -> remote. `state` is only sent to authenticated remotes.
enum ServerMessage: Codable {
    case state(ViewerState)
    case unpaired
    case challenge(Data)
    case pair(PairMessage)
}

func parseVideoID(_ url: URL?) -> String? {
    guard let url, let host = url.host?.lowercased() else { return nil }
    if host == "youtu.be" { return url.pathComponents.dropFirst().first }
    guard host.hasSuffix("youtube.com") else { return nil }
    if url.path == "/watch" {
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "v" }?.value
    }
    let p = url.pathComponents
    if p.count >= 3, p[1] == "shorts" || p[1] == "embed" { return p[2] }
    return nil
}

func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let t = Int(seconds)
    let h = t / 3600, m = (t % 3600) / 60, s = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

enum VideoMetadata {
    private struct OEmbed: Decodable { let title: String; let author_name: String }

    static func item(videoID: String, duration: Double?) async -> VideoItem {
        var title = "YouTube video", channel = ""
        if let url = URL(string: "https://www.youtube.com/oembed?format=json&url=https://www.youtube.com/watch?v=\(videoID)"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let o = try? JSONDecoder().decode(OEmbed.self, from: data) {
            title = o.title
            channel = o.author_name
        }
        return VideoItem(videoID: videoID, title: title, channel: channel, duration: duration)
    }
}
