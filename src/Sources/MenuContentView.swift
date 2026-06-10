import SwiftUI

// MARK: - Root

struct MenuContentView: View {
    @EnvironmentObject var controller: AppController
    @State private var tab: Tab = .providers
    @State private var contentHeight: CGFloat = 360

    enum Tab: String, CaseIterable, Identifiable {
        case providers = "Providers"
        case share = "Share"
        case borrow = "Borrow"
        case activity = "Activity"
        case settings = "Settings"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .providers: return "bolt.horizontal.circle"
            case .share: return "square.and.arrow.up"
            case .borrow: return "square.and.arrow.down"
            case .activity: return "list.bullet.rectangle"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            ProcessHealthBanner()
            Divider()
            TabBar(selection: $tab)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    GettingStartedCard(tab: $tab)
                    switch tab {
                    case .providers: ProvidersTab(providers: controller.providers)
                    case .share: ShareTab()
                    case .borrow: BorrowTab()
                    case .activity: ActivityTab()
                    case .settings: SettingsTab()
                    }
                }
                .padding(12)
                .background(GeometryReader { g in
                    Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                })
            }
            // Hug the content instead of a fixed height: short tabs stay compact,
            // long lists scroll once they pass the cap.
            .frame(height: min(max(contentHeight, 180), 480))
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }

            Divider()
            FooterView()
        }
        .frame(width: 420)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 360
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Tab bar (custom: 5 labeled tabs don't fit a segmented picker)

struct TabBar: View {
    @Binding var selection: MenuContentView.Tab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MenuContentView.Tab.allCases) { t in
                Button {
                    selection = t
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: t.symbol).font(.system(size: 14))
                        Text(t.rawValue).font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == t ? Color.accentColor : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selection == t ? Color.accentColor.opacity(0.12) : Color.clear)
                )
                .accessibilityLabel(t.rawValue)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Header

struct HeaderView: View {
    @EnvironmentObject var controller: AppController

    private var running: Bool { controller.status?.running ?? false }
    private var sharingOn: Bool { controller.status?.sharingEnabled ?? true }
    private var relayCount: Int { controller.status?.connectedRelayCount ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "person.2.wave.2.fill")
                    .foregroundStyle(.tint)
                Text("VibeShare").font(.headline)
                Spacer()
                StatusDot(on: running)
                Text(running ? "Running" : "Starting…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "link").font(.caption2).foregroundStyle(.secondary)
                Text(controller.endpointURL)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                CopyIconButton(text: controller.endpointURL,
                               help: "Copy the OpenAI endpoint URL",
                               onCopy: { controller.markToolSetupSeen() })
            }
            HStack(spacing: 12) {
                // 0 connected relays = invisible to friends; flag it.
                pill(icon: "antenna.radiowaves.left.and.right",
                     text: "\(relayCount) relays",
                     ok: relayCount > 0)
                pill(icon: "cpu",
                     text: "\(controller.status?.models.count ?? 0) local models",
                     ok: controller.status?.upstream.reachable ?? false)
                if sharingOn {
                    pill(icon: "person.crop.circle",
                         text: controller.status?.identityName ?? "—")
                } else {
                    pill(icon: "pause.circle.fill", text: "sharing off", ok: false)
                }
            }
            .font(.caption2)
        }
        .padding(12)
    }

    private func pill(icon: String, text: String, ok: Bool = true) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(text).lineLimit(1)
        }
        .foregroundStyle(ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
    }
}

// MARK: - Engine health banner (surfaces ProcessManager errors that previously
// vanished into the log file while the header said "Starting…" forever)

struct ProcessHealthBanner: View {
    @ObservedObject private var processes = ProcessManager.shared

    var body: some View {
        if let err = processes.lastError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.caption2)
                    .lineLimit(2)
                    .help(err)
                Spacer()
                Button("Restart") { processes.restartAll() }
                    .controlSize(.small)
                Button("Logs") { AppController.shared.openLogsFolder() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
        }
    }
}

// MARK: - Getting started (first-run checklist; hides once done or dismissed)

struct GettingStartedCard: View {
    @EnvironmentObject var controller: AppController
    @Binding var tab: MenuContentView.Tab
    @AppStorage("onboarding.dismissed") private var dismissed = false
    @AppStorage("useWithExpanded") private var useWithExpanded = false

