import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

// `OrcaNotch --demo` plays a scripted demo with mock agents on a fake desktop stage.
// `OrcaNotch --demo-record out.mp4` does the same and records only the stage window.

// MARK: - Mock data

private enum Mock {
    static func agent(host: String?, repo: String, branch: String, pane: String, state: String,
                      agentType: String = "claude", title: String, prompt: String? = nil,
                      reply: String? = nil, tool: String? = nil, input: String? = nil,
                      question: String? = nil, startedSecondsAgo: Double = 5) -> Agent {
        let now = Date().timeIntervalSince1970 * 1000
        var row: [String: Any] = [
            "paneKey": "\(pane):00000000-0000-4000-8000-000000000000",
            "state": state, "agentType": agentType, "taskTitle": title,
            "stateStartedAt": now - startedSecondsAgo * 1000, "updatedAt": now - startedSecondsAgo * 1000,
        ]
        row["prompt"] = prompt
        row["lastAssistantMessage"] = reply
        row["toolName"] = tool
        row["toolInput"] = input
        row["interactivePrompt"] = question
        let worktree: [String: Any] = [
            "worktreeId": "\(repo)-\(branch)", "repo": repo, "path": "/demo/\(repo)",
            "branch": "refs/heads/\(branch)", "agents": [row],
        ]
        let terminal: [String: Any] = ["handle": "term_\(pane)", "tabId": pane, "leafId": "00000000-0000-4000-8000-000000000000"]
        let wt = try! JSONDecoder().decode(Worktree.self, from: JSONSerialization.data(withJSONObject: worktree))
        let term = try! JSONDecoder().decode(TerminalRow.self, from: JSONSerialization.data(withJSONObject: terminal))
        return Agent(row: wt.agents[0], worktree: wt, host: host, terminal: term)
    }

    static let hosts = [HostStatus(name: "local", online: true), HostStatus(name: "devbox", online: true),
                        HostStatus(name: "ci-runner", online: true)]

    static let checkoutWorking = agent(host: nil, repo: "storefront", branch: "feat/checkout-v2", pane: "p1", state: "working",
                                       title: "Checkout redesign", prompt: "Rebuild the checkout summary with the new pricing table",
                                       reply: "Pricing table is wired up. Now updating the summary card.", tool: "Edit",
                                       input: "src/checkout/Summary.tsx", startedSecondsAgo: 540)

    static func authFlake(_ state: String, ago: Double = 1) -> Agent {
        agent(host: "devbox", repo: "api", branch: "fix/auth-flake", pane: "p2", state: state, agentType: "claude",
              title: "Flaky auth tests",
              prompt: "The session refresh tests fail about 1 in 5 runs on CI. Find out why and fix it.",
              reply: state == "working" && ago < 5
                ? "Running the suite serially to confirm the fix…"
                : "Found it: two tests share one **Redis** key, so parallel runs expire each other's session. I gave each test its own key prefix in `test/helpers/session.ts`. I want to run the suite 20 times to be sure.",
              tool: "Bash", input: "pnpm test --filter auth -- --runInBand --repeat 20", startedSecondsAgo: ago)
    }

    static func releaseNotes(_ state: String, prompt: String = "Draft the 4.2 release notes from the merged PRs", ago: Double = 1) -> Agent {
        agent(host: "ci-runner", repo: "docs", branch: "release/4.2", pane: "p3", state: state, agentType: "codex",
              title: "Release notes 4.2", prompt: prompt,
              reply: state == "waiting"
                ? "The draft covers **31 merged PRs** grouped into Features, Fixes and Internal. Three PRs add features that are still behind beta flags."
                : "Adding the beta section and linking each flag to its docs page…",
              question: state == "waiting" ? "Should the notes include the beta-flagged features?" : nil,
              startedSecondsAgo: ago)
    }

