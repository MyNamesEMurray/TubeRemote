import StoreKit
import SwiftUI

final class ProStore: ObservableObject {
    static let shared = ProStore()
    static let productID = "com.exaltedpixels.TubeRemote.pro"

    @Published private(set) var isPro: Bool
    @Published private(set) var product: Product?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    /// For testing before the product exists in App Store Connect. Remove before a public release.
    @Published var debugUnlocked: Bool {
        didSet {
            UserDefaults.standard.set(debugUnlocked, forKey: "proDebugUnlocked")
            isPro = entitled || debugUnlocked
        }
    }

    private var entitled: Bool
    private var updates: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        let e = d.bool(forKey: "proEntitled"), g = d.bool(forKey: "proDebugUnlocked")
        entitled = e
        isPro = e || g
        debugUnlocked = g
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refreshEntitlement()
            }
        }
        Task { [weak self] in
            await self?.loadProduct()
            await self?.refreshEntitlement()
        }
    }

    @MainActor func loadProduct() async {
        product = try? await Product.products(for: [Self.productID]).first
    }

    @MainActor func refreshEntitlement() async {
        var found = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.productID, t.revocationDate == nil { found = true }
        }
        entitled = found
        UserDefaults.standard.set(found, forKey: "proEntitled")
        isPro = found || debugUnlocked
    }

    @MainActor func purchase() async {
        if product == nil { await loadProduct() }
        guard let product else { return message = "Unavailable right now." }
        busy = true
        message = nil
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                if case .verified(let t) = result {
                    await t.finish()
                    await refreshEntitlement()
                } else {
                    message = "Purchase could not be verified."
                }
            case .pending:
                message = "Purchase pending approval."
            default:
                break
            }
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor func restore() async {
        busy = true
        message = nil
        defer { busy = false }
        try? await AppStore.sync()
        await refreshEntitlement()
        if !entitled { message = "No purchase to restore." }
    }
}

struct PaywallView: View {
    @EnvironmentObject private var pro: ProStore
    @Environment(\.dismiss) private var dismiss

    private let features: [(String, String)] = [
        ("tv", "Preferred video quality: start every video at Highest available, or at the quality you choose"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.white)
                        .frame(width: 104, height: 104)
                        .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .accessibilityHidden(true)
                    Text("TubeRemote Pro").font(.largeTitle.bold())
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(features, id: \.1) { f in
                            Label {
                                Text(f.1)
                            } icon: {
                                Image(systemName: f.0).foregroundStyle(.tint).frame(width: 32)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("One-time purchase. Everything you use today stays free.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if pro.isPro {
                        Label("Pro unlocked", systemImage: "checkmark.seal.fill").font(.headline)
                    } else {
                        Button {
                            Task { await pro.purchase() }
                        } label: {
                            Group {
                                if pro.busy {
                                    ProgressView()
                                } else if let p = pro.product {
                                    Text("Buy for \(p.displayPrice)")
                                } else {
                                    Text("Unavailable right now")
                                }
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(pro.product == nil || pro.busy)
                    }
                    Button("Restore Purchases") { Task { await pro.restore() } }
                        .disabled(pro.busy)
                    if let m = pro.message {
                        Text(m).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 520)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { if pro.product == nil { await pro.loadProduct() } }
        }
    }
}

/// Small "Pro" tag shown next to a feature the person has not unlocked.
struct GatedBadge: View {
    var body: some View {
        Label("Pro", systemImage: "lock.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }
}

/// The picker for the viewer's preferred quality. The viewer keeps the value; the remote only sends it.
struct QualityRow: View {
    let value: String
    let enabled: Bool
    let set: (String) -> Void
    @Binding var showPaywall: Bool
    @EnvironmentObject var pro: ProStore

    var body: some View {
        if pro.isPro {
            Picker("Preferred quality", selection: Binding(get: { value }, set: set)) {
                ForEach(preferredQualityChoices, id: \.id) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.menu)
            .disabled(!enabled)
        } else {
            Button { showPaywall = true } label: {
                HStack {
                    Text("Preferred quality").foregroundStyle(.primary)
                    GatedBadge()
                    Spacer()
                    Text(preferredQualityChoices.first { $0.id == value }?.label ?? "Auto").foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Reads the connected viewer's value live, so the picker follows it.
struct RemoteQualityRow: View {
    @ObservedObject var client: RemoteClient
    @Binding var showPaywall: Bool

    var body: some View {
        QualityRow(value: client.state?.preferredQuality ?? "auto", enabled: client.connected,
                   set: { client.send(.setPreferredQuality($0)) }, showPaywall: $showPaywall)
    }
}