    private var step1Done: Bool { !(controller.status?.models.isEmpty ?? true) }
    private var step2Done: Bool { controller.toolSetupSeen }
    private var step3Done: Bool {
        controller.grants.contains { !$0.revoked } || !controller.connections.isEmpty
    }
    private var allDone: Bool { step1Done && step2Done && step3Done }

    var body: some View {
        if !dismissed && !allDone {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Get started").font(.subheadline).bold()
                    Spacer()
                    Button { dismissed = true } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Hide this checklist")
                }
                step(1, done: step1Done, "Connect an AI subscription") {
                    tab = .providers
                }
                step(2, done: step2Done, "Point a tool at your local endpoint") {
                    useWithExpanded = true
                    tab = .providers
                }
                step(3, done: step3Done, "Share a code with a friend — or redeem theirs") {
                    tab = .share
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
        }
    }

    private func step(_ n: Int, done: Bool, _ title: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                    .foregroundStyle(done ? Color.green : Color.secondary)
                    .frame(width: 16) // glyphs differ slightly; don't shift the row
                Text(title)
                    .font(.caption)
                    .strikethrough(done)
                    .foregroundStyle(done ? Color.secondary : Color.primary)
                Spacer()
                if !done {
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(done)
    }
}

// MARK: - Footer

struct FooterView: View {
    @EnvironmentObject var controller: AppController
    var body: some View {
        HStack {
            if let err = controller.softError {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(err) // full text on hover…
                CopyIconButton(text: err, help: "Copy full error") // …and copyable
            } else {
                Text("Updated \(controller.lastUpdated?.formatted(date: .omitted, time: .standard) ?? "—")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Quit") { controller.requestQuit() }
                .controlSize(.small)
        }
        .padding(8)
    }
}

// MARK: - Small components

/// compact renders a count as 950, 12.3K, or 4.5M for tight UI labels.
func compact(_ n: Int) -> String {
    let v = Double(n)
    switch n {
    case ..<1_000: return "\(n)"
    case ..<1_000_000: return String(format: "%.1fK", v / 1_000)
    default: return String(format: "%.1fM", v / 1_000_000)
    }
}

/// parseTokenAmount parses a user-entered token allotment: plain counts
/// ("250000", commas/underscores ok) plus k/m/b shorthand ("500k", "2.5m").
/// Blank or unparseable (incl. ≤0) means unlimited (0).
func parseTokenAmount(_ s: String) -> Int {
    var t = s.trimmingCharacters(in: .whitespaces).lowercased()
    t = t.replacingOccurrences(of: ",", with: "")
        .replacingOccurrences(of: "_", with: "")
    guard !t.isEmpty else { return 0 }
    var mult = 1.0
    if let suffix = t.last, "kmb".contains(suffix) {
        switch suffix {
        case "k": mult = 1_000
        case "m": mult = 1_000_000
        default: mult = 1_000_000_000
        }
        t.removeLast()
    }
    guard let v = Double(t), v > 0 else { return 0 }
    return Int(v * mult)
}

/// tokenAmountString renders a token count for prefilling the edit field, using
/// the same shorthand the parser accepts (5_000_000 -> "5m", 250_000 -> "250k",
/// 1234 -> "1234").
func tokenAmountString(_ tokens: Int) -> String {
    guard tokens > 0 else { return "" }
    if tokens % 1_000_000 == 0 { return "\(tokens / 1_000_000)m" }
    if tokens % 1_000 == 0 { return "\(tokens / 1_000)k" }
    return String(tokens)
}

/// Copy button that flashes a green checkmark so the click visibly did something.
/// The label has a fixed footprint: the checkmark and doc glyphs differ in size,
/// and since the popover hugs its content height, an unframed swap makes the
/// whole UI shift.
struct CopyIconButton: View {
    let text: String
    var help: String = "Copy"
    var onCopy: (() -> Void)? = nil
    @State private var copied = false

    var body: some View {
        Button {
            AppController.shared.copyToPasteboard(text)
            onCopy?()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? AnyShapeStyle(Color.green) : AnyShapeStyle(.primary))
                .frame(width: 16, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

struct StatusDot: View {
    let on: Bool
    var body: some View {
        Circle().fill(on ? Color.green : Color.secondary.opacity(0.5))
            .frame(width: 8, height: 8)
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

struct SectionTitle: View {
    let title: String
    let subtitle: String?
    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline).bold()
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct EmptyHint: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}
