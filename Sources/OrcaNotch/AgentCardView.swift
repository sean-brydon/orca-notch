import SwiftUI

private let dim = Color.white.opacity(0.45)
private let faint = Color.white.opacity(0.08)

/// A numbered choice currently drawn on the agent's screen (permission prompt, question menu).
struct MenuChoice: Identifiable, Equatable {
    let key: String
    let label: String
    let selected: Bool
    var id: String { key }

    private static let pattern = try! NSRegularExpression(pattern: #"^\s*(❯|›|>)?\s*(\d)\.\s+(.+?)\s*$"#)

    /// Reads the menu from the bottom of the screen: the last contiguous run of `N. label` rows.
    static func parse(_ lines: [String]) -> [MenuChoice] {
        var found: [MenuChoice] = []
        var gap = 0
        for raw in lines.suffix(24).reversed() {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "│ "))
            let ns = line as NSString
            if let m = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                found.append(MenuChoice(key: ns.substring(with: m.range(at: 2)),
                                        label: ns.substring(with: m.range(at: 3)),
                                        selected: m.range(at: 1).location != NSNotFound))
                gap = 0
            } else if !found.isEmpty {
                // Allow a wrapped label line or two between options, then stop.
                gap += 1
                if gap > 2 { break }
            }
        }
        let choices = Array(found.reversed())
        // Require a real 1..n menu so stray numbered prose doesn't become buttons.
        guard choices.count >= 2, choices.first?.key == "1",
              choices.map(\.key) == (1...choices.count).map(String.init) else { return [] }
        return choices
    }
}

struct AgentDetailPane: View {
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var store: AgentStore
    @AppStorage("showScreen") private var showScreen = false
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let agent = store.selectedAgent {
                header(agent)
                let recovered = ScreenTranscript.extract(store.screenLines)
                let prompt = agent.prompt ?? recovered.prompt
                let reply = agent.reply ?? recovered.reply
                if showScreen || (reply == nil && prompt == nil) {
                    TerminalScreenView(lines: store.screenLines, status: store.screenStatus)
                    if agent.terminalHandle != nil { quickKeys }
                } else {
                    AgentCard(agent: agent, prompt: prompt, reply: reply,
                              choices: MenuChoice.parse(store.screenLines)) { key in
                        store.send(key, enter: false)
                    }
                }
                if agent.terminalHandle != nil { replyField(agent) }
            } else {
                Spacer()
                Text("Select an agent").font(.system(size: 12)).foregroundStyle(dim).frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .onChange(of: model.focusInputToken) { _, _ in inputFocused = true }
        .onChange(of: model.demoTyping) { _, typed in if let typed { draft = typed } }
    }

    private func header(_ agent: Agent) -> some View {
        HStack(spacing: 8) {
            Text(agent.headline.uppercased())
                .font(.system(size: 9.5, weight: .bold)).kerning(0.5)
                .foregroundStyle(.black)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(agent.state.color))
            Text(agent.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 6)
            Picker("", selection: $showScreen) {
                Image(systemName: "text.bubble").tag(false).help("Card")
                Image(systemName: "terminal").tag(true).help("Screen")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button { store.openInOrca(agent) } label: {
                Label("Orca", systemImage: "arrow.up.forward.app").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(PillButtonStyle())
            .help("Open this terminal in Orca")
        }
    }

    private var quickKeys: some View {
        HStack(spacing: 5) {
            ForEach(QuickKey.all) { key in
                Button(key.label) { store.send(key.text, enter: key.enter) }
                    .buttonStyle(PillButtonStyle(mono: true))
                    .help(key.help)
            }
            Spacer(minLength: 0)
        }
    }

    private func replyField(_ agent: Agent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(agent.state.color)
                TextField("Reply to \(agent.agentType)…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .autocorrectionDisabled()
                    .focused($inputFocused)
                    .onSubmit {
                        guard !draft.isEmpty else { return }
                        store.send(draft, enter: true)
                        draft = ""
                    }
                Text("⏎").font(.system(size: 11)).foregroundStyle(dim)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(inputFocused ? agent.state.color.opacity(0.6) : faint))
            if let err = store.sendError {
                Text(err).font(.system(size: 10)).foregroundStyle(.red).lineLimit(1)
            }
        }
    }
}

