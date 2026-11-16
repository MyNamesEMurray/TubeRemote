import Foundation

/// Keeps the queue on the remote, so it survives closing the app and is not tied to one viewer. Whatever queue the
/// selected viewer reports is saved. A viewer with nothing queued or playing leaves the saved queue alone, and the
/// remote offers to resume it (`ResumeQueueBar`).
final class QueueKeeper {
    private let settings: AppSettings

    init(settings: AppSettings) { self.settings = settings }

    static func shouldSave(saved: [VideoItem], viewerQueue: [VideoItem], idle: Bool) -> Bool {
        !(idle && viewerQueue.isEmpty) && viewerQueue != saved
    }

    func observe(_ st: ViewerState, key: String) {
        guard settings.saveQueue, ProStore.shared.has(st), key == settings.lastViewerKey,
              Self.shouldSave(saved: settings.savedQueue, viewerQueue: st.queue, idle: st.current == nil) else { return }
        settings.savedQueue = st.queue
    }
}
