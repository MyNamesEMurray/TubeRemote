import CryptoKit
import Foundation
import Network

/// JSON messages over plain TCP, each prefixed by a 4-byte big-endian length, advertised via Bonjour.
/// Everything runs on the main queue. A relay server for remote-over-internet can speak the same messages.
enum Transport {
    static let serviceType = "_ytremote._tcp"
    static let maxMessage = 1 << 20
    /// Bump when a message changes in a way older builds cannot read.
    static let version = 2

    static func parameters() -> NWParameters {
        let p = NWParameters.tcp
        if let tcp = p.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        return p
    }

    /// Service name is "<device name>#<device key>". Bonjour caps names at 63 bytes, so trim by bytes.
    static func service(name: String, key: String) -> NWListener.Service {
        var n = name
        while n.utf8.count > 50 { n.removeLast() }
        return NWListener.Service(name: "\(n)#\(key)", type: serviceType)
    }

    static func nonce() -> Data { Data((0..<16).map { _ in UInt8.random(in: 0...255) }) }

    /// True when iOS refused Local Network access (kDNSServiceErr_PolicyDenied).
    static func isDenied(_ e: NWError) -> Bool {
        if case .dns(let code) = e { return code == -65570 }
        return false
    }

    static func send<T: Encodable>(_ msg: T, on c: NWConnection) {
        guard let body = try? JSONEncoder().encode(msg) else { return Log.add("tx encode failed: \(T.self)") }
        var len = UInt32(body.count).bigEndian
        let frame = Data(bytes: &len, count: 4) + body
        c.send(content: frame, completion: .idempotent)
    }

    static func receiveLoop<T: Decodable>(
        _ c: NWConnection, as type: T.Type,
        onMessage: @escaping (T) -> Void, onEnd: @escaping () -> Void
    ) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { head, _, _, error in
            guard error == nil, let head, head.count == 4 else {
                Log.add("rx header ended: \(error.map { "\($0)" } ?? "closed")")
                return onEnd()
            }
            let n = Int(head.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard n > 0, n <= maxMessage else {
                Log.add("rx bad length \(n)")
                return onEnd()
            }
            c.receive(minimumIncompleteLength: n, maximumLength: n) { body, _, _, error in
                guard error == nil, let body, body.count == n else {
                    Log.add("rx body ended: \(error.map { "\($0)" } ?? "closed")")
                    return onEnd()
                }
                if let m = try? JSONDecoder().decode(T.self, from: body) { onMessage(m) } else { Log.add("rx decode failed (\(n) bytes)") }
                receiveLoop(c, as: type, onMessage: onMessage, onEnd: onEnd)
            }
        }
    }
}

/// Encrypts everything sent after sign-in, with keys derived from the pairing secret and both sides' nonces.
/// Each direction has its own key and a message counter, so a message cannot be read, changed, replayed or reordered.
struct Channel {
    private let tx: SymmetricKey, rx: SymmetricKey
    private var sent: UInt64 = 0, received: UInt64 = 0

    init(secret: Data, salt: Data, viewer: Bool) {
        func key(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt,
                                   info: Data(info.utf8), outputByteCount: 32)
        }
        tx = key(viewer ? "viewer" : "remote")
        rx = key(viewer ? "remote" : "viewer")
    }

    private static func nonce(_ n: UInt64) -> Data {
        Data(count: 4) + withUnsafeBytes(of: n.bigEndian) { Data($0) }
    }

    mutating func seal<T: Encodable>(_ m: T) -> Data? {
        guard let body = try? JSONEncoder().encode(m),
              let nonce = try? ChaChaPoly.Nonce(data: Self.nonce(sent + 1)),
              let box = try? ChaChaPoly.seal(body, using: tx, nonce: nonce) else { return nil }
        sent += 1
        return box.ciphertext + box.tag
    }

    /// Returns the decrypted message body, or nil if it was not the next message from the other side.
    mutating func open(_ data: Data) -> Data? {
        guard let box = try? ChaChaPoly.SealedBox(combined: Self.nonce(received + 1) + data),
              let body = try? ChaChaPoly.open(box, using: rx) else { return nil }
        received += 1
        return body
    }
}