    static func billing(_ state: String, ago: Double = 1) -> Agent {
        agent(host: "devbox", repo: "billing", branch: "chore/webhooks-v2", pane: "p4", state: state,
              title: "Migrate billing webhooks",
              prompt: "Move our webhook handlers to the v2 event format",
              reply: state == "done"
                ? "All **14 webhook handlers** now use the v2 event format.\n\n- Replaced `event.data.object` lookups with typed payloads\n- Added replay protection with the `event.id` idempotency key\n- 212 tests pass, including new fixtures for each event\n\nOpened draft PR #482: https://github.com/acme/billing/pull/482"
                : "Converting the invoice handlers now.",
              tool: state == "done" ? nil : "Edit", input: state == "done" ? nil : "src/webhooks/invoice.ts",
              startedSecondsAgo: ago)
    }

    static let reactUpgrade = agent(host: nil, repo: "storefront", branch: "chore/react-19", pane: "p5", state: "done",
                                    title: "Upgrade to React 19",
                                    prompt: "Upgrade to React 19 and fix anything that breaks",
                                    reply: "Upgraded to React 19. Two components used the removed `defaultProps` on function components, so I moved those to default parameters.",
                                    startedSecondsAgo: 3 * 3600)

    static let authBlockedScreen = [
        "● Found it: two tests share one Redis key, so parallel runs expire each other's",
        "  session. I gave each test its own key prefix in test/helpers/session.ts.",
        "● Update(test/helpers/session.ts)",
        "  ⎿  Updated test/helpers/session.ts with 3 additions and 1 removal",
        "      12 -  const key = 'session:test'",
        "      12 +  const key = `session:test:${randomUUID()}`",
        "────────────────────────────────────────────────────────────────────────────",
        " Bash command",
        "   pnpm test --filter auth -- --runInBand --repeat 20",
        " Do you want to proceed?",
        " ❯ 1. Yes",
        "   2. Yes, and don't ask again for pnpm test commands",
        "   3. No, and tell Claude what to do differently (esc)",
    ]

    static let authRunningScreen = [
        "● Bash(pnpm test --filter auth -- --runInBand --repeat 20)",
        "  ⎿  run 7/20 · 48 passed",
        "✻ Verifying… (41s · esc to interrupt)",
        "────────────────────────────────────────────────────────────────────────────",
        "❯",
        "────────────────────────────────────────────────────────────────────────────",
        "  ⏵⏵ accept edits on (shift+tab to cycle)",
    ]

    static let notesWaitingScreen = [
        "• The draft covers 31 merged PRs grouped into Features, Fixes and Internal.",
        "  Three PRs add features that are still behind beta flags.",
        "",
        "  Should the notes include the beta-flagged features?",
        "  1. Yes, in a separate Beta section",
        "  2. No, GA features only",
        "  3. Something else",
    ]

    static let billingDoneScreen = [
        "● Bash(pnpm test)",
        "  ⎿  212 passed (14 files) · 9.8s",
        "● Bash(gh pr create --draft --title \"Webhooks v2\")",
        "  ⎿  https://github.com/acme/billing/pull/482",
        "● All 14 webhook handlers now use the v2 event format.",
        "  - Replaced event.data.object lookups with typed payloads",
        "  - Added replay protection with the event.id idempotency key",
        "  - 212 tests pass, including new fixtures for each event",
        "  Opened draft PR #482: https://github.com/acme/billing/pull/482",
        "✻ Worked for 6m 12s",
        "────────────────────────────────────────────────────────────────────────────",
        "❯",
        "────────────────────────────────────────────────────────────────────────────",
        "  ⏵⏵ accept edits on (shift+tab to cycle)",
    ]
}

// MARK: - Stage

