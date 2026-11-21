import StoreKit
import SwiftUI

final class ProStore: ObservableObject {
    static let shared = ProStore()
    static let productID = "com.exaltedpixels.TubeRemote.pro"
    /// Debug builds launched with `-TubeRemotePrice '$4.99'` show that price before the product has loaded, for the store screenshot.
    static var stagedPrice: String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "TubeRemotePrice")
        #else
        nil
        #endif
    }

    @Published private(set) var isPro: Bool
    @Published private(set) var product: Product?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private var entitled: Bool
    private var updates: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        let e = d.bool(forKey: "proEntitled")
        entitled = e
        isPro = e
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
        isPro = found
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
        ("forward.fill", "Skip Ad from the remote"),
        ("moon.zzz.fill", "Sleep timer"),
        ("list.bullet.rectangle", "Add a whole playlist to the queue"),
        ("square.and.arrow.up", "Share a video to the viewer from other apps"),
        ("person.2.fill", "Several remotes on one viewer. Pro on the viewer or on any one remote is enough for everyone connected"),
        ("tray.and.arrow.down.fill", "Keep your queue on the remote, and resume it where you left off"),
        ("text.alignleft", "Rich video view: the description beside the video on the viewer, scrolled from your remote"),
        ("infinity", "Autoplay: keep going with what YouTube suggests when the queue runs out"),
    ]
    private var price: String? { pro.product?.displayPrice ?? ProStore.stagedPrice }

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
                    Text("One-time purchase. Playing videos from one remote on one viewer stays free.")
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
                                } else if let price {
                                    Text("Buy for \(price)")
                                } else {
                                    Text("Unavailable right now")
                                }
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(price == nil || pro.busy)
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

extension ProStore {
    func has(_ viewer: ViewerState?) -> Bool { isPro || viewer?.sessionPro == true }
}

/// Sleep timer menu. The viewer holds the timer; `endsAt` is when it will pause, if one is running.
struct SleepTimerMenu: View, Equatable {
    let endsAt: Date?
    var onDark = false
    var unlocked = false
    let set: (Double?) -> Void
    @EnvironmentObject var pro: ProStore
    @State private var showPaywall = false
    @State private var showCustom = false
    private var isPro: Bool { pro.isPro || unlocked }

    static func == (a: SleepTimerMenu, b: SleepTimerMenu) -> Bool { a.endsAt == b.endsAt && a.onDark == b.onDark && a.unlocked == b.unlocked }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: "moon.zzz.fill")
            if let endsAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("Sleep in " + clock(max(endsAt.timeIntervalSince(ctx.date), 0))).monospacedDigit()
                }
            } else {
                Text("Sleep timer")
            }
            if !isPro { GatedBadge() }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(onDark ? Color.white : Color.primary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(minHeight: 36)
        .background(onDark ? Color.white.opacity(0.18) : Color(.secondarySystemFill), in: Capsule())
        .frame(minHeight: 44)
    }

    var body: some View {
        Group {
            if isPro {
                Menu {
                    Button { Haptics.tap(); set(nil) } label: { Label("Off", systemImage: "xmark") }
                    ForEach([15, 30, 45, 60], id: \.self) { m in
                        Button(m == 60 ? "1 hour" : "\(m) minutes") { Haptics.tap(); set(Double(m * 60)) }
                    }
                    Button("Custom…") { Haptics.tap(); showCustom = true }
                    Button("End of video") { Haptics.tap(); set(0) }
                    Button("End of queue") { Haptics.tap(); set(-1) }
                } label: { label }
                .menuOrder(.fixed)
                .accessibilityLabel(endsAt == nil ? "Sleep timer" : "Sleep timer running")
            } else {
                Button { showPaywall = true } label: { label }
            }
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .sheet(isPresented: $showCustom) { CustomSleepSheet(set: set).presentationDetents([.height(320)]) }
    }
}

/// Pro: switches autoplay on or off. The viewer holds the setting.
struct AutoplayButton: View {
    let on: Bool
    var onDark = false
    var unlocked = false
    let set: (Bool) -> Void
    @EnvironmentObject var pro: ProStore
    @State private var showPaywall = false
    private var isPro: Bool { pro.isPro || unlocked }
    private var lit: Bool { on && isPro }

    var body: some View {
        Button {
            Haptics.tap()
            if isPro { set(!on) } else { showPaywall = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "infinity")
                Text(lit ? "Autoplay on" : "Autoplay")
                if !isPro { GatedBadge() }
            }
            .font(.subheadline.weight(lit ? .semibold : .medium))
            .foregroundStyle(lit || onDark ? Color.white : Color.primary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(lit ? Color.accentColor : onDark ? Color.white.opacity(0.18) : Color(.secondarySystemFill), in: Capsule())
            .frame(minHeight: 44)
        }
        .accessibilityLabel(on ? "Autoplay on" : "Autoplay off")
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }
}

/// Hours and minutes for a sleep timer of any length up to twelve hours.
struct CustomSleepSheet: View {
    let set: (Double?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hours = 0
    @State private var minutes = 20

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Picker("Hours", selection: $hours) { ForEach(0..<12, id: \.self) { Text("\($0) h").tag($0) } }
                    Picker("Minutes", selection: $minutes) { ForEach(0..<60, id: \.self) { Text("\($0) min").tag($0) } }
                }
                .pickerStyle(.wheel)
                Button {
                    Haptics.tap()
                    set(Double(hours * 3600 + minutes * 60))
                    dismiss()
                } label: { Text("Start timer").font(.headline).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(hours == 0 && minutes == 0)
                    .padding([.horizontal, .bottom])
            }
            .navigationTitle("Sleep timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// The picker for the viewer's preferred quality. The viewer keeps the value; the remote only sends it.
struct QualityRow: View {
    let value: String
    let enabled: Bool
    var unlocked = false
    let set: (String) -> Void
    @Binding var showPaywall: Bool
    @EnvironmentObject var pro: ProStore

    var body: some View {
        if pro.isPro || unlocked {
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
                   unlocked: client.state?.sessionPro == true, set: { client.send(.setPreferredQuality($0)) }, showPaywall: $showPaywall)
    }
}