struct PendingPeer: Identifiable {
    let id: ObjectIdentifier
    let name: String
    /// The remote's device key, known once it has said hello.
    var key: String? = nil
}

/// Viewer side: accepts any number of remotes. Only authenticated remotes get state and may send commands.
final class ViewerServer {
    private struct Peer {
        let conn: NWConnection
        var name = "a remote"
        var last = Date()
        var hello = false
        var key: String?
        var pro = false
        var since = Date.distantFuture
        var nonce: Data?
        var channel: Channel?
        var authed: Bool { channel != nil }
    }

    private var listener: NWListener?
    private var conns: [ObjectIdentifier: Peer] = [:]
    private var running = false
    private var sweeper: Timer?

    var onCommand: ((Command, String) -> Void)?
    var snapshot: (() -> ViewerState?)?
    var paired: ((String) -> PairedDevice?)?
    var onPair: ((PairMessage, ObjectIdentifier, @escaping (PairMessage) -> Void) -> Void)?
    var onPeers: (() -> Void)?
    var onGone: ((ObjectIdentifier) -> Void)?
    var onDenied: ((Bool) -> Void)?
    /// Whether the viewer's own device has Pro.
    var viewerPro: (() -> Bool)?
    /// Short messages for the person at the viewer.
    var notify: ((String) -> Void)?
    /// Whether a video is loaded, so extra remotes can be sent away when nothing is playing.
    var hasVideo: (() -> Bool)?
    private var excessPending = false
    private var idleSince: Date?

    /// Remotes that said hello but are not authenticated, so they can be offered for pairing.
    var pending: [PendingPeer] {
        conns.compactMap { $0.value.hello && !$0.value.authed ? PendingPeer(id: $0.key, name: $0.value.name) : nil }
            .sorted { $0.name < $1.name }
    }

