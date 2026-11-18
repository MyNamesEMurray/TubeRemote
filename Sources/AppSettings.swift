import SwiftUI

final class AppSettings: ObservableObject {
    @Published var deviceName: String {
        didSet { UserDefaults.standard.set(deviceName, forKey: "deviceName") }
    }
    @Published var defaultMode: Mode {
        didSet { UserDefaults.standard.set(defaultMode.rawValue, forKey: "defaultMode") }
    }
    @Published var queueAction: QueueAction {
        didSet { UserDefaults.standard.set(queueAction.rawValue, forKey: "queueAction") }
    }
    /// Used by the viewer. A remote changes it by sending a command.
    @Published var preferredQuality: String {
        didSet { UserDefaults.standard.set(preferredQuality, forKey: "preferredQuality") }
    }
    /// Pro. The remote keeps the last queue it saw, whichever viewer it came from, and puts it on an empty viewer.
    @Published var saveQueue: Bool {
        didSet {
            UserDefaults.standard.set(saveQueue, forKey: "saveQueue")
            if !saveQueue { savedQueue = SavedQueue() }
        }
    }
    @Published var savedQueue: SavedQueue {
        didSet { Store.write("queue.json", try? JSONEncoder().encode(savedQueue)) }
    }
    /// Viewer: when the sleep timer ends, stop holding the screen awake so the device can lock by itself.
    @Published var lockOnSleep: Bool {
        didSet { UserDefaults.standard.set(lockOnSleep, forKey: "lockOnSleep") }
    }
    @Published var hasOnboarded: Bool {
        didSet { UserDefaults.standard.set(hasOnboarded, forKey: "hasOnboarded") }
    }
    @Published var paired: [PairedDevice] {
        didSet { Store.write("paired.json", try? JSONEncoder().encode(paired), backup: false) }
    }
    /// Stable per-install id, used to recognise a viewer even after it is renamed.
    let deviceKey: String

    func paired(_ key: String) -> PairedDevice? { paired.first { $0.key == key } }

    func addPaired(_ d: PairedDevice) {
        paired.removeAll { $0.key == d.key }
        paired.append(d)
    }

    var lastViewerKey: String? {
        get { UserDefaults.standard.string(forKey: "lastViewer") }
        set { UserDefaults.standard.set(newValue, forKey: "lastViewer") }
    }

    /// Never empty.
    var name: String {
        let t = deviceName.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? UIDevice.current.model : t
    }

    init() {
        let d = UserDefaults.standard
        deviceName = d.string(forKey: "deviceName") ?? UIDevice.current.name
        defaultMode = Mode(rawValue: d.string(forKey: "defaultMode") ?? "") ?? .remote
        queueAction = QueueAction(rawValue: d.string(forKey: "queueAction") ?? "") ?? .playNow
        preferredQuality = d.string(forKey: "preferredQuality") ?? "auto"
        saveQueue = d.object(forKey: "saveQueue") as? Bool ?? true
        let stored = Store.read("queue.json")
        savedQueue = stored.flatMap { try? JSONDecoder().decode(SavedQueue.self, from: $0) }
            ?? SavedQueue(queue: stored.flatMap { try? JSONDecoder().decode([VideoItem].self, from: $0) } ?? [])
        lockOnSleep = d.object(forKey: "lockOnSleep") as? Bool ?? true
        hasOnboarded = d.bool(forKey: "hasOnboarded")
        paired = Store.read("paired.json").flatMap { try? JSONDecoder().decode([PairedDevice].self, from: $0) } ?? []
        if let k = d.string(forKey: "deviceKey") {
            deviceKey = k
        } else {
            let k = String(UUID().uuidString.prefix(8))
            d.set(k, forKey: "deviceKey")
            deviceKey = k
        }
    }
}

extension AppSettings {
    /// Gives the share extension what it needs to reach a viewer. Written whenever the app comes or goes.
    func mirrorForShare(pro: Bool) {
        let ok = SharedConfig(deviceKey: deviceKey, deviceName: name, paired: paired, lastViewer: lastViewerKey,
                              queueAction: queueAction, pro: pro).write()
        if !ok { Log.add(SharedConfig.available ? "share: could not write the shared file" : "share: App Group not available to this build") }
    }
}

/// Small files in Application Support, readable after first unlock so a locked viewer can still authenticate.
enum Store {
    private static func url(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    static func read(_ name: String) -> Data? { try? Data(contentsOf: url(name)) }

    static func write(_ name: String, _ data: Data?, backup: Bool = true) {
        guard let data else { return }
        var u = url(name)
        try? data.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if !backup {
            var v = URLResourceValues()
            v.isExcludedFromBackup = true
            try? u.setResourceValues(v)
        }
    }
}
