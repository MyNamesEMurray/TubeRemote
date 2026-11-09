import CryptoKit
import Foundation
import SwiftUI

/// Numeric-comparison pairing: both devices derive the same 6-digit code from an ECDH exchange,
/// a person confirms it on both, and the shared secret is saved for later authentication.
/// Works from either side because the messages are symmetric.
final class Pairing: ObservableObject {
    struct Prompt: Equatable {
        let name: String
        let code: String
    }

    @Published var prompt: Prompt?
    var onPaired: ((PairedDevice) -> Void)?

    private final class Session {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let send: (PairMessage) -> Void
        var peerKey = "", peerName = ""
        var secret: Data?
        var iAccepted = false, peerAccepted = false
        init(send: @escaping (PairMessage) -> Void) { self.send = send }
    }

    private var session: Session?
    private let settings: AppSettings

    init(settings: AppSettings) { self.settings = settings }

    func begin(send: @escaping (PairMessage) -> Void) {
        cancel()
        open(send: send)
    }

    func receive(_ m: PairMessage, send: @escaping (PairMessage) -> Void) {
        switch m {
        case .key(let pub, let deviceKey, let name):
            let s = session ?? open(send: send)
            guard s.secret == nil,
                  let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub),
                  let shared = try? s.priv.sharedSecretFromKeyAgreement(with: peer) else { return }
            s.peerKey = deviceKey
            s.peerName = name
            let pubs = [s.priv.publicKey.rawRepresentation, pub].sorted { $0.lexicographicallyPrecedes($1) }
            let salt = pubs[0] + pubs[1]
            let key = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: salt, sharedInfo: Data("tuberemote".utf8), outputByteCount: 32)
            s.secret = key.withUnsafeBytes { Data($0) }
            let n = SHA256.hash(data: salt).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
            prompt = Prompt(name: name, code: String(format: "%06d", n))
            Log.add("pairing code ready for \(name)")
        case .decision(let yes):
            guard let s = session else { return }
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

    @discardableResult
    private func open(send: @escaping (PairMessage) -> Void) -> Session {
        let s = Session(send: send)
        session = s
        s.send(.key(pub: s.priv.publicKey.rawRepresentation, deviceKey: settings.deviceKey, name: settings.name))
        return s
    }

    private func finish() {
        guard let s = session, s.iAccepted, s.peerAccepted, let secret = s.secret else { return }
        session = nil
        let d = PairedDevice(key: s.peerKey, name: s.peerName, secret: secret)
        settings.addPaired(d)
        Log.add("paired with \(d.name)")
        onPaired?(d)
    }
}

struct PairingPrompt: ViewModifier {
    @EnvironmentObject var pairing: Pairing

    func body(content: Content) -> some View {
        content.overlay {
            if let p = pairing.prompt {
                ZStack {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    VStack(spacing: 14) {
                        Text("Pair with \(p.name)?").font(.headline)
                        Text(p.code).font(.system(size: 40, weight: .bold, design: .monospaced))
                        Text("Do both devices show this code?").font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button("No", role: .cancel) { pairing.answer(false) }.buttonStyle(.bordered)
                            Button("Yes") { pairing.answer(true) }.buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding()
                }
            }
        }
    }
}

extension View {
    func pairingPrompt() -> some View { modifier(PairingPrompt()) }
}
