import Combine
import CryptoKit
import Foundation
import Network

final class RemoteClient: ObservableObject, Identifiable {
    let key: String
    @Published var name: String
    @Published var state: ViewerState?
    @Published var details: VideoDetails?
    private var lists: (queue: [VideoItem], history: [VideoItem]) = ([], [])

    private var volumeHold: (value: Float, until: Date)?
    private var brightnessHold: (value: Float, until: Date)?

    func setBrightness(_ v: Float) {
        brightnessHold = (v, Date().addingTimeInterval(1.5))
        state?.brightness = v
        send(.setBrightness(v))
    }

    func setVolume(_ v: Float) {
        volumeHold = (v, Date().addingTimeInterval(1.5))
        state?.volume = v
        send(.setVolume(v))
    }

    func setQueue(_ q: [VideoItem]) {
        lists.queue = q
        state?.queue = q
    }
    @Published var connected = false
    @Published var detail = ""
    @Published var needsPairing = false
    @Published var outdated = false
    @Published var released = false
    @Published var busy = false
    var endpoints: [NWEndpoint]
    private var attempt = 0
    var id: String { key }
    var title: String { state?.deviceName ?? name }
    private var tag: String { Log.who(key) }

    private let settings: AppSettings
    private let pairing: Pairing
    private let keeper: QueueKeeper?
    private var conn: NWConnection?
    private var ready = false
    private var channel: Channel?
    private var peerVersion: Int?
    private var lastActivity = Date()
    private var watchdog: Timer?
    private var keepalive: Timer?
    private var stopped = false
    private var retryPending = false

