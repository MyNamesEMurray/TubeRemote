import AVFoundation
import MediaPlayer
import UIKit

final class LockScreenControls {
    private(set) static var active = false

    var remoteRole = false
    private let settings: AppSettings
    private unowned let remote: RemoteController
    private var timer: Timer?
    private var player: AVAudioPlayer?
    private var avPlayer: AVPlayer?
    private var nowSession: MPNowPlayingSession?
    private var loopObs: NSObjectProtocol?
    private var sessionMode = false
    private var wired = false
    private var interruptObs: NSObjectProtocol?
    private var foregroundObs: NSObjectProtocol?
    private var yielded = false
    private var shownKey = ""
    private var shownPosition = 0.0
    private var shownAt = Date()
    private var artwork: MPMediaItemArtwork?
    private var artworkFor: String?

    init(settings: AppSettings, remote: RemoteController) {
        self.settings = settings
        self.remote = remote
    }

    func sync() {
        if remoteRole && settings.lockScreenControls {
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            interruptObs = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
                guard let self, Self.active || self.yielded, let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .began {
                    Log.add("lock screen controls: another app took the audio")
                    self.yielded = true
                    self.stopPlayback()
                } else if let o = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                          AVAudioSession.InterruptionOptions(rawValue: o).contains(.shouldResume) {
                    self.yielded = false
                    self.tick()
                }
            }
            foregroundObs = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.yielded = false
                self?.tick()
            }
            tick()
        } else {
            timer?.invalidate()
            timer = nil
            interruptObs.map(NotificationCenter.default.removeObserver)
            interruptObs = nil
            foregroundObs.map(NotificationCenter.default.removeObserver)
            foregroundObs = nil
            yielded = false
            stopPlayback()
        }
    }

    private func tick() {
        guard !yielded else { return }
        guard let c = remote.active, c.connected, let s = c.state, let cur = s.current, ProStore.shared.has(s) else { return stopPlayback() }
        if Self.active, sessionMode != settings.lockScreenPausesAudio { stopPlayback() }
        startPlayback(playing: s.isPlaying)
        wire()
        if nowSession == nil { center.playbackState = s.isPlaying ? .playing : .paused }
        let key = "\(cur.videoID)|\(s.isPlaying)|\(Int(s.duration))|\(artworkFor == cur.videoID)"
        let expected = shownPosition + (s.isPlaying ? Date().timeIntervalSince(shownAt) * (s.speed ?? 1) : 0)
        guard key != shownKey || abs(s.position - expected) > 1.5 else { return }
        shownKey = key
        shownPosition = s.position
        shownAt = Date()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: cur.title,
            MPMediaItemPropertyArtist: cur.channel,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: s.position,
            MPNowPlayingInfoPropertyPlaybackRate: s.isPlaying ? (s.speed ?? 1) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if s.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = s.duration }
        if artworkFor == cur.videoID, let artwork { info[MPMediaItemPropertyArtwork] = artwork } else { loadArtwork(cur) }
        center.nowPlayingInfo = info
        if nowSession == nil { center.playbackState = s.isPlaying ? .playing : .paused }
        Log.add("lock screen shows \(s.isPlaying ? "playing" : "paused") at \(Int(s.position))")
    }

    private func loadArtwork(_ item: VideoItem) {
        guard artworkFor != item.videoID else { return }
        artworkFor = item.videoID
        artwork = nil
        URLSession.shared.dataTask(with: item.thumbnailURL) { [weak self] data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self, self.artworkFor == item.videoID else { return }
                self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.shownKey = ""
            }
        }.resume()
    }

    private var center: MPNowPlayingInfoCenter { nowSession?.nowPlayingInfoCenter ?? MPNowPlayingInfoCenter.default() }
    private var commands: MPRemoteCommandCenter { nowSession?.remoteCommandCenter ?? MPRemoteCommandCenter.shared() }

    private func startPlayback(playing: Bool) {
        if !Self.active {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback)
            try? session.setActive(true)
            sessionMode = settings.lockScreenPausesAudio
            if sessionMode { startSession() } else {
                player = try? AVAudioPlayer(data: Self.silence())
                player?.numberOfLoops = -1
            }
            Self.active = true
            Log.add("lock screen controls on, \(sessionMode ? "system player" : "silent sound")")
        }
        if sessionMode {
            guard let avPlayer else { return }
            if playing, avPlayer.rate == 0 {
                avPlayer.play()
            } else if !playing, avPlayer.rate != 0 {
                avPlayer.pause()
                Log.add("lock screen controls: system player paused")
            }
        } else if player?.isPlaying != true {
            player?.play()
        }
    }

    private func startSession() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence.wav")
        try? Self.silence().write(to: url)
        let p = AVPlayer(url: url)
        p.actionAtItemEnd = .none
        p.volume = 1
        loopObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { [weak p] _ in
            p?.seek(to: .zero)
            p?.play()
        }
        avPlayer = p
        let session = MPNowPlayingSession(players: [p])
        session.automaticallyPublishesNowPlayingInfo = false
        session.becomeActiveIfPossible { ok in Log.add("now playing session active: \(ok)") }
        nowSession = session
    }

    private func stopPlayback() {
        guard Self.active else { return }
        Self.active = false
        unwire()
        center.nowPlayingInfo = nil
        player?.stop()
        player = nil
        avPlayer?.pause()
        avPlayer = nil
        nowSession = nil
        loopObs.map(NotificationCenter.default.removeObserver)
        loopObs = nil
        shownKey = ""
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        Log.add("lock screen controls off")
    }

    private func wire() {
        guard !wired else { return }
        wired = true
        let cc = commands
        func add(_ command: MPRemoteCommand, _ make: @escaping (MPRemoteCommandEvent, ViewerState) -> Command?) {
            command.isEnabled = true
            command.addTarget { [weak self] event in
                guard let c = self?.remote.active, c.connected, let s = c.state, let cmd = make(event, s) else { return .commandFailed }
                Log.add("lock screen \(cmd.logName)")
                c.send(cmd)
                return .success
            }
        }
        let skip = Double(settings.skipSeconds)
        cc.skipForwardCommand.preferredIntervals = [NSNumber(value: skip)]
        cc.skipBackwardCommand.preferredIntervals = [NSNumber(value: skip)]
        add(cc.playCommand) { _, _ in .resume }
        add(cc.pauseCommand) { _, _ in .pause }
        add(cc.togglePlayPauseCommand) { _, s in s.isPlaying ? .pause : .resume }
        add(cc.nextTrackCommand) { _, _ in .next }
        add(cc.previousTrackCommand) { _, _ in .previous }
        add(cc.skipForwardCommand) { _, _ in .skip(skip) }
        add(cc.skipBackwardCommand) { _, _ in .skip(-skip) }
        add(cc.changePlaybackPositionCommand) { e, _ in (e as? MPChangePlaybackPositionCommandEvent).map { .seek($0.positionTime) } }
    }

    private func unwire() {
        guard wired else { return }
        wired = false
        let cc = commands
        [cc.playCommand, cc.pauseCommand, cc.togglePlayPauseCommand, cc.nextTrackCommand, cc.previousTrackCommand,
         cc.skipForwardCommand, cc.skipBackwardCommand, cc.changePlaybackPositionCommand].forEach {
            $0.removeTarget(nil)
            $0.isEnabled = false
        }
    }

    private static func silence() -> Data {
        let rate: UInt32 = 8000
        let bytes = rate * 2
        var d = Data("RIFF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        u32(36 + bytes)
        d.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(Data("data".utf8))
        u32(bytes)
        d.append(Data(count: Int(bytes)))
        return d
    }
}
