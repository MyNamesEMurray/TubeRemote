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

    private init() { lines = UserDefaults.standard.stringArray(forKey: "log") ?? [] }

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
        .navigationTitle("Debug log")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Copy") { UIPasteboard.general.string = log.lines.joined(separator: "\n") }
                Button("Clear", role: .destructive) { log.clear() }
            }
        }
    }
}