struct AgentCard: View {
    let agent: Agent
    let prompt: String?
    let reply: String?
    let choices: [MenuChoice]
    let onChoose: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let prompt, !prompt.isEmpty {
                        youBubble(prompt)
                    }
                    if let reply, !reply.isEmpty {
                        agentReply(reply)
                    }
                    stateCard
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(.bottom)
            .onChange(of: reply) { _, _ in
                DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.04)))
    }

    private func youBubble(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Spacer(minLength: 60)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.12)))
        }
    }

    private func agentReply(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").font(.system(size: 10, weight: .bold)).foregroundStyle(TerminalPalette.claude)
                Text(agent.agentType).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(dim)
            }
            Text(Self.markdown(text))
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .foregroundStyle(Color(white: 0.9))
                .tint(TerminalPalette.blue)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var stateCard: some View {
        switch agent.state {
        case .working:
            HStack(spacing: 8) {
                PulsingDot(color: agent.state.color, size: 7)
                Text(agent.toolName.map { "Running \($0)" } ?? "Working…")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(agent.state.color)
                if let input = agent.toolInput {
                    Text(input).font(.system(size: 11, design: .monospaced)).foregroundStyle(dim).lineLimit(1)
                }
            }
        case .blocked, .waiting:
            actionCard
        case .done:
            HStack(spacing: 6) {
                Image(systemName: agent.interrupted ? "stop.circle" : "checkmark.circle.fill")
                Text(agent.interrupted ? "Interrupted" : "Finished — reply below to keep going")
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(agent.interrupted ? dim : agent.state.color)
        }
    }

    private var actionCard: some View {
        let color = agent.state.color
        return VStack(alignment: .leading, spacing: 10) {
            Text(agent.state == .blocked ? "WANTS TO RUN" : "ASKING YOU")
                .font(.system(size: 9.5, weight: .bold)).kerning(0.6).foregroundStyle(color)

            if agent.state == .blocked, let tool = agent.toolName {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tool).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                    if let input = agent.toolInput {
                        Text(input)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color(white: 0.8))
                            .lineLimit(6)
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
            }
            if let q = agent.question {
                Text(q).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !choices.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(choices) { choice in
                        Button { onChoose(choice.key) } label: {
                            HStack(spacing: 8) {
                                Text(choice.key)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.black)
                                    .frame(width: 18, height: 18)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(choice.selected ? color : Color.white.opacity(0.7)))
                                Text(choice.label).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(choice.selected ? 0.12 : 0.05)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if agent.state == .blocked {
                HStack(spacing: 6) {
                    Button("Approve") { onChoose("1") }.buttonStyle(ActionButtonStyle(color: TerminalPalette.green))
                    Button("Always") { onChoose("2") }.buttonStyle(ActionButtonStyle(color: .white.opacity(0.7)))
                    Button("Deny") { onChoose("\u{1b}") }.buttonStyle(ActionButtonStyle(color: TerminalPalette.red))
                }
            } else {
                Text("Type your answer below.").font(.system(size: 11)).foregroundStyle(dim)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.35)))
    }

    static func markdown(_ text: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var s = (try? AttributedString(markdown: text, options: opts)) ?? AttributedString(text)
        for run in s.runs where run.inlinePresentationIntent?.contains(.code) == true {
            s[run.range].font = .system(size: 11.5, design: .monospaced)
            s[run.range].foregroundColor = TerminalPalette.code
        }
        return s
    }
}

struct ActionButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(Capsule().fill(color.opacity(configuration.isPressed ? 0.7 : 1)))
    }
}
