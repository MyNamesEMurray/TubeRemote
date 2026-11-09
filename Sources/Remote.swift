import Foundation
import Network

/// One connection to one viewer. Reconnects forever until stop().
final class RemoteClient: ObservableObject, Identifiable {
    let key: String
    @Published var name: String
    @Published var state: ViewerState?
    @Published var connected = false
    var endpoint: NWEndpoint
    var id: String { key }
    var title: String { state?.deviceName ?? name }

    private let myName: () -> String
    private var conn: NWConnection?
    private var lastActivity = Date()
    private var watchdog: Timer?
    private var keepalive: Timer?
    private var stopped = false
    private var retryPending = false

    init(key: String, name: String, endpoint: NWEndpoint, myName: @escaping () -> String) {
        self.key = key
        self.name = name
        self.endpoint = endpoint
        self.myName = myName
        // The viewer broadcasts at least once a second; silence means the link is dead.
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.conn != nil, Date().timeIntervalSince(self.lastActivity) > 6 else { return }
            self.drop()
        }
        // shortcut: hello resend doubles as ping; the viewer answers with a snapshot
        keepalive = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.connected, let c = self.conn else { return }
            Transport.send(ClientMessage.hello(name: self.myName()), on: c)
        }
    }

    func connect() {
        guard !stopped, conn == nil else { return }
        retryPending = false
        lastActivity = Date()
        let c = NWConnection(to: endpoint, using: Transport.parameters())
        conn = c
        c.stateUpdateHandler = { [weak self, weak c] s in
            guard let self, let c, c === self.conn else { return }
            switch s {
            case .ready:
                Transport.send(ClientMessage.hello(name: self.myName()), on: c)
                Transport.receiveLoop(c, as: ViewerState.self, onMessage: { [weak self] st in
                    guard let self, c === self.conn else { return }
                    self.lastActivity = Date()
                    self.state = st
                    self.connected = true
                }, onEnd: { [weak self] in
                    if let self, c === self.conn { self.drop() }
                })
            case .failed, .cancelled:
                self.drop()
            default:
                break
            }
        }
        c.start(queue: .main)
    }

    func send(_ cmd: Command) {
        guard connected, let conn else { return }
        Transport.send(ClientMessage.command(cmd), on: conn)
    }

    func stop() {
        stopped = true
        watchdog?.invalidate()
        keepalive?.invalidate()
        conn?.cancel()
        conn = nil
        connected = false
    }

    private func drop() {
        let old = conn
        conn = nil
        old?.cancel()
        connected = false
        guard !stopped, !retryPending else { return }
        retryPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connect() }
    }
}

/// Browses Bonjour for viewers and keeps a client per viewer, so the picker shows live status.
final class RemoteController: ObservableObject {
    @Published var devices: [RemoteClient] = []
    @Published var selectedKey: String? {
        didSet { settings.lastViewerKey = selectedKey }
    }
    var active: RemoteClient? { devices.first { $0.key == selectedKey } }

    private var clients: [String: RemoteClient] = [:]
    private var missing: [String: Date] = [:]
    private var browser: NWBrowser?
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        selectedKey = settings.lastViewerKey
    }

    func start() {
        stop()
        let b = NWBrowser(for: .bonjour(type: Transport.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.update(results) }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
        clients.values.forEach { $0.stop() }
        clients = [:]
        missing = [:]
        devices = []
    }

    func select(_ c: RemoteClient) { selectedKey = c.key }

    /// Bonjour service names are "<device name>#<device key>".
    private static func split(_ s: String) -> (name: String, key: String) {
        guard let r = s.range(of: "#", options: .backwards) else { return (s, s) }
        return (String(s[..<r.lowerBound]), String(s[r.upperBound...]))
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var found: [String: (name: String, endpoint: NWEndpoint)] = [:]
        for r in results {
            if case let .service(name, _, _, _) = r.endpoint {
                let p = Self.split(name)
                found[p.key] = (p.name, r.endpoint)
            }
        }
        for (k, v) in found {
            missing[k] = nil
            if let c = clients[k] {
                c.name = v.name
                c.endpoint = v.endpoint
            } else {
                let c = RemoteClient(key: k, name: v.name, endpoint: v.endpoint,
                                     myName: { [weak self] in self?.settings.name ?? "Remote" })
                clients[k] = c
                c.connect()
            }
        }
        for k in clients.keys where found[k] == nil && missing[k] == nil {
            let t = Date()
            missing[k] = t
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, self.missing[k] == t else { return }
                self.missing[k] = nil
                self.clients[k]?.stop()
                self.clients[k] = nil
                self.devices.removeAll { $0.key == k }
            }
        }
        devices = clients.values.sorted { $0.name < $1.name }
        if selectedKey == nil, devices.count == 1 { selectedKey = devices[0].key }
    }
}
