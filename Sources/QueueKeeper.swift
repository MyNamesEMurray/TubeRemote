import Foundation

/// Keeps the queue on the remote, so it survives closing the app and is not tied to one viewer. What the selected viewer
/// reports is saved: the playing video and where it had got to, and the queue. A viewer with nothing queued or playing
/// leaves the saved queue alone, and the remote offers to resume it (`ResumeQueueBar`).
final class QueueKeeper {
    private let settings: AppSettings

    init(settings: AppSettings) { self.settings = settings }

    /// A position moves every second; it is only worth writing again once it has moved this far.
    static let positionStep = 10.0

    /// Nil for an idle, empty viewer: that says nothing about what was saved. A video within ten seconds (or 5% of a short one) of its end counts as played.
    static func snapshot(_ st: ViewerState) -> SavedQueue? {
        if st.current == nil && st.queue.isEmpty { return nil }
        var current = st.current
        if st.duration > 0, st.position >= st.duration - min(10, st.duration * 0.05) { current = nil }
        current?.startAt = nil
        return SavedQueue(current: current, position: current == nil ? 0 : st.position, queue: st.queue)
    }

    static func shouldSave(saved: SavedQueue, new: SavedQueue) -> Bool {
        new.queue != saved.queue || new.current?.videoID != saved.current?.videoID
            || abs(new.position - saved.position) >= positionStep
    }

    /// `previous` is the last state of this same connection. A viewer that goes from active to idle while connected was
    /// emptied on purpose or finished, so nothing is left to resume.
    func observe(_ st: ViewerState, previous: ViewerState?, key: String) {
        guard settings.saveQueue, ProStore.shared.has(st), key == settings.lastViewerKey else { return }
        guard let new = Self.snapshot(st) else {
            if let previous, Self.snapshot(previous) != nil { settings.savedQueue = SavedQueue() }
            return
        }
        if Self.shouldSave(saved: settings.savedQueue, new: new) { settings.savedQueue = new }
    }
}