struct DemoStageView: View {
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var store: AgentStore
    static let size = CGSize(width: 1512, height: 640)

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.13, green: 0.16, blue: 0.33),
                                    Color(red: 0.36, green: 0.25, blue: 0.5),
                                    Color(red: 0.86, green: 0.5, blue: 0.42)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            // A background app window so the notch has something to sit over.
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.12).opacity(0.92))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 7) {
                            ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.8)).frame(width: 11, height: 11) }
                        }
                        ForEach(0..<9, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.07))
                                .frame(width: CGFloat([420, 610, 380, 540, 300, 580, 460, 350, 500][i]), height: 9)
                        }
                    }
                    .padding(16)
                }
                .frame(width: 1000, height: 480)
                .offset(y: 110)
                .shadow(color: .black.opacity(0.4), radius: 30, y: 12)

            HStack(spacing: 18) {
                Image(systemName: "apple.logo").font(.system(size: 14))
                Text("Orca").fontWeight(.bold)
                ForEach(["File", "Edit", "View", "Window", "Help"], id: \.self) { Text($0) }
                Spacer()
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text("Tue 10:42")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 32)
            .background(Color.black.opacity(0.2))

            // The camera housing, always there under whatever the app draws.
            RoundedRectangle(cornerRadius: 10).fill(.black).frame(width: 190, height: 32).offset(y: -10).padding(.top, 0)
                .frame(height: 32, alignment: .bottom).clipped()

            NotchRootView(onCollapse: {}, onPin: {})

            if let p = model.demoCursor {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.black)
                    .shadow(color: .white, radius: 0.6).shadow(color: .white, radius: 0.6).shadow(color: .black.opacity(0.4), radius: 3, y: 2)
                    .scaleEffect(model.demoCursorDown ? 0.85 : 1, anchor: .topLeading)
                    .position(x: p.x + 7, y: p.y + 11)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
        .preferredColorScheme(.dark)
    }
}

// MARK: - Director

@MainActor
final class DemoDirector {
    let model = NotchModel()
    let store = AgentStore()
    private var window: NSWindow!
    private var recorder: DemoRecorder?
    private var recordStart: Date?
    private let outputURL: URL?

    init(recordTo: URL?) { outputURL = recordTo }

    // Stage geometry: expanded panel is 860 wide, centred at x = 756.
    private let notch = CGPoint(x: 756, y: 14)
    private let away = CGPoint(x: 1180, y: 420)

