import SwiftUI

final class Log: ObservableObject {
    static let shared = Log()
    static var tag = "?"
    @Published private(set) var lines: [String]
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let cleanKey = "logCleanExit"
    private static let inExtension = Bundle.main.bundlePath.hasSuffix(".appex")

    private static var extensionLogURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedConfig.group)?
            .appendingPathComponent("nowplaying", isDirectory: true).appendingPathComponent("extension.log")
    }

    /// What the extensions wrote, one line each, for the app's log to show beside its own.
    static func extensionLines() -> [String] {
        guard let url = extensionLogURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    private static func writeForApp(_ line: String) {
        guard let url = extensionLogURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lines = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        lines.append(line)
        try? (lines.suffix(200).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static var header: String {
        let info = Bundle.main.infoDictionary
        var sys = utsname()
        uname(&sys)
        let model = withUnsafePointer(to: &sys.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
        return "TubeRemote \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?")), iOS \(UIDevice.current.systemVersion), \(model)"
    }

    /// The log is cleared on the first launch after a normal exit and kept after a crash. The app counts as
    /// exited cleanly once it reaches the background, which is where a swipe-away from the app switcher happens,
    /// and as running again as soon as it is active.
    private init() {
        let d = UserDefaults.standard
        lines = d.bool(forKey: Self.cleanKey) ? [] : (d.stringArray(forKey: "log") ?? [])
        if d.bool(forKey: Self.cleanKey), !Self.inExtension, let url = Self.extensionLogURL { try? FileManager.default.removeItem(at: url) }
        d.set(false, forKey: Self.cleanKey)
        save()
    }

    /// Names, titles and addresses stay out of the log. A device appears as the last four characters of its
    /// random key, which tells two devices apart and nothing more.
    static func who(_ key: String?) -> String { key.map { "device \($0.suffix(4))" } ?? "a device" }

    func setCleanExit(_ clean: Bool) {
        UserDefaults.standard.set(clean, forKey: Self.cleanKey)
        save()
    }

    static func add(_ s: String) {
        DispatchQueue.main.async {
            let line = "\(fmt.string(from: Date())) \(tag) \(s)"
            shared.append(line)
            if inExtension { writeForApp(line) }
        }
    }

    func clear() {
        lines = []
        save()
        if let url = Self.extensionLogURL { try? FileManager.default.removeItem(at: url) }
    }

    private func append(_ s: String) {
        lines = Array((lines + [s]).suffix(300))
    }

    /// Called when the app leaves the foreground; writing on every line stalls the main thread.
    func save() { UserDefaults.standard.set(lines, forKey: "log") }
}

struct DebugLogView: View {
    @ObservedObject var log = Log.shared

    private var text: String {
        let merged = (log.lines + Log.extensionLines()).enumerated()
            .sorted { ($0.element.prefix(12), $0.offset) < ($1.element.prefix(12), $1.offset) }.map(\.element)
        return Log.header + "\n" + (merged.isEmpty ? "No entries" : merged.joined(separator: "\n"))
    }

    var body: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                Text(text)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Debug Log")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Copy") { UIPasteboard.general.string = text }
                Button("Clear", role: .destructive) { log.clear() }
            }
        }
    }
}
