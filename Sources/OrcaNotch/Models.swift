import Foundation

// MARK: - Wire types (orca CLI --json)

struct Envelope<T: Decodable>: Decodable {
    let ok: Bool
    let result: T?
    let error: ErrorInfo?

    struct ErrorInfo: Decodable {
        let message: String?
    }
}

struct EnvironmentList: Decodable { let environments: [OrcaEnvironment] }
struct OrcaEnvironment: Decodable { let id: String; let name: String }

struct WorktreePS: Decodable { let worktrees: [Worktree] }

struct Worktree: Decodable {
    let worktreeId: String
    let repo: String
    let path: String
    let branch: String?
    let displayName: String?
    let isArchived: Bool?
    let isActive: Bool?
    let agents: [AgentRow]
}

struct AgentRow: Decodable {
    let paneKey: String
    let state: String
    let agentType: String?
    let prompt: String?
    let taskTitle: String?
    let displayName: String?
    let lastAssistantMessage: String?
    let toolName: String?
    let toolInput: String?
    let interactivePrompt: String?
    let interrupted: Bool?
    let stateStartedAt: Double?
    let updatedAt: Double?

    enum CodingKeys: String, CodingKey {
        case paneKey, state, agentType, prompt, taskTitle, displayName, lastAssistantMessage
        case toolName, toolInput, interactivePrompt, interrupted, stateStartedAt, updatedAt
    }

    // Why: the status payload is provider-shaped; tolerate objects where we expect strings
    // so one odd agent never blanks the whole list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paneKey = try c.decode(String.self, forKey: .paneKey)
        state = (try? c.decode(String.self, forKey: .state)) ?? "working"
        func text(_ key: CodingKeys) -> String? {
            (try? c.decodeIfPresent(JSONValue.self, forKey: key))??.text
        }
        agentType = text(.agentType)
        prompt = text(.prompt)
        taskTitle = text(.taskTitle)
        displayName = text(.displayName)
        lastAssistantMessage = text(.lastAssistantMessage)
        toolName = text(.toolName)
        toolInput = text(.toolInput)
        interactivePrompt = text(.interactivePrompt)
        interrupted = try? c.decodeIfPresent(Bool.self, forKey: .interrupted)
        stateStartedAt = try? c.decodeIfPresent(Double.self, forKey: .stateStartedAt)
        updatedAt = try? c.decodeIfPresent(Double.self, forKey: .updatedAt)
    }
}

struct TerminalList: Decodable { let terminals: [TerminalRow] }

struct TerminalRow: Decodable {
    let handle: String
    let tabId: String
    let leafId: String
    let title: String?

    /// Orca's agent `paneKey` is `${tabId}:${leafId}` (see stable-pane-id.js in Orca).
    var paneKey: String { "\(tabId):\(leafId)" }
}

struct TerminalRead: Decodable { let terminal: TerminalScreen }

struct TerminalScreen: Decodable {
    let handle: String
    let status: String?
    let tail: [String]
}

/// Minimal "any JSON" so we can decode loosely-typed fields and ignore results we don't need.
enum JSONValue: Decodable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    var text: String? {
        switch self {
        case .string(let s): return s.isEmpty ? nil : s
        case .number(let n): return String(n)
        case .bool(let b): return String(b)
        case .null: return nil
        case .array(let a): return a.compactMap(\.text).joined(separator: " ")
        case .object(let o):
            for key in ["question", "message", "command", "text", "title"] {
                if let t = o[key]?.text { return t }
            }
            return o.values.compactMap(\.text).first
        }
    }
}

// MARK: - View model

enum AgentState: String {
    case working, blocked, waiting, done

    var rank: Int {
        switch self {
        case .blocked: return 0
        case .waiting: return 1
        case .done: return 2
        case .working: return 3
        }
    }
}

struct Agent: Identifiable, Equatable {
    /// nil = local Orca runtime; otherwise the paired environment name (e.g. "personal/devl").
    let host: String?
    let paneKey: String
    let state: AgentState
    let agentType: String
    let repo: String
    let branch: String
    let worktreeIsActive: Bool
    let title: String
    let detail: String
    let prompt: String?
    let reply: String?
    let toolName: String?
    let toolInput: String?
    let question: String?
    let interrupted: Bool
    let stateStartedAt: Double
    let updatedAt: Double
    var terminalHandle: String?
    var needsAttention = false

    var id: String { "\(hostLabel)|\(paneKey)" }
    var hostLabel: String { host ?? "local" }
    var attentionKey: String { "\(id)@\(state.rawValue)@\(stateStartedAt)" }
    var location: String { "\(repo) · \(branch)" }

    var headline: String {
        switch state {
        case .blocked: return "Needs permission"
        case .waiting: return "Waiting for you"
        case .done: return interrupted ? "Interrupted" : "Finished"
        case .working: return "Working"
        }
    }
}

extension Agent {
    init(row: AgentRow, worktree: Worktree, host: String?, terminal: TerminalRow?) {
        let state = AgentState(rawValue: row.state) ?? .working
        self.host = host
        paneKey = row.paneKey
        self.state = state
        agentType = row.agentType ?? "agent"
        repo = worktree.repo
        let rawBranch = worktree.branch.map { $0.replacingOccurrences(of: "refs/heads/", with: "") }
        branch = rawBranch ?? worktree.displayName ?? ""
        worktreeIsActive = worktree.isActive ?? false
        interrupted = row.interrupted ?? false
        stateStartedAt = row.stateStartedAt ?? row.updatedAt ?? 0
        updatedAt = row.updatedAt ?? stateStartedAt
        terminalHandle = terminal?.handle
        prompt = row.prompt
        reply = row.lastAssistantMessage
        toolName = row.toolName
        toolInput = row.toolInput
        question = row.interactivePrompt

        let terminalTitle = terminal?.title.map(Agent.stripSpinner).flatMap { $0.isEmpty ? nil : $0 }
        title = [row.taskTitle, row.displayName, terminalTitle, row.prompt.map(Agent.firstLine)]
            .compactMap { $0 }
            .first { !$0.isEmpty && !$0.hasPrefix("Terminal ") } ?? "\(agentType) in \(worktree.repo)"

        switch state {
        case .blocked:
            let tool = [row.toolName, row.toolInput].compactMap { $0 }.joined(separator: ": ")
            detail = row.interactivePrompt ?? (tool.isEmpty ? "Waiting for approval" : tool)
        case .waiting:
            detail = row.interactivePrompt ?? row.lastAssistantMessage.map(Agent.firstLine) ?? "Waiting for input"
        case .working:
            detail = row.toolName.map { "Running \($0)" } ?? row.prompt.map(Agent.firstLine) ?? "Working…"
        case .done:
            detail = row.lastAssistantMessage.map(Agent.firstLine) ?? "Done"
        }
    }

    static func firstLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? s
    }

    /// Claude Code and friends prefix tab titles with spinner glyphs (✳ ⠂ ⠐ …).
    static func stripSpinner(_ s: String) -> String {
        var t = Substring(s)
        while let c = t.first, !(c.isLetter || c.isNumber || c == "[" || c == "(") { t = t.dropFirst() }
        return t.trimmingCharacters(in: .whitespaces)
    }
}
