import CryptoKit
import Foundation
import SwiftUI

/// Numeric-comparison pairing: both devices derive the same 6-digit code from an ECDH exchange,
/// a person confirms it on both, and the shared secret is saved for later authentication.
/// Either side may start. The starter commits to its key before seeing the other's, so the code cannot be forced.
final class Pairing: ObservableObject {
    struct Prompt: Equatable {
        let name: String
        let code: String
    }

    @Published var prompt: Prompt?
    var onPaired: ((PairedDevice) -> Void)?

    private final class Session {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let peer: AnyHashable
        let initiator: Bool
        let send: (PairMessage) -> Void
        var peerCommit: Data?
        var peerKey = "", peerName = ""
        var secret: Data?
        var iAccepted = false, peerAccepted = false
        var pub: Data { priv.publicKey.rawRepresentation }

        init(peer: AnyHashable, initiator: Bool, send: @escaping (PairMessage) -> Void) {
            self.peer = peer
            self.initiator = initiator
            self.send = send
        }
    }

    private var session: Session?
    private let settings: AppSettings

    init(settings: AppSettings) { self.settings = settings }

    func begin(peer: AnyHashable, send: @escaping (PairMessage) -> Void) {
        cancel()
        let s = open(peer: peer, initiator: true, send: send)
        s.send(.commit(Data(SHA256.hash(data: s.pub))))
    }

    func receive(_ m: PairMessage, from peer: AnyHashable, send: @escaping (PairMessage) -> Void) {
        if let s = session, s.peer != peer { return }
        switch m {
        case .commit(let c):
            // shortcut: if both sides start at the same instant both attempts cancel; the person taps Pair again
            cancel()
            let s = open(peer: peer, initiator: false, send: send)
            s.peerCommit = c
            s.send(key(s))
        case .key(let pub, let deviceKey, let name):
            guard let s = session, s.secret == nil else { return }
            if s.initiator {
                s.send(key(s))
            } else if Data(SHA256.hash(data: pub)) != s.peerCommit {
                return cancel()
            }
            guard let peerPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub),
                  let shared = try? s.priv.sharedSecretFromKeyAgreement(with: peerPub) else { return cancel() }
            s.peerKey = deviceKey
            s.peerName = String(name.prefix(40))
            let pubs = [s.pub, pub].sorted { $0.lexicographicallyPrecedes($1) }
            let salt = pubs[0] + pubs[1]
            let derived = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: salt, sharedInfo: Data("tuberemote".utf8), outputByteCount: 32)
            s.secret = derived.withUnsafeBytes { Data($0) }
            let n = SHA256.hash(data: salt).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
            prompt = Prompt(name: s.peerName, code: String(format: "%06d", n))
            Log.add("pairing code ready")
        case .decision(let yes):
            guard let s = session, s.secret != nil else { return }
            guard yes else { return cancel() }
            s.peerAccepted = true
            finish()
        }
    }

    func answer(_ yes: Bool) {
        prompt = nil
        guard let s = session else { return }
        s.send(.decision(yes))
        guard yes else { session = nil; return }
        s.iAccepted = true
        finish()
    }

    func cancel() {
        session = nil
        prompt = nil
    }

    func cancel(peer: AnyHashable) {
        if session?.peer == peer { cancel() }
    }

    private func key(_ s: Session) -> PairMessage {
        .key(pub: s.pub, deviceKey: settings.deviceKey, name: settings.name)
    }

    private func open(peer: AnyHashable, initiator: Bool, send: @escaping (PairMessage) -> Void) -> Session {
        let s = Session(peer: peer, initiator: initiator, send: send)
        session = s
        // An unanswered attempt must not block the next one forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self, weak s] in
            if let s, self?.session === s { self?.cancel() }
        }
        return s
    }

    private func finish() {
        guard let s = session, s.iAccepted, s.peerAccepted, let secret = s.secret else { return }
        session = nil
        let d = PairedDevice(key: s.peerKey, name: s.peerName, secret: secret)
        settings.addPaired(d)
        Log.add("paired with \(Log.who(d.key))")
        onPaired?(d)
    }
}

struct PairingPrompt: ViewModifier {
    @EnvironmentObject var pairing: Pairing

    private func spaced(_ code: String) -> String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }

    func body(content: Content) -> some View {
        content.overlay {
            if let p = pairing.prompt {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    VStack(spacing: 14) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 40))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("Pair with \(p.name)?")
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                        Text(spaced(p.code))
                            .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                            .tracking(4)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                            .accessibilityLabel("Code \(p.code.map(String.init).joined(separator: " "))")
                        Text("Make sure this code matches the one on the other device.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        VStack(spacing: 8) {
                            Button {
                                Haptics.tap()
                                pairing.answer(true)
                            } label: {
                                Text("Pair").font(.headline).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            Button {
                                Haptics.tap()
                                pairing.answer(false)
                            } label: {
                                Text("Cancel").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                            .padding(.vertical, 8)
                        }
                        .padding(.top, 6)
                    }
                    .padding(24)
                    .frame(maxWidth: 340)
                    .glassBackground(RoundedRectangle(cornerRadius: 20, style: .continuous), .regularMaterial)
                    .padding()
                }
                .accessibilityAddTraits(.isModal)
            }
        }
    }
}

extension View {
    func pairingPrompt() -> some View { modifier(PairingPrompt()) }
}
