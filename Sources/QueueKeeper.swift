import Foundation

/// Keeps the queue on the remote, so it survives closing the app and is not tied to one viewer. Whatever queue the
/// selected viewer reports is saved; a viewer that has nothing queued or playing when this remote signs in gets it back.
final class QueueKeeper {
    enum Plan: Equatable { case restore, save, none }

    private let settings: AppSettings
    /// Just after a restore the viewer may still report an empty queue; that must not wipe what was saved.
    private var holdUntil = Date.distantPast

    init(settings: AppSettings) { self.settings = settings }

    static func plan(saved: [VideoItem], viewerQueue: [VideoItem], idle: Bool, first: Bool, holding: Bool) -> Plan {
        if first, idle, viewerQueue.isEmpty, !saved.isEmpty { return .restore }
        if holding, viewerQueue.isEmpty { return .none }
        return viewerQueue == saved ? .none : .save
    }

    func observe(_ st: ViewerState, from c: RemoteClient, first: Bool) {
        guard settings.saveQueue, ProStore.shared.has(st), c.key == settings.lastViewerKey else { return }
        switch Self.plan(saved: settings.savedQueue, viewerQueue: st.queue, idle: st.current == nil, first: first,
                         holding: Date() < holdUntil) {
        case .restore:
            holdUntil = Date().addingTimeInterval(3)
            c.send(.restoreQueue(settings.savedQueue))
        case .save:
            settings.savedQueue = st.queue
        case .none:
            break
        }
    }
}
