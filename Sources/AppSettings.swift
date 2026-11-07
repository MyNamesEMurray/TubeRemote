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
    /// Stable per-install id, used to recognise a viewer even after it is renamed.
    let deviceKey: String

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
        if let k = d.string(forKey: "deviceKey") {
            deviceKey = k
        } else {
            let k = String(UUID().uuidString.prefix(8))
            d.set(k, forKey: "deviceKey")
            deviceKey = k
        }
    }
}