    func start() {
        model.hardwareNotch = CGSize(width: 190, height: 32)
        model.screenHasNotch = true
        UserDefaults.standard.set(false, forKey: "showScreen")

        window = NSWindow(contentRect: NSRect(origin: .zero, size: DemoStageView.size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Orca Notch Demo"
        window.contentView = NSHostingView(rootView: DemoStageView().environmentObject(model).environmentObject(store))
        window.center()
        window.orderFrontRegardless()

        store.onNewAttention = { [weak self] agent in self?.peek(agent) }
        store.onDemoSend = { [weak self] agent, text in self?.handleSend(agent: agent, text: text) }
        model.demoCursor = away

        Task { await run() }
    }

    // Live state the script mutates.
    private var agents: [String: Agent] = [:]
    private var screens: [String: [String]] = [:]

    private func publish() {
        store.setDemo(hosts: Mock.hosts, agents: Array(agents.values), screens: screens)
    }

    private func set(_ agent: Agent, screen: [String]? = nil) {
        agents[agent.id] = agent
        if let screen { screens[agent.id] = screen }
        publish()
    }

    private func handleSend(agent: Agent, text: String) {
        if agent.paneKey.hasPrefix("p2") {
            set(Mock.authFlake("working"), screen: Mock.authRunningScreen)
        } else if agent.paneKey.hasPrefix("p3") {
            set(Mock.releaseNotes("working", prompt: text), screen: [])
        }
    }

    private func peek(_ agent: Agent) {
        guard model.mode != .expanded else { return }
        model.peekAgentID = agent.id
        setMode(.peek)
    }

    private func setMode(_ mode: NotchMode) {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { model.mode = mode }
        store.isViewing = mode == .expanded
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func move(to p: CGPoint, _ duration: Double = 0.7) async {
        withAnimation(.easeInOut(duration: duration)) { model.demoCursor = p }
        await wait(duration)
    }

    private func click() async {
        if let recordStart { FileHandle.standardError.write(String(format: "click at %.2fs\n", Date().timeIntervalSince(recordStart)).data(using: .utf8)!) }
        withAnimation(.easeOut(duration: 0.08)) { model.demoCursorDown = true }
        await wait(0.12)
        withAnimation(.easeOut(duration: 0.12)) { model.demoCursorDown = false }
    }

    private func type(_ text: String) async {
        for i in 1...text.count {
            model.demoTyping = String(text.prefix(i))
            await wait(0.045)
        }
    }

    private func run() async {
        // Initial fleet: nothing needs you yet.
        agents = [:]
        for a in [Mock.checkoutWorking, Mock.authFlake("working", ago: 300), Mock.releaseNotes("working", ago: 200),
                  Mock.billing("working", ago: 380), Mock.reactUpgrade] { agents[a.id] = a }
        screens = [:]
        publish()
        await wait(0.8)

        if let outputURL {
            do {
                recorder = try await DemoRecorder.start(windowNumber: window.windowNumber, url: outputURL)
                recordStart = Date()
            } catch {
                FileHandle.standardError.write("Recording failed: \(error)\n".data(using: .utf8)!)
                NSApp.terminate(nil)
                return
            }
        }
        await wait(1.5)

        // 1. An agent hits a permission prompt: the notch peeks.
        set(Mock.authFlake("blocked"), screen: Mock.authBlockedScreen)
        await wait(2.2)

        // 2. Hover the notch to open the pull-down on that agent.
        await move(to: notch, 0.9)
        store.selectedID = Mock.authFlake("blocked").id
        model.peekAgentID = nil
        setMode(.expanded)
        await wait(2.4)

        // 3. Approve it from the card.
        await move(to: CGPoint(x: 742, y: 344), 0.8)
        await click()
        store.send("1", enter: false)
        await wait(1.6)

        // 4. Meanwhile another agent asks a question.
        set(Mock.releaseNotes("waiting"), screen: Mock.notesWaitingScreen)
        await wait(1.0)
        await move(to: CGPoint(x: 452, y: 94), 0.8)
        await click()
        store.selectedID = Mock.releaseNotes("waiting").id
        await wait(2.2)

        // 5. Answer in your own words.
        await move(to: CGPoint(x: 860, y: 489), 0.7)
        await click()
        await type("Yes, in a Beta section, and link each flag's docs")
        await wait(0.4)
        store.send(model.demoTyping ?? "", enter: true)
        model.demoTyping = ""
        await wait(1.6)

        // 6. Move away: it tucks back into the notch.
        await move(to: away, 0.8)
        setMode(.collapsed)
        await wait(2.0)

        // 7. A long task finishes: green peek.
        set(Mock.billing("done"), screen: Mock.billingDoneScreen)
        await wait(2.4)
        await move(to: notch, 0.9)
        store.selectedID = Mock.billing("done").id
        model.peekAgentID = nil
        setMode(.expanded)
        await wait(3.2)

        // 8. Flip to the raw screen view, then back.
        await move(to: CGPoint(x: 1084, y: 47), 0.8)
        await click()
        UserDefaults.standard.set(true, forKey: "showScreen")
        await wait(2.8)
        await click()
        UserDefaults.standard.set(false, forKey: "showScreen")
        await wait(1.2)

        await move(to: away, 0.8)
        setMode(.collapsed)
        await wait(2.0)

        if let recorder {
            await recorder.stop()
            print("Saved demo to \(outputURL!.path)")
            NSApp.terminate(nil)
        } else {
            await wait(1.5)
            await run()
        }
    }
}

// MARK: - Recorder (ScreenCaptureKit, stage window only)

final class DemoRecorder: NSObject, SCStreamOutput {
    private let stream: SCStream
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "demo.recorder")
    private var started = false

    private init(stream: SCStream, writer: AVAssetWriter, input: AVAssetWriterInput) {
        self.stream = stream
        self.writer = writer
        self.input = input
    }

    static func start(windowNumber: Int, url: URL) async throws -> DemoRecorder {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { Int($0.windowID) == windowNumber }) else {
            throw OrcaCLI.Failure(message: "Stage window not found for capture")
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let width = Int(window.frame.width * scale), height = Int(window.frame.height * scale)

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 14_000_000],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()

        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: nil)
        let recorder = DemoRecorder(stream: stream, writer: writer, input: input)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
        try await stream.startCapture()
        return recorder
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        if !started {
            writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData { input.append(buffer) }
    }

    func stop() async {
        try? await stream.stopCapture()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.input.markAsFinished()
                self.writer.finishWriting { done.resume() }
            }
        }
    }
}
