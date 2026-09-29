import AppKit
import Foundation

struct HostStatus: Identifiable, Equatable {
    let name: String
    var online: Bool
    var error: String?
    var id: String { name }
}

@MainActor
final class AgentStore: ObservableObject {
    @Published private(set) var agents: [Agent] = []
    @Published private(set) var hosts: [HostStatus] = []
    @Published var selectedID: String? {
        didSet { if selectedID != oldValue { selectionChanged() } }
    }
    @Published private(set) var screenLines: [String] = []
    @Published private(set) var screenStatus: String?
    @Published private(set) var sendError: String?

    /// Fired once per new attention state (a fresh block/wait, or an agent finishing).
    var onNewAttention: ((Agent) -> Void)?

    var isViewing = false {
        didSet { if isViewing != oldValue { restartScreenLoop() } }
    }

    var attentionAgents: [Agent] { agents.filter(\.needsAttention) }
    var workingCount: Int { agents.filter { $0.state == .working }.count }
    var selectedAgent: Agent? { agents.first { $0.id == selectedID } }

    private static let pollInterval: UInt64 = 2_000_000_000
    private static let hideDoneAfter: Double = 24 * 60 * 60 * 1000
    private static let orcaBundleID = "com.stablyai.orca"

    private var environmentNames: [String] = []
    private var lastEnvironmentFetch = Date.distantPast
    private var terminalsByHost: [String: [String: TerminalRow]] = [:]
    private var lastTerminalFetch: [String: Date] = [:]
    private var agentsByHost: [String: [Agent]] = [:]
    /// agent id -> stateStartedAt the user has acknowledged (only matters for `done`).
    private var acknowledged: [String: Double] = [:]
    private var initializedHosts: Set<String> = []
    private var knownAttentionKeys: Set<String> = []
    private var pollTask: Task<Void, Never>?
    private var screenTask: Task<Void, Never>?

