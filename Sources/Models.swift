import Foundation

enum Mode: String, CaseIterable, Identifiable {
    case viewer, remote
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum QueueAction: String, CaseIterable, Identifiable, Codable {
    case playNow, playNext, addToEnd
    var id: String { rawValue }

    var label: String {
        switch self {
        case .playNow: return "Play now"
        case .playNext: return "Play next"
        case .addToEnd: return "Add to end of queue"
        }
    }

    var playlistTitle: String {
        switch self {
        case .playNow: return "Play playlist now"
        case .playNext: return "Play playlist next"
        case .addToEnd: return "Add playlist to end of queue"
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

extension Command {
    /// The command's name without its contents, for the log: "play", not the video it carries.
    var logName: String { String(String(describing: self).prefix { $0 != "(" }) }
}

struct VideoItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var videoID: String
    var title: String
    var channel: String
    var duration: Double?
    /// Where the viewer starts this video, in seconds. Only set on a resumed video; it does not stay on the item.
    var startAt: Double?

    var thumbnailURL: URL { URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg")! }
    /// Sharper image for the large Now Playing artwork. Older videos lack it, so pair it with thumbnailURL.
    var artworkURL: URL { URL(string: "https://i.ytimg.com/vi/\(videoID)/hq720.jpg")! }
    /// Same video with a new queue-entry id, so one video can sit in the queue twice.
    var fresh: VideoItem { var c = self; c.id = UUID(); return c }
    /// videoID is interpolated into JS on the viewer, and arrives over the network: whitelist it.
    var isValid: Bool { videoID.range(of: "^[A-Za-z0-9_-]{6,20}$", options: .regularExpression) != nil }
}

/// What a remote keeps of a viewer's queue: the video that was playing, where it had got to, and what was next.
struct SavedQueue: Codable, Equatable {
    var current: VideoItem?
    var position = 0.0
    var queue: [VideoItem] = []

    var count: Int { (current == nil ? 0 : 1) + queue.count }
    var isEmpty: Bool { count == 0 }
    /// Videos in the order they would play, the first starting where it left off.
    var items: [VideoItem] {
        guard var c = current else { return queue }
        c.startAt = position > 5 ? position : nil
        return [c] + queue
    }
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
    /// What the viewer starts every video at (see `preferredQualityChoices`).
    var preferredQuality: String?
    /// When the viewer will pause by itself, if a sleep timer is running.
    var sleepEndsAt: Date?
    /// No quality is forced; `quality` is then whatever YouTube picked.
    var autoQuality: Bool?
    /// "searching": captions were asked for and none are showing yet. "none": this video has none.
    var captionsStatus: String?
    /// Pro is on the viewer or a connected remote, so every remote may use Pro features.
    var sessionPro: Bool?
    /// Pro: when the queue runs out the viewer starts what YouTube suggests next. Nil on a viewer that cannot do this.
    var autoplay: Bool?

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
    /// The quality every video starts at: YouTube's quality name, "best" or "auto".
    case setPreferredQuality(String)
    /// Seconds until the viewer pauses; 0 means at the end of the video, -1 at the end of the queue, nil switches the timer off.
    case setSleepTimer(Double?)
    case setAutoplay(Bool)
    /// A whole playlist at once, placed in the queue the way `QueueAction` says.
    case playlist([VideoItem], QueueAction)
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
    /// `pro` says whether this device has TubeRemote Pro; one Pro device lets several remotes share a viewer.
    case hello(name: String, key: String, version: Int?, pro: Bool?)
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
    /// The person at the viewer disconnected this remote; it should not reconnect by itself.
    case goodbye
    /// The viewer already serves another remote and nothing connected has Pro. The remote should not retry by itself.
    case busy
}

/// Who may be connected to a viewer at once: one remote, or any number when the viewer or a connected remote has Pro.
struct SessionRules {
    struct Remote: Equatable {
        var key: String
        var pro: Bool
        var since: Date
    }

    /// A remote signing in is let in if it is the only one, or the session has Pro through the viewer, the newcomer or
    /// anyone already connected. A device's own older connection does not count against it.
    static func admits(_ newcomer: Remote, among current: [Remote], viewerPro: Bool) -> Bool {
        let others = current.filter { $0.key != newcomer.key }
        return others.isEmpty || viewerPro || newcomer.pro || others.contains { $0.pro }
    }

    /// After the Pro device left: nothing is playing and the extras have had a minute.
    static func shouldTrim(playing: Bool, idleSince: Date?, now: Date) -> Bool {
        !playing && idleSince.map { now.timeIntervalSince($0) >= 60 } == true
    }

    /// When a session has lost Pro (the Pro remote left) and several remotes remain: everyone but the one connected longest.
    static func excess(_ current: [Remote], viewerPro: Bool) -> [String] {
        guard !viewerPro, current.count > 1, !current.contains(where: \.pro),
              let keep = current.min(by: { $0.since < $1.since })?.key else { return [] }
        return current.map(\.key).filter { $0 != keep }
    }
}

let playbackSpeeds = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

func rateLabel(_ r: Double) -> String { (r == r.rounded() ? "\(Int(r))" : "\(r)") + "×" }

/// The playlist id in a YouTube address, if it names a playlist this app can read. Auto-generated mixes (RD...) are not.
func parseListID(_ url: URL?) -> String? {
    guard let url, let host = url.host?.lowercased(), host.hasSuffix("youtube.com"),
          let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "list" })?.value
    else { return nil }
    let ok = id == "LL" || id == "WL" || id.range(of: "^(PL|UU|OLAK5uy_|FL)[A-Za-z0-9_-]{2,}$", options: .regularExpression) != nil
    return ok ? id : nil
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

/// What can be chosen as the preferred quality. "best" is the highest the video offers up to 4K, "auto" leaves it to YouTube.
let preferredQualityChoices: [(id: String, label: String)] = [
    ("auto", "Auto"), ("best", "Highest available"), ("hd2160", "2160p (4K)"),
    ("hd1440", "1440p"), ("hd1080", "1080p"), ("hd720", "720p"), ("large", "480p"),
]

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
