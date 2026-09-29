import ServiceManagement
import SwiftUI

// MARK: - Shape

/// Notch silhouette: flush with the top edge, with small concave flares at the top corners
/// (so it melts into the bezel like the hardware notch) and rounded bottom corners.
struct NotchShape: Shape {
    var flare: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, radius) }
        set { flare = newValue.first; radius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let radius = min(radius, (r.width - flare * 2) / 2, r.height)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + flare, y: r.minY + flare), control: CGPoint(x: r.minX + flare, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + flare, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.minX + flare + radius, y: r.maxY), control: CGPoint(x: r.minX + flare, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - flare - radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - flare, y: r.maxY - radius), control: CGPoint(x: r.maxX - flare, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - flare, y: r.minY + flare))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - flare, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Palette

extension AgentState {
    var color: Color {
        switch self {
        case .blocked: return Color(red: 1.0, green: 0.45, blue: 0.25)
        case .waiting: return Color(red: 1.0, green: 0.78, blue: 0.2)
        case .done: return Color(red: 0.3, green: 0.85, blue: 0.5)
        case .working: return Color(red: 0.35, green: 0.62, blue: 1.0)
        }
    }

    var symbol: String {
        switch self {
        case .blocked: return "hand.raised.fill"
        case .waiting: return "questionmark.bubble.fill"
        case .done: return "checkmark.circle.fill"
        case .working: return "circle.dotted"
        }
    }
}

private let dim = Color.white.opacity(0.45)
private let faint = Color.white.opacity(0.08)

private func shortHost(_ host: String) -> String {
    host.split(separator: "/").last.map(String.init) ?? host
}

private func ago(_ ms: Double) -> String {
    let s = max(0, Date().timeIntervalSince1970 - ms / 1000)
    switch s {
    case ..<45: return "now"
    case ..<3600: return "\(Int(s / 60))m"
    case ..<86400: return "\(Int(s / 3600))h"
    default: return "\(Int(s / 86400))d"
    }
}

// MARK: - Root

struct NotchRootView: View {
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var store: AgentStore
    let onCollapse: () -> Void
    let onPin: () -> Void

    var body: some View {
        let size = model.bodySize(showEars: !store.agents.isEmpty)
        let flare: CGFloat = model.mode == .expanded ? 14 : 7
        let radius: CGFloat = model.mode == .expanded ? 26 : (model.mode == .peek ? 20 : 10)

        ZStack(alignment: .top) {
            NotchShape(flare: flare, radius: radius)
                .fill(Color.black)
                .frame(width: size.width + flare * 2, height: size.height)
                .shadow(color: .black.opacity(model.mode == .collapsed ? 0 : 0.5), radius: 20, y: 10)

            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(NotchShape(flare: 0, radius: radius))
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { onPin() })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .collapsed:
            CollapsedEars().transition(.opacity)
        case .peek:
            PeekView(agent: store.agents.first { $0.id == model.peekAgentID })
                .transition(.opacity.combined(with: .move(edge: .top)))
        case .expanded:
            ExpandedView(onCollapse: onCollapse)
                .transition(.opacity.animation(.easeOut(duration: 0.18).delay(0.08)))
        }
    }
}

// MARK: - Collapsed

struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 7
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background(Circle().fill(color.opacity(0.5)).scaleEffect(on ? 2.4 : 1).opacity(on ? 0 : 0.8))
            .onAppear {
                withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { on = true }
            }
    }
}

struct CollapsedEars: View {
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var store: AgentStore

    var body: some View {
        let attention = store.attentionAgents
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                if store.workingCount > 0 {
                    PulsingDot(color: AgentState.working.color, size: 6)
                    Text("\(store.workingCount)").font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(AgentState.working.color)
                } else if !store.agents.isEmpty {
                    Circle().fill(dim).frame(width: 5, height: 5)
                }
            }
            .frame(width: NotchModel.earWidth)

            Spacer(minLength: 0)

            ZStack {
                if let top = attention.first {
                    Text("\(attention.count)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(minWidth: 17, minHeight: 17)
                        .padding(.horizontal, attention.count > 9 ? 3 : 0)
                        .background(Capsule().fill(top.state.color))
                        .background(PulsingDot(color: top.state.color, size: 14).opacity(0.6))
                }
            }
            .frame(width: NotchModel.earWidth)
        }
        .frame(maxHeight: model.screenHasNotch ? model.hardwareNotch.height : 26)
    }
}

// MARK: - Peek

struct PeekView: View {
    @EnvironmentObject var model: NotchModel
    let agent: Agent?

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.screenHasNotch ? model.hardwareNotch.height : 0)
            if let agent {
                HStack(spacing: 12) {
                    Image(systemName: agent.state.symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(agent.state.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(agent.headline) · \(agent.title)")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        Text(agent.detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        Text("\(shortHost(agent.hostLabel)) · \(agent.location) · \(agent.agentType)")
                            .font(.system(size: 10)).foregroundStyle(dim).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
            }
        }
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var store: AgentStore
    let onCollapse: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 12) {
                AgentListView().frame(width: 290)
                AgentDetailPane()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    private var header: some View {
        let needs = store.attentionAgents.count
        let notchW = model.screenHasNotch ? model.hardwareNotch.width : 0
        return HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "fish.fill").foregroundStyle(.white)
                Text("Orca").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                Text(needs > 0 ? "\(needs) need\(needs == 1 ? "s" : "") you" : "all clear")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(needs > 0 ? AgentState.blocked.color : dim)
                if store.workingCount > 0 {
                    Text("· \(store.workingCount) working").font(.system(size: 11)).foregroundStyle(dim)
                }
            }
            Spacer(minLength: notchW + 16)
            HStack(spacing: 10) {
                ForEach(store.hosts) { host in
                    HStack(spacing: 4) {
                        Circle().fill(host.online ? AgentState.done.color : Color.red.opacity(0.8)).frame(width: 6, height: 6)
                        Text(shortHost(host.name)).font(.system(size: 10.5)).foregroundStyle(dim)
                    }
                    .help(host.error ?? "\(host.name) connected")
                }
                SettingsMenu()
                Button(action: onCollapse) {
                    Image(systemName: "chevron.up").font(.system(size: 11, weight: .bold)).foregroundStyle(dim)
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
            }
        }
        .padding(.horizontal, 24)
        .frame(height: max(model.screenHasNotch ? model.hardwareNotch.height : 0, 34))
    }
}

