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
            if session != nil { Task { await endSession() } }
            return
        }
        let a = NowPlayingAttributes(
            id: c.key, viewerName: c.title, videoID: cur.videoID, title: cur.title, channel: cur.channel,
            isPlaying: s.isPlaying, position: s.position, timestamp: Date(), duration: s.duration,
            speed: Float(s.speed ?? 1), live: s.live == true, volume: s.volume, skip: Double(settings.skipSeconds))
        let key = "\(a.id)|\(a.videoID)|\(a.isPlaying)|\(Int(a.duration))|\(Int(a.volume * 100))"
        let expected = sentPosition + (a.isPlaying ? Date().timeIntervalSince(sentAt) * Double(a.speed) : 0)
        guard session == nil || key != sentKey || abs(a.position - expected) > 1.5 else { return }
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
