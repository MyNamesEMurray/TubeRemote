import AVFoundation
import MediaPlayer
import UIKit

/// While Now Playing is open, the phone's volume buttons change the viewer's volume instead of the phone's.
/// iOS has no API for the buttons themselves, so this watches the phone's volume, reports which way it
/// moved, and puts it straight back. `view` must be on screen: it hides the system volume overlay.
final class VolumeKeys {
    let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    private var obs: NSKeyValueObservation?
    private var notes: [NSObjectProtocol] = []
    private var original: Float = 0.5
    private var base: Float = 0.5
    private var onStep: ((Float) -> Void)?
    private var quietUntil = Date.distantPast

    func start(onStep: @escaping (Float) -> Void) {
        self.onStep = onStep
        let nc = NotificationCenter.default
        notes = [
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.listen()
            },
            nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.release()
            },
        ]
        listen()
    }

    func stop() {
        notes.forEach(NotificationCenter.default.removeObserver)
        notes = []
        release()
        onStep = nil
    }

    private func listen() {
        guard obs == nil else { return }
        let session = AVAudioSession.sharedInstance()
        // Volume changes are only reported to an active session; ambient does not interrupt other audio.
        if !LockScreenControls.active && !KeepAlive.active { try? session.setCategory(.ambient) }
        try? session.setActive(true)
        original = session.outputVolume
        base = original
        quietUntil = Date().addingTimeInterval(1.5)
        Log.add("volume keys on, phone volume \(Int((original * 100).rounded()))%")
        obs = session.observe(\.outputVolume) { [weak self] s, _ in
            let v = s.outputVolume
            DispatchQueue.main.async {
                guard let self, self.obs != nil, abs(v - self.base) > 0.01 else { return }
                // The phone's own volume settles right after the session starts and when it is held inside the ends; that is not a key press.
                if Date() < self.quietUntil {
                    Log.add("volume keys: ignored a settling change \(Int((self.base * 100).rounded()))% to \(Int((v * 100).rounded()))%")
                    self.base = v
                    return
                }
                self.onStep?(v > self.base ? 0.0625 : -0.0625)
                self.set(self.base)
            }
        }
        // shortcut: at full or zero volume one button reports nothing, so the phone is held just inside
        // the ends while this is active and put back afterwards. The slider only exists once laid out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.obs != nil else { return }
            let inside = min(max(self.original, 0.125), 0.875)
            if inside != self.original, self.set(inside) { self.base = inside }
        }
    }

    private func release() {
        guard obs != nil else { return }
        obs = nil
        set(original)
    }

    @discardableResult
    private func set(_ v: Float) -> Bool {
        guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return false }
        slider.setValue(v, animated: false)
        slider.sendActions(for: .touchUpInside)
        return true
    }
}