struct SettingsMenu: View {
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var store: AgentStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Menu {
            Toggle("Sound on new alerts", isOn: $model.soundEnabled)
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }))
            Divider()
            Button("Clear finished") { store.acknowledgeAllDone() }
            Button("Rescan Orca environments") { store.refreshEnvironments() }
            Divider()
            Text("Toggle: ⌥⌘O")
            Button("Quit Orca Notch") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape.fill").font(.system(size: 11)).foregroundStyle(dim)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Agent list

struct AgentListView: View {
    @EnvironmentObject var store: AgentStore

    var body: some View {
        let needs = store.agents.filter(\.needsAttention)
        let working = store.agents.filter { !$0.needsAttention && $0.state == .working }
        let rest = store.agents.filter { !$0.needsAttention && $0.state != .working }

        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                if store.agents.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "moon.zzz.fill").font(.system(size: 22)).foregroundStyle(dim)
                        Text(store.hosts.contains(where: \.online) ? "No agents running" : "Can't reach Orca")
                            .font(.system(size: 12)).foregroundStyle(dim)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
                section("Needs you", needs)
                section("Working", working)
                section("Recent", rest)
            }
            .padding(6)
        }
        .scrollIndicators(.never)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.04)))
    }

    @ViewBuilder private func section(_ title: String, _ agents: [Agent]) -> some View {
        if !agents.isEmpty {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(dim)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(agents) { agent in
                AgentRowView(agent: agent, selected: agent.id == store.selectedID)
                    .id(agent.attentionKey)
                    .onTapGesture { store.selectedID = agent.id }
            }
        }
    }
}

struct AgentRowView: View {
    let agent: Agent
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Group {
                if agent.state == .working {
                    PulsingDot(color: agent.state.color, size: 7)
                } else {
                    Circle().fill(agent.needsAttention ? agent.state.color : dim).frame(width: 7, height: 7)
                }
            }
            .frame(width: 10, height: 10)
            .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(ago(agent.stateStartedAt)).font(.system(size: 10)).foregroundStyle(dim)
                }
                Text(AgentCard.markdown(agent.detail))
                    .font(.system(size: 11))
                    .foregroundStyle(agent.needsAttention && agent.state != .done ? agent.state.color.opacity(0.9) : .white.opacity(0.6))
                    .lineLimit(2)
                Text("\(shortHost(agent.hostLabel)) · \(agent.location) · \(agent.agentType)")
                    .font(.system(size: 10)).foregroundStyle(dim).lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.white.opacity(0.11) : .clear))
        .contentShape(Rectangle())
    }
}

// MARK: - Screen

struct QuickKey: Identifiable {
    let label: String
    let text: String
    let enter: Bool
    let help: String
    var id: String { label }

    static let all: [QuickKey] = [
        QuickKey(label: "1", text: "1", enter: false, help: "Send 1 (e.g. approve)"),
        QuickKey(label: "2", text: "2", enter: false, help: "Send 2"),
        QuickKey(label: "3", text: "3", enter: false, help: "Send 3"),
        QuickKey(label: "⏎", text: "\r", enter: false, help: "Enter"),
        QuickKey(label: "esc", text: "\u{1b}", enter: false, help: "Escape"),
        QuickKey(label: "⇧tab", text: "\u{1b}[Z", enter: false, help: "Shift-Tab (cycle mode)"),
        QuickKey(label: "↑", text: "\u{1b}[A", enter: false, help: "Up arrow"),
        QuickKey(label: "↓", text: "\u{1b}[B", enter: false, help: "Down arrow"),
        QuickKey(label: "⌃C", text: "\u{3}", enter: false, help: "Interrupt"),
    ]
}

struct TerminalScreenView: View {
    let lines: [String]
    let status: String?

    var body: some View {
        let styled = TerminalStyler.style(lines)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1.5) {
                    if styled.isEmpty {
                        Text(status ?? "Loading…")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(TerminalPalette.dim)
                    }
                    ForEach(Array(styled.enumerated()), id: \.offset) { _, line in
                        switch line {
                        case .rule:
                            Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1).padding(.vertical, 5)
                        case .text(let text, let indent, let highlight):
                            Text(text)
                                .font(.system(size: 11, design: .monospaced))
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, indent)
                                .padding(.horizontal, highlight == nil ? 0 : 5)
                                .padding(.vertical, highlight == nil ? 0 : 1.5)
                                .background(RoundedRectangle(cornerRadius: 4).fill(highlight ?? .clear))
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(.bottom)
            .onChange(of: lines) { _, _ in
                DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.055)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(faint))
        .overlay(alignment: .bottomTrailing) {
            if let status, !lines.isEmpty {
                Text(status).font(.system(size: 10)).foregroundStyle(dim).padding(8)
            }
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    var mono = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium, design: mono ? .monospaced : .default))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, mono ? 8 : 10)
            .frame(minWidth: mono ? 26 : nil, minHeight: 22)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.2 : 0.09)))
    }
}
