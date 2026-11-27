import AVFoundation
import NowPlaying
import UIKit

@available(iOS 27.0, *)
@MainActor
final class NowPlayingBridge {
    private let settings: AppSettings
    private let remote: RemoteController
    private var loop: Task<Void, Never>?
    private var session: RemoteMediaSession<NowPlayingAttributes>?
    private var busy = false
    private var sentKey = ""
    private var sentPosition = 0.0
    private var sentAt = Date()
    private var foregroundObs: NSObjectProtocol?
    private var keepAlive: AVAudioPlayer?
    private var lastReason = ""

    init(settings: AppSettings, remote: RemoteController) {
        self.settings = settings
        self.remote = remote
    }

    func sync(on: Bool) {
        if on {
            guard loop == nil else { return }
            loop = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.tick()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            foregroundObs = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                NowPlayingMailbox.markActive()
                Task { @MainActor in await self?.makePrimary() }
            }
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
                                            { _, observer, _, _, _ in
                guard let observer else { return }
                let bridge = Unmanaged<NowPlayingBridge>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in bridge.drainMailbox() }
            }, NowPlayingMailbox.notification as CFString, nil, .deliverImmediately)
        } else {
            loop?.cancel()
            loop = nil
            foregroundObs.map(NotificationCenter.default.removeObserver)
            foregroundObs = nil
            CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
                                               CFNotificationName(NowPlayingMailbox.notification as CFString), nil)
            Task { await endSession() }
        }
    }

    func drainMailbox() {
        for command in NowPlayingMailbox.take() {
            guard let c = remote.active, c.connected else { continue }
            Log.add("now playing command \(command.logName)")
            if case .setVolume(let v) = command { c.setVolume(v) } else { c.send(command) }
        }
    }

    private func startKeepAlive() {
        if keepAlive == nil {
            let audio = AVAudioSession.sharedInstance()
            try? audio.setCategory(.playback, options: [.mixWithOthers])
            try? audio.setActive(true)
            keepAlive = try? AVAudioPlayer(data: LockScreenControls.silence())
            keepAlive?.numberOfLoops = -1
            KeepAlive.active = true
            Log.add("now playing keep-alive sound on")
        }
        if keepAlive?.isPlaying != true { keepAlive?.play() }
    }

    private func stopKeepAlive() {
        guard keepAlive != nil else { return }
        keepAlive?.stop()
        keepAlive = nil
        KeepAlive.active = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        Log.add("now playing keep-alive sound off")
    }

    private func tick() {
        NowPlayingMailbox.markActive()
        if keepAlive != nil { startKeepAlive() }
        guard !busy else { return }
        guard let c = remote.active, c.connected, let s = c.state, let cur = s.current, ProStore.shared.has(s) else {
            let reason = remote.active == nil ? "no viewer selected" : remote.active?.connected != true ? "viewer not connected"
                : remote.active?.state == nil ? "no state from the viewer yet" : remote.active?.state?.current == nil ? "nothing playing"
                : "Pro is off"
            if reason != lastReason {
                lastReason = reason
                Log.add("now playing idle: \(reason)")
            }
            if session != nil { Task { await endSession() } }
            return
        }
        lastReason = ""
        let a = NowPlayingAttributes(
            id: c.key, viewerName: c.title, videoID: cur.videoID, title: cur.title, channel: cur.channel,
            isPlaying: s.isPlaying, position: s.position, timestamp: Date(), duration: s.duration,
            speed: Float(s.speed ?? 1), live: s.live == true, volume: s.volume, skip: Double(settings.skipSeconds))
        let key = "\(a.id)|\(a.videoID)|\(a.isPlaying)|\(Int(a.duration))|\(Int(a.volume * 100))|\(Int(a.skip))|\(Int(a.speed * 100))|\(a.live)"
        let expected = sentPosition + (a.isPlaying ? Date().timeIntervalSince(sentAt) * Double(a.speed) : 0)
        guard session == nil || key != sentKey || abs(a.position - expected) > 1.5 else { return }
        let names = ["viewer", "video", "playing", "length", "volume", "skip", "speed", "live"]
        let changed = zip(names, zip(key.split(separator: "|", omittingEmptySubsequences: false),
                                      sentKey.split(separator: "|", omittingEmptySubsequences: false)))
            .filter { $0.1.0 != $0.1.1 }.map(\.0)
        let why = session == nil ? "starting" : changed.isEmpty ? "position drifted by \(Int(a.position - expected)) s" : changed.joined(separator: ", ")
        Log.add("now playing push (\(why)): \(a.isPlaying ? "playing" : "paused") at \(Int(a.position)) of \(Int(a.duration)), skip \(Int(a.skip)), speed \(a.speed), volume \(Int(a.volume * 100))")
        busy = true
        Task {
            await push(a, key: key)
            busy = false
        }
    }

    private func push(_ a: NowPlayingAttributes, key: String) async {
        do {
            if session == nil {
                session = try await RemoteMediaSession<NowPlayingAttributes>.sessions().first { $0.id == a.id }
            }
            if let session {
                try await session.update(a)
            } else {
                let started = try await RemoteMediaSession<NowPlayingAttributes>.start(attributes: a)
                session = started
                Log.add("now playing session started")
                await makePrimary()
            }
            sentKey = key
            sentPosition = a.position
            sentAt = a.timestamp
            startKeepAlive()
        } catch {
            Log.add("now playing session failed: \(error)")
            session = nil
        }
    }

    private func makePrimary() async {
        guard let session, !session.isSystemPrimary, UIApplication.shared.applicationState == .active else { return }
        do {
            try await session.requestToBecomeSystemPrimary()
            Log.add("now playing session is primary")
        } catch {
            Log.add("now playing primary request failed: \(error)")
        }
    }

    private func endSession() async {
        guard let s = session else { return }
        session = nil
        sentKey = ""
        stopKeepAlive()
        try? await s.end()
        Log.add("now playing session ended")
    }
}
