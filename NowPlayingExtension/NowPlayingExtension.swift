import ExtensionFoundation
import Foundation
import NowPlaying
import Observation

@main
struct TubeRemoteNowPlaying: RemoteMediaSessionExtension {
    init() {
        Log.tag = "N"
        Log.add("np extension started")
    }

    var configuration: RemoteMediaSessionExtensionConfiguration<Self> {
        RemoteMediaSessionExtensionConfiguration(extension: self)
    }

    func session(_ attributes: NowPlayingAttributes) async throws -> ViewerSession {
        ViewerSession(attributes: attributes)
    }
}

@MainActor
@Observable
final class ViewerSession: RemoteMediaSessionRepresentable {
    let id: String
    var attributes: NowPlayingAttributes
    @ObservationIgnored private let link: ViewerLink

    init(attributes: NowPlayingAttributes) {
        id = attributes.id
        self.attributes = attributes
        Log.add("np session created for \(Log.who(attributes.id)), skip \(Int(attributes.skip))")
        link = ViewerLink(key: attributes.id)
        link.onState = { [weak self] state in self?.apply(state) }
        link.maintain()
    }

    func update(_ attributes: NowPlayingAttributes) {
        Log.add("np update from the app: \(attributes.isPlaying ? "playing" : "paused") at \(Int(attributes.position)), skip \(Int(attributes.skip))")
        self.attributes = attributes
    }

    private var livePosition: Double {
        attributes.isPlaying ? attributes.position + Date().timeIntervalSince(attributes.timestamp) * Double(attributes.speed) : attributes.position
    }

    private func settle(isPlaying: Bool? = nil, position: Double? = nil) {
        var a = attributes
        a.position = position ?? livePosition
        if let isPlaying { a.isPlaying = isPlaying }
        a.timestamp = Date()
        attributes = a
    }

    private func apply(_ s: ViewerState) {
        if s.current?.videoID != attributes.videoID || s.isPlaying != attributes.isPlaying {
            Log.add("np state from the viewer: \(s.isPlaying ? "playing" : "paused") at \(Int(s.position)), \(s.current?.videoID != attributes.videoID ? "new video" : "same video")")
        }
        var a = attributes
        a.isPlaying = s.isPlaying
        a.position = s.position
        a.timestamp = Date()
        a.duration = s.duration
        a.speed = Float(s.speed ?? 1)
        a.live = s.live == true
        a.volume = s.volume
        if let cur = s.current {
            a.videoID = cur.videoID
            a.title = cur.title
            a.channel = cur.channel
        }
        attributes = a
    }

    var playbackSnapshot: MediaPlaybackSnapshot? {
        MediaPlaybackSnapshot(
            state: attributes.isPlaying ? .playing(rate: attributes.speed) : .paused,
            elapsedTime: attributes.position,
            timestamp: attributes.timestamp)
    }

    var content: (any MediaContentRepresentable)? {
        let a = attributes
        guard !a.videoID.isEmpty, let url = URL(string: "https://i.ytimg.com/vi/\(a.videoID)/mqdefault.jpg") else { return nil }
        return GenericContent(
            id: a.videoID, title: a.title, subtitle: a.channel, type: .video,
            duration: a.live ? .live : (a.duration > 0 ? .finite(a.duration) : .continuous),
            artwork: Artwork(id: a.videoID) { _ in
                let (data, _) = try await URLSession.shared.data(from: url)
                return try ArtworkRepresentation(data: data)
            })
    }

    var commands: [MediaCommand] {
        let skip = attributes.skip
        return [
            .play {
                try await self.link.send(.resume)
                self.settle(isPlaying: true)
            },
            .pause {
                try await self.link.send(.pause)
                self.settle(isPlaying: false)
            },
            .togglePlayPause {
                let playing = self.attributes.isPlaying
                try await self.link.send(playing ? .pause : .resume)
                self.settle(isPlaying: !playing)
            },
            .next { try await self.link.send(.next) },
            .previous { try await self.link.send(.previous) },
            .skipForward(preferredIntervals: [skip]) { by in
                try await self.link.send(.skip(by))
                self.settle(position: self.livePosition + by)
            },
            .skipBackward(preferredIntervals: [skip]) { by in
                try await self.link.send(.skip(-by))
                self.settle(position: max(self.livePosition - by, 0))
            },
            .seekToPosition { time in
                try await self.link.send(.seek(time))
                self.settle(position: time)
            },
        ]
    }

    var devices: [MediaDevice] {
        let a = attributes
        return [
            MediaDevice(id: a.id, name: a.viewerName, type: .tablet, capabilities: [
                .absoluteVolume(a.volume) { level in
                    try await self.link.send(.setVolume(level))
                    await MainActor.run { self.attributes.volume = level }
                },
            ]),
        ]
    }
}