    init(key: String, name: String, endpoints: [NWEndpoint], settings: AppSettings, pairing: Pairing,
         state: ViewerState? = nil, keeper: QueueKeeper? = nil) {
        self.state = state
        self.keeper = keeper
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
        guard !stopped, !released, conn == nil else { return }
        retryPending = false
        lastActivity = Date()
        peerVersion = nil
        // shortcut: a renamed or stale Bonjour twin may share the key, so rotate endpoints on each retry
        let endpoint = endpoints[attempt % endpoints.count]
        attempt += 1
        let c = NWConnection(to: endpoint, using: Transport.parameters())
        Log.add("connecting to \(tag)")
        conn = c
        c.stateUpdateHandler = { [weak self, weak c] s in
            guard let self, let c, c === self.conn else { return }
            Log.add("outbound \(self.tag): \(s)")
            switch s {
            case .ready:
                self.ready = true
                Transport.send(ClientMessage.hello(name: self.settings.name, key: self.settings.deviceKey,
                                                   version: Transport.version, pro: ProStore.shared.isPro), on: c)
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

    func reconnect() {
        guard released || busy else { return }
        released = false
        busy = false
        connect()
    }

    func refresh() {
        guard !released else { return }
        busy = false
        drop()
    }

    func beginPair() {
        pairing.begin(peer: key) { [weak self] in self?.sendRaw(.pair($0)) }
    }

    private func sameVersion() -> Bool {
        if peerVersion == nil { outdated = true }
        return !outdated
    }

    private func handle(_ m: ServerMessage) {
        switch m {
        case .hello(let v):
            peerVersion = v
            outdated = v != Transport.version
        case .sealed(let box):
            guard let body = channel?.open(box) else {
                Log.add("bad encrypted message from \(tag)")
                return drop()
            }
            switch try? JSONDecoder().decode(ServerMessage.self, from: body) {
            case .lists(let q, let h)?:
                lists = (q, h)
            case .state(var st)?:
                st.queue = lists.queue
                st.history = lists.history
                if let h = volumeHold, Date() < h.until { st.volume = h.value }
                if let h = brightnessHold, Date() < h.until { st.brightness = h.value }
                if !connected { Log.add("first state from \(tag)") }
                let previous = connected ? state : nil
                state = st
                connected = true
                needsPairing = false
                busy = false
                detail = ""
                keeper?.observe(st, previous: previous, key: key)
            case .details(let d)?:
                details = d
            case .goodbye?:
                Log.add("disconnected by \(tag)")
                released = true
                drop()
            default:
                Log.add("rx sealed decode failed")
            }
        case .state:
            Log.add("ignored unencrypted state")
        case .details:
            Log.add("ignored unencrypted details")
        case .lists:
            Log.add("ignored unencrypted lists")
        case .goodbye:
            // Only the signed-in channel may tell a remote to stay away; anything on the network can send this.
            Log.add("ignored unsigned goodbye")
        case .busy:
            // Cannot be signed (it comes before sign-in), so it only slows the retries instead of stopping them.
            Log.add("viewer is in use by another remote: \(tag)")
            busy = true
            drop()
        case .unpaired:
            guard sameVersion() else { return }
            channel = nil
            // What it was playing was reported by an earlier pairing; showing it now would mislead.
            state = nil
            connected = false
            needsPairing = true
            detail = ""
        case .challenge(let nonce):
            guard sameVersion() else { return }
            // No secret on this side: answer with an empty proof so the viewer reports "unpaired" and offers pairing.
            guard let d = settings.paired(key) else { return sendRaw(.auth(mac: Data(), nonce: Data())) }
            let mine = Transport.nonce()
            let mac = HMAC<SHA256>.authenticationCode(for: nonce, using: SymmetricKey(data: d.secret))
            channel = Channel(secret: d.secret, salt: nonce + mine, viewer: false)
            sendRaw(.auth(mac: Data(mac), nonce: mine))
        case .pair(let pm):
            pairing.receive(pm, from: key) { [weak self] in self?.sendRaw(.pair($0)) }
        }
    }

    private func sendRaw(_ m: ClientMessage) {
        guard ready, let conn else { return }
        Transport.send(m, on: conn)
    }

    func send(_ cmd: Command) {
        guard connected, let box = channel?.seal(ClientMessage.command(cmd)) else {
            return Log.add("send \(cmd.logName) dropped: not connected")
        }
        if !cmd.logsOften { Log.add("send \(cmd.logName)") }
        sendRaw(.sealed(box))
    }

    func stop() {
        stopped = true
        watchdog?.invalidate()
        keepalive?.invalidate()
        conn?.cancel()
        conn = nil
        ready = false
        connected = false
        channel = nil
        pairing.cancel(peer: key)
    }

    private func drop() {
        Log.add("drop \(tag)")
        let old = conn
        conn = nil
        old?.cancel()
        ready = false
        connected = false
        channel = nil
        pairing.cancel(peer: key)
        guard !stopped, !released, !retryPending else { return }
        retryPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (busy ? 30 : 2)) { [weak self] in self?.connect() }
    }
}

final class RemoteController: ObservableObject {
    @Published var devices: [RemoteClient] = []
    @Published var selectedKey: String? {
        didSet { settings.lastViewerKey = selectedKey }
    }
    @Published var denied = false
    var active: RemoteClient? { devices.first { $0.key == selectedKey } }

    private var clients: [String: RemoteClient] = [:]
    private var missing: [String: Date] = [:]
    /// What each viewer last reported, so a client rebuilt after a return from the background shows
    /// the last known controls (dimmed, "Reconnecting") instead of flashing "Nothing Playing".
    private var lastState: [String: ViewerState] = [:]
    private var browser: NWBrowser?
    private var running = false
    private let settings: AppSettings
    private let pairing: Pairing
    private var proObs: AnyCancellable?
    private let keeper: QueueKeeper

    init(settings: AppSettings, pairing: Pairing) {
        self.settings = settings
        self.pairing = pairing
        keeper = QueueKeeper(settings: settings)
        selectedKey = settings.lastViewerKey
        // Buying or restoring Pro changes what this device may do on a viewer, so sign in again.
        proObs = ProStore.shared.$isPro.dropFirst().removeDuplicates().sink { [weak self] _ in
            self?.clients.values.forEach { $0.refresh() }
        }
    }

    func start() {
        running = true
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: Transport.serviceType, domain: nil), using: .tcp)
        b.stateUpdateHandler = { [weak self] s in
            Log.add("browser \(s)")
            switch s {
            case .ready:
                self?.denied = false
            case .waiting(let e):
                self?.denied = Transport.isDenied(e)
            case .failed(let e):
                self?.denied = Transport.isDenied(e)
                self?.teardown()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard let self, self.running else { return }
                    self.start()
                }
            default:
                break
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Log.add("browse results: \(results.count)")
            self?.update(results)
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        running = false
        teardown()
    }

    private func teardown() {
        for (k, c) in clients { if let s = c.state { lastState[k] = s } }
        browser?.cancel()
        browser = nil
        clients.values.forEach { $0.stop() }
        clients = [:]
        missing = [:]
        devices = []
    }

    func select(_ c: RemoteClient) { selectedKey = c.key }

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
                let c = RemoteClient(key: k, name: v.name, endpoints: v.endpoints, settings: settings, pairing: pairing,
                                    state: lastState[k], keeper: keeper)
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
                self.lastState[k] = nil
                self.devices.removeAll { $0.key == k }
            }
        }
        devices = clients.values.sorted { $0.name < $1.name }
        if selectedKey == nil, devices.count == 1 { selectedKey = devices[0].key }
    }
}
