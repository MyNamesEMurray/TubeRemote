import CryptoKit
import Foundation
import Network

/// One connection to one viewer. Reconnects forever until stop().
final class RemoteClient: ObservableObject, Identifiable {
    let key: String
    @Published var name: String
    @Published var state: ViewerState?
    @Published var connected = false
    @Published var detail = ""
    @Published var needsPairing = false
    var endpoints: [NWEndpoint]
    private var attempt = 0
    var id: String { key }
    var title: String { state?.deviceName ?? name }

    private let settings: AppSettings
    private let pairing: Pairing
    private var conn: NWConnection?
    private var ready = false
    private var lastActivity = Date()
    private var watchdog: Timer?
    private var keepalive: Timer?
    private var stopped = false
    private var retryPending = false

    init(key: String, name: String, endpoints: [NWEndpoint], settings: AppSettings, pairing: Pairing) {
        self.key = key
        self.name = name
        self.endpoints = endpoints
        self.settings = settings
        self.pairing = pairing
        // The viewer broadcasts at least once a second; silence means the link is dead.
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.conn != nil, Date().timeIntervalSince(self.lastActivity) > (self.connected ? 6 : 20) else { return }
            self.drop()
        }
        keepalive = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.sendRaw(.ping)
        }
    }

    func connect() {
        guard !stopped, conn == nil else { return }
        retryPending = false
        lastActivity = Date()
        // shortcut: a renamed or stale Bonjour twin may share the key, so rotate endpoints on each retry
        let endpoint = endpoints[attempt % endpoints.count]
        attempt += 1
        let c = NWConnection(to: endpoint, using: Transport.parameters())
        Log.add("connecting to \(title) at \(endpoint)")
        conn = c
        c.stateUpdateHandler = { [weak self, weak c] s in
            guard let self, let c, c === self.conn else { return }
            Log.add("outbound \(self.title): \(s)")
            switch s {
            case .ready:
                self.ready = true
                Transport.send(ClientMessage.hello(name: self.settings.name, key: self.settings.deviceKey), on: c)
                Transport.receiveLoop(c, as: ServerMessage.self, onMessage: { [weak self] m in
                    guard let self, c === self.conn else { return }
                    self.lastActivity = Date()
                    self.handle(m)
                }, onEnd: { [weak self] in
                    if let self, c === self.conn { self.drop() }
                })
            case .failed(let e):
                self.detail = "failed: \(e)"
                self.drop()
            case .cancelled:
                self.drop()
            case .waiting(let e):
                self.detail = "waiting: \(e)"
            default:
                break
            }
        }
        c.start(queue: .main)
    }

    var isPaired: Bool { settings.paired(key) != nil }

    func beginPair() {
        pairing.begin { [weak self] in self?.sendRaw(.pair($0)) }
    }

    private func handle(_ m: ServerMessage) {
        switch m {
        case .state(let st):
            if !connected { Log.add("first state from \(title)") }
            state = st
            connected = true
            needsPairing = false
            detail = ""
        case .unpaired:
            connected = false
            needsPairing = true
            detail = ""
        case .challenge(let nonce):
            guard let d = settings.paired(key) else { return }
            let mac = HMAC<SHA256>.authenticationCode(for: nonce, using: SymmetricKey(data: d.secret))
            sendRaw(.auth(Data(mac)))
        case .pair(let pm):
            pairing.receive(pm) { [weak self] in self?.sendRaw(.pair($0)) }
        }
    }

    private func sendRaw(_ m: ClientMessage) {
        guard ready, let conn else { return }
        Transport.send(m, on: conn)
    }

    func send(_ cmd: Command) {
        guard connected else { return Log.add("send \(cmd) dropped: not connected") }
        Log.add("send \(cmd)")
        sendRaw(.command(cmd))
    }

    func stop() {
        stopped = true
        watchdog?.invalidate()
        keepalive?.invalidate()
        conn?.cancel()
        conn = nil
        ready = false
        connected = false
    }

    private func drop() {
        Log.add("drop \(title)")
        let old = conn
        conn = nil
        old?.cancel()
        ready = false
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
    @Published var groupKeys: Set<String> = []
    var active: RemoteClient? { devices.first { $0.key == selectedKey } }
    var targets: [RemoteClient] {
        let g = devices.filter { groupKeys.contains($0.key) && $0.connected }
        return g.isEmpty ? active.map { [$0] } ?? [] : g
    }

    private var clients: [String: RemoteClient] = [:]
    private var missing: [String: Date] = [:]
    private var browser: NWBrowser?
    private let settings: AppSettings
    private let pairing: Pairing

    init(settings: AppSettings, pairing: Pairing) {
        self.settings = settings
        self.pairing = pairing
        selectedKey = settings.lastViewerKey
    }

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: Transport.serviceType, domain: nil), using: .tcp)
        b.stateUpdateHandler = { [weak self] s in
            Log.add("browser \(s)")
            if case .failed = s { self?.stop() }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Log.add("browse results: \(results.map { "\($0.endpoint)" })")
            self?.update(results)
        }
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
        var found: [String: (name: String, endpoints: [NWEndpoint])] = [:]
        for r in results {
            if case let .service(name, _, _, _) = r.endpoint {
                let p = Self.split(name)
                var f = found[p.key] ?? (name: p.name, endpoints: [])
                f.endpoints.append(r.endpoint)
                if p.name.count < f.name.count { f.name = p.name }
                f.endpoints.sort { "\($0)" < "\($1)" }
                found[p.key] = f
            }
        }
        for (k, v) in found {
            missing[k] = nil
            if let c = clients[k] {
                c.name = v.name
                c.endpoints = v.endpoints
            } else {
                let c = RemoteClient(key: k, name: v.name, endpoints: v.endpoints, settings: settings, pairing: pairing)
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