    func start() {
        guard pollTask == nil, !isDemo else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: Self.pollInterval)
            }
        }
    }

    func refreshEnvironments() {
        lastEnvironmentFetch = .distantPast
    }

    // MARK: - Polling

    private func pollOnce() async {
        if Date().timeIntervalSince(lastEnvironmentFetch) > 60 {
            lastEnvironmentFetch = Date()
            if let envs = try? await OrcaCLI.environments() {
                environmentNames = envs.map(\.name)
            }
        }

        let targets: [String?] = [nil] + environmentNames.map { Optional($0) }
        let cachedTerminals = terminalsByHost
        let lastFetch = lastTerminalFetch

        let results = await withTaskGroup(of: HostPoll.self) { group -> [HostPoll] in
            for host in targets {
                let key = host ?? "local"
                let cached = cachedTerminals[key] ?? [:]
                let terminalsStale = Date().timeIntervalSince(lastFetch[key] ?? .distantPast) > 15
                group.addTask { await AgentStore.poll(host: host, cachedTerminals: cached, terminalsStale: terminalsStale) }
            }
            var out: [HostPoll] = []
            for await r in group { out.append(r) }
            return out
        }

        var statuses: [HostStatus] = []
        for r in results {
            let key = r.host ?? "local"
            if let terminals = r.terminals {
                terminalsByHost[key] = terminals
                lastTerminalFetch[key] = Date()
            }
            if let agents = r.agents {
                agentsByHost[key] = agents
                statuses.append(HostStatus(name: key, online: true))
            } else {
                agentsByHost[key] = nil
                initializedHosts.remove(key)
                statuses.append(HostStatus(name: key, online: false, error: r.error))
            }
        }
        hosts = statuses.sorted { ($0.name == "local" ? "" : $0.name) < ($1.name == "local" ? "" : $1.name) }
        rebuild()
    }

    private struct HostPoll: Sendable {
        let host: String?
        var agents: [Agent]?
        var terminals: [String: TerminalRow]?
        var error: String?
    }

    nonisolated private static func poll(host: String?, cachedTerminals: [String: TerminalRow], terminalsStale: Bool) async -> HostPoll {
        do {
            let worktrees = try await OrcaCLI.worktrees(environment: host)
            let paneKeys = worktrees.flatMap { $0.agents.map(\.paneKey) }
            var terminals: [String: TerminalRow]?
            if terminalsStale || paneKeys.contains(where: { cachedTerminals[$0] == nil }) {
                if let rows = try? await OrcaCLI.terminals(environment: host) {
                    terminals = Dictionary(rows.map { ($0.paneKey, $0) }, uniquingKeysWith: { a, _ in a })
                }
            }
            let lookup = terminals ?? cachedTerminals
            let agents = worktrees
                .filter { $0.isArchived != true }
                .flatMap { wt in wt.agents.map { Agent(row: $0, worktree: wt, host: host, terminal: lookup[$0.paneKey]) } }
            return HostPoll(host: host, agents: agents, terminals: terminals)
        } catch {
            return HostPoll(host: host, error: error.localizedDescription)
        }
    }

    private func rebuild() {
        let now = Date().timeIntervalSince1970 * 1000
        let orcaFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.orcaBundleID

        var all: [Agent] = []
        for (hostKey, hostAgents) in agentsByHost {
            let firstSight = !initializedHosts.contains(hostKey)
            for var agent in hostAgents {
                if agent.state == .done && now - agent.updatedAt > Self.hideDoneAfter { continue }
                if agent.state == .done {
                    // Don't flood on launch, and treat "you're looking at it in Orca" as seen.
                    let seenInOrca = orcaFrontmost && agent.worktreeIsActive && agent.host == nil
                    let seenHere = isViewing && agent.id == selectedID
                    if firstSight || seenInOrca || seenHere || agent.interrupted {
                        acknowledged[agent.id] = max(acknowledged[agent.id] ?? 0, agent.stateStartedAt)
                    }
                    agent.needsAttention = (acknowledged[agent.id] ?? 0) < agent.stateStartedAt
                } else {
                    agent.needsAttention = agent.state == .blocked || agent.state == .waiting
                }
                all.append(agent)
            }
            if firstSight {
                // Pre-existing blocks show in the badge but don't trigger a peek/sound.
                knownAttentionKeys.formUnion(hostAgents.map(\.attentionKey))
                initializedHosts.insert(hostKey)
            }
        }

        all.sort { a, b in
            if a.needsAttention != b.needsAttention { return a.needsAttention }
            if a.state.rank != b.state.rank { return a.state.rank < b.state.rank }
            return a.updatedAt > b.updatedAt
        }

        let attentionNow = all.filter(\.needsAttention)
        let fresh = attentionNow.filter { !knownAttentionKeys.contains($0.attentionKey) }
        knownAttentionKeys = Set(all.map(\.attentionKey))

        if all != agents { agents = all }
        if selectedID == nil || !all.contains(where: { $0.id == selectedID }) {
            selectedID = all.first?.id
        }
        if let newest = fresh.max(by: { $0.stateStartedAt < $1.stateStartedAt }) {
            onNewAttention?(newest)
        }
    }

    func acknowledgeAllDone() {
        for a in agents where a.state == .done { acknowledged[a.id] = a.stateStartedAt }
        rebuild()
    }

    // MARK: - Terminal

    private func selectionChanged() {
        screenLines = []
        screenStatus = nil
        sendError = nil
        if isViewing, let a = selectedAgent, a.state == .done {
            acknowledged[a.id] = a.stateStartedAt
            rebuild()
        }
        restartScreenLoop()
    }

    private func restartScreenLoop() {
        screenTask?.cancel()
        guard isViewing else { return }
        screenTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshScreen()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func refreshScreen() async {
        guard let agent = selectedAgent else { screenLines = []; return }
        if isDemo {
            let lines = demoScreens[agent.id] ?? []
            if lines != screenLines { screenLines = lines }
            return
        }
        guard let handle = agent.terminalHandle else {
            screenStatus = "No live terminal found for this agent yet."
            return
        }
        do {
            let screen = try await OrcaCLI.screen(handle: handle, environment: agent.host)
            guard agent.id == selectedID else { return }
            var lines = screen.tail.map { String($0.reversed().drop(while: \.isWhitespace).reversed()) }
            while lines.last?.isEmpty == true { lines.removeLast() }
            if lines != screenLines { screenLines = lines }
            screenStatus = screen.status == "running" ? nil : screen.status
        } catch {
            guard agent.id == selectedID else { return }
            screenStatus = error.localizedDescription
        }
    }

    func send(_ text: String, enter: Bool) {
        guard let agent = selectedAgent, let handle = agent.terminalHandle else { return }
        if isDemo { onDemoSend?(agent, text); return }
        sendError = nil
        Task {
            do {
                try await OrcaCLI.send(handle: handle, text: text, enter: enter, environment: agent.host)
                try? await Task.sleep(nanoseconds: 250_000_000)
                await refreshScreen()
            } catch {
                sendError = error.localizedDescription
            }
        }
    }

    func openInOrca(_ agent: Agent) {
        Task {
            if let handle = agent.terminalHandle {
                try? await OrcaCLI.focus(handle: handle, environment: agent.host)
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.orcaBundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
        }
    }

    // MARK: - Demo (mock data, no orca CLI)

    private(set) var isDemo = false
    var demoScreens: [String: [String]] = [:]
    var onDemoSend: ((Agent, String) -> Void)?

    func setDemo(hosts: [HostStatus], agents: [Agent], screens: [String: [String]]) {
        isDemo = true
        self.hosts = hosts
        demoScreens = screens
        agentsByHost = Dictionary(grouping: agents, by: \.hostLabel)
        rebuild()
        Task { await refreshScreen() }
    }
}
