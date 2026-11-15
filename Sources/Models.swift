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
    /// Sharper image for the large Now Playing artwork. Older videos lack it, so pair it with thumbnailURL.
    var artworkURL: URL { URL(string: "https://i.ytimg.com/vi/\(videoID)/hq720.jpg")! }
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
    var queue: [VideoItem]
    var history: [VideoItem]
    // Optional so builds from before these existed still decode; nil hides the controls on the remote.
    var speed: Double?
    var captions: Bool?
    /// YouTube's name for the quality now playing, e.g. "hd1080".
    var quality: String?
    var qualities: [String]?
    /// An advert is playing and YouTube is offering its Skip button.
    var adSkippable: Bool?
    /// No quality is forced; `quality` is then whatever YouTube picked.
    var autoQuality: Bool?
    /// "searching": captions were asked for and none are showing yet. "none": this video has none.
    var captionsStatus: String?

    var muted: Bool { volume < 0.01 }
}

enum Command: Codable {
    case play(VideoItem), playNext(VideoItem), enqueue(VideoItem)
    case pause, resume
    case seek(Double), skip(Double)
    case next, previous
    case setVolume(Float), setMuted(Bool)
    case remove(UUID), reorder([UUID]), playQueueItem(UUID)
    case clearQueue, clearHistory
    /// Quality is YouTube's name ("hd1080"), or "auto".
    case setSpeed(Double), setCaptions(Bool), setQuality(String)
    case skipAd
}

struct PairedDevice: Codable, Identifiable {
    var id: String { key }
    let key: String
    var name: String
    let secret: Data
}

/// Same messages in both directions. The side that starts sends a hash of its public key first and
/// only reveals the key after it has the other side's, so neither can pick a key to force a matching code.
enum PairMessage: Codable {
    case commit(Data)
    case key(pub: Data, deviceKey: String, name: String)
    case decision(Bool)
}

// Devices on different app versions must still understand each other's hello, so keep `hello` stable,
// bump Transport.version for breaking changes, and make any field added to a message optional.

/// Remote -> viewer. `command` is only accepted inside `sealed`.
enum ClientMessage: Codable {
    case hello(name: String, key: String, version: Int?)
    case auth(mac: Data, nonce: Data)
    case ping
    case pair(PairMessage)
    case command(Command)
    case sealed(Data)
}

/// Viewer -> remote. `state` is only sent inside `sealed`, to authenticated remotes.
enum ServerMessage: Codable {
    case hello(version: Int)
    case state(ViewerState)
    case unpaired
    case challenge(Data)
    case pair(PairMessage)
    case sealed(Data)
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
    if p.count >= 3, ["shorts", "embed", "live"].contains(p[1]) { return p[2] }
    return nil
}

/// "hd1080" -> "1080p".
func qualityLabel(_ q: String?) -> String {
    let names = ["highres": "Max", "large": "480p", "medium": "360p", "small": "240p", "tiny": "144p"]
    guard let q, q != "auto", q != "unknown" else { return "Auto" }
    return names[q] ?? (q.hasPrefix("hd") ? "\(q.dropFirst(2))p" : q)
}

func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let t = Int(seconds)
    let h = t / 3600, m = (t % 3600) / 60, s = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

enum VideoMetadata {
    private struct OEmbed: Decodable { let title: String; let author_name: String }

    /// `fallbackTitle` is used when the lookup fails or takes longer than five seconds.
    static func item(videoID: String, duration: Double?, fallbackTitle: String = "") async -> VideoItem {
        var title = fallbackTitle.isEmpty ? "YouTube video" : fallbackTitle, channel = ""
        if let url = URL(string: "https://www.youtube.com/oembed?format=json&url=https://www.youtube.com/watch?v=\(videoID)"),
           let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5)),
           let o = try? JSONDecoder().decode(OEmbed.self, from: data) {
            title = o.title
            channel = o.author_name
        }
        return VideoItem(videoID: videoID, title: title, channel: channel, duration: duration)
    }
}
