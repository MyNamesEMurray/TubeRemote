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

    /// The log is cleared on the first launch after a normal exit and kept after a crash. The app counts as
    /// exited cleanly once it reaches the background, which is where a swipe-away from the app switcher happens,
    /// and as running again as soon as it is active.
    private init() {
        let d = UserDefaults.standard
        lines = d.bool(forKey: Self.cleanKey) ? [] : (d.stringArray(forKey: "log") ?? [])
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
        DispatchQueue.main.async { shared.append("\(fmt.string(from: Date())) \(tag) \(s)") }
    }

    func clear() { lines = []; save() }

    private func append(_ s: String) {
        lines = Array((lines + [s]).suffix(300))
    }

    /// Called when the app leaves the foreground; writing on every line stalls the main thread.
    func save() { UserDefaults.standard.set(lines, forKey: "log") }
}

struct DebugLogView: View {
    @ObservedObject var log = Log.shared

    var body: some View {
        ScrollView {
            Text(log.lines.isEmpty ? "No entries" : log.lines.joined(separator: "\n"))
                .font(.system(size: 10, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle("Debug Log")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Copy") { UIPasteboard.general.string = log.lines.joined(separator: "\n") }
                Button("Clear", role: .destructive) { log.clear() }
            }
        }
    }
}