    func start(name: String, key: String) {
        stop()
        running = true
        guard let l = try? NWListener(using: Transport.parameters()) else { return }
        l.service = Transport.service(name: name, key: key)
        l.serviceRegistrationUpdateHandler = { change in
            Log.add("service \(String(describing: change).prefix { $0 != "(" })")
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] state in
            Log.add("listener \(state) port \(self?.listener?.port.map { "\($0)" } ?? "-")")
            switch state {
            case .ready:
                self?.onDenied?(false)
            case .waiting(let e):
                self?.onDenied?(Transport.isDenied(e))
            case .failed(let e):
                self?.onDenied?(Transport.isDenied(e))
                self?.listener = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard let self, self.running, self.listener == nil else { return }
                    self.start(name: name, key: key)
                }
            default:
                break
            }
        }
        l.start(queue: .main)
        Log.add("listener starting")
        listener = l
        sweeper = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            for (id, e) in self.conns where Date().timeIntervalSince(e.last) > (e.hello ? 15 : 5) {
                Log.add("dropping silent remote \(Log.who(e.key)) hello=\(e.hello)")
                e.conn.cancel()
                self.remove(id)
            }
            self.tickSession()
        }
    }

    /// When the Pro device leaves and several remotes remain: while a video plays they keep going until it ends or the next
    /// one starts. With nothing playing they get a minute for the Pro device to come back. Then all but the remote
    /// connected longest are sent away.
    private func tickSession() {
        let excess = SessionRules.excess(remotes(), viewerPro: viewerPro?() ?? false)
        guard !excess.isEmpty else {
            idleSince = nil
            if excessPending {
                excessPending = false
                if viewerPro?() == true || anyRemotePro { notify?("A Pro device is connected again. Remotes stay connected.") }
            }
            return
        }
        let playing = hasVideo?() == true
        if !excessPending {
            excessPending = true
            notify?(playing ? "A Pro device left. Extra remotes disconnect when this video ends."
                            : "A Pro device left. Extra remotes disconnect in a minute unless it comes back.")
        }
        idleSince = playing ? nil : (idleSince ?? Date())
        if SessionRules.shouldTrim(playing: playing, idleSince: idleSince, now: Date()) { trimExtras() }
    }

    /// The viewer calls this when a new video starts.
    func videoChanged() {
        if excessPending { trimExtras() }
    }

    private func trimExtras() {
        excessPending = false
        idleSince = nil
        let excess = SessionRules.excess(remotes(), viewerPro: viewerPro?() ?? false)
        guard !excess.isEmpty else { return }
        for (id, p) in conns where p.authed && excess.contains(p.key ?? "") { disconnect(id, with: .busy) }
        notify?("Extra remotes disconnected. Sharing a viewer needs Pro on the viewer or on one remote.")
    }

    var anyRemotePro: Bool { remotes().contains { $0.pro } }

    private func remotes(excluding id: ObjectIdentifier? = nil) -> [SessionRules.Remote] {
        conns.compactMap {
            $0.key != id && $0.value.authed ? SessionRules.Remote(key: $0.value.key ?? "", pro: $0.value.pro, since: $0.value.since) : nil
        }
    }

    /// One remote at a time unless the viewer or a connected remote has Pro. A device that signs in again replaces
    /// its own older connection.
    private func admit(_ id: ObjectIdentifier) -> Bool {
        guard let me = conns[id], let key = me.key else { return false }
        for (other, p) in conns where other != id && p.authed && p.key == key {
            p.conn.cancel()
            remove(other)
        }
        return SessionRules.admits(SessionRules.Remote(key: key, pro: me.pro, since: Date()), among: remotes(excluding: id),
                                   viewerPro: viewerPro?() ?? false)
    }

    func rename(name: String, key: String) {
        listener?.service = Transport.service(name: name, key: key)
    }

    func stop() {
        sweeper?.invalidate()
        sweeper = nil
        running = false
        listener?.cancel()
        listener = nil
        conns.values.forEach { $0.conn.cancel() }
        conns = [:]
        onPeers?()
    }

    func broadcast(_ state: ViewerState) {
        for (id, p) in conns {
            if p.authed {
                sendSealed(.state(state), to: id)
            } else if p.hello, p.nonce == nil {
                send(.unpaired, to: id)
            }
        }
    }

    func send(_ m: ServerMessage, to id: ObjectIdentifier) {
        if let c = conns[id]?.conn { Transport.send(m, on: c) }
    }

    /// Remotes signed in right now, so the person at the viewer can see and disconnect them.
    var connected: [PendingPeer] {
        conns.compactMap { $0.value.authed ? PendingPeer(id: $0.key, name: $0.value.name, key: $0.value.key) : nil }
            .sorted { $0.name < $1.name }
    }

    /// Disconnects every signed-in remote. Devices still waiting to pair are left alone.
    func disconnectAll() {
        for (id, p) in conns where p.authed { disconnect(id) }
    }

    /// Tells the remote, then closes the connection once the message has had time to leave.
    func disconnect(_ id: ObjectIdentifier, with message: ServerMessage = .goodbye) {
        guard let c = conns[id]?.conn else { return }
        // A signed-in remote only believes a goodbye that arrives inside its encrypted channel.
        if case .goodbye = message, conns[id]?.authed == true { sendSealed(message, to: id) } else { send(message, to: id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            c.cancel()
            self?.remove(id)
        }
    }

    private func sendSealed(_ m: ServerMessage, to id: ObjectIdentifier) {
        guard let box = conns[id]?.channel?.seal(m) else { return }
        send(.sealed(box), to: id)
    }

    /// A pairing just finished: ask the remote with this key to sign in with its new secret.
    func challenge(key: String) {
        for (id, p) in conns where p.key == key && p.hello { challenge(id) }
        onPeers?()
    }

    private func challenge(_ id: ObjectIdentifier) {
        let nonce = Transport.nonce()
        conns[id]?.channel = nil
        conns[id]?.nonce = nonce
        send(.challenge(nonce), to: id)
    }

    /// The paired list changed: disconnect signed-in remotes that are no longer on it.
    func keep(_ keys: Set<String>) {
        for (id, p) in conns where p.authed && !keys.contains(p.key ?? "") {
            Log.add("unpaired \(Log.who(p.key)), disconnecting")
            p.conn.cancel()
            remove(id)
        }
    }

    private func remove(_ id: ObjectIdentifier) {
        guard conns[id] != nil else { return }
        conns[id] = nil
        onGone?(id)
        onPeers?()
    }

    private func accept(_ c: NWConnection) {
        // A device that never signs in can still keep a connection alive with pings, so there are only so many.
        guard conns.values.filter({ !$0.authed }).count < 8 else { return c.cancel() }
        let id = ObjectIdentifier(c)
        conns[id] = Peer(conn: c)
        Log.add("accepted connection")
        c.stateUpdateHandler = { [weak self] s in
            Log.add("inbound \(s)")
            switch s {
            case .failed, .cancelled: self?.remove(id)
            default: break
            }
        }
        c.start(queue: .main)
        Transport.receiveLoop(c, as: ClientMessage.self, onMessage: { [weak self] m in
            self?.conns[id]?.last = Date()
            self?.handle(m, id: id, conn: c)
        }, onEnd: { [weak self] in
            self?.remove(id)
            c.cancel()
        })
    }

    private func handle(_ m: ClientMessage, id: ObjectIdentifier, conn: NWConnection) {
        switch m {
        case .hello(let name, let key, let version, let pro):
            send(.hello(version: Transport.version), to: id)
            guard version == Transport.version else {
                return Log.add("\(Log.who(key)) runs protocol \(version.map { "\($0)" } ?? "1"), this device \(Transport.version)")
            }
            if conns[id]?.hello == false { Log.add("hello from \(Log.who(key))") }
            conns[id]?.name = String(name.prefix(40))
            conns[id]?.hello = true
            conns[id]?.key = key
            conns[id]?.pro = pro ?? false
            conns[id]?.channel = nil
            if paired?(key) != nil {
                challenge(id)
            } else {
                conns[id]?.nonce = nil
                send(.unpaired, to: id)
            }
            onPeers?()
        case .auth(let mac, let theirs):
            guard let p = conns[id], let nonce = p.nonce, let key = p.key, let d = paired?(key), theirs.count == 16,
                  HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: nonce, using: SymmetricKey(data: d.secret))
            else {
                Log.add("auth failed for \(Log.who(conns[id]?.key))")
                conns[id]?.nonce = nil
                send(.unpaired, to: id)
                onPeers?()
                return
            }
            guard admit(id) else {
                Log.add("refused \(Log.who(p.key)): the viewer serves another remote and no Pro device is connected")
                conns[id]?.nonce = nil
                disconnect(id, with: .busy)
                return
            }
            conns[id]?.channel = Channel(secret: d.secret, salt: nonce + theirs, viewer: true)
            conns[id]?.since = Date()
            conns[id]?.nonce = nil
            Log.add("authenticated \(Log.who(p.key))")
            if let s = snapshot?() { sendSealed(.state(s), to: id) }
            onPeers?()
        case .ping:
            break
        case .pair(let pm):
            guard conns[id]?.hello == true else { return }
            onPair?(pm, id) { Transport.send(ServerMessage.pair($0), on: conn) }
        case .sealed(let box):
            guard let body = conns[id]?.channel?.open(box) else {
                Log.add("bad encrypted message from \(Log.who(conns[id]?.key)), disconnecting")
                conn.cancel()
                return remove(id)
            }
            guard case .command(let cmd)? = try? JSONDecoder().decode(ClientMessage.self, from: body) else {
                return Log.add("rx sealed decode failed")
            }
            Log.add("command \(cmd.logName) from \(Log.who(conns[id]?.key))")
            onCommand?(cmd, conns[id]?.name ?? "a remote")
        case .command:
            Log.add("ignored unencrypted command")
        }
    }
}
