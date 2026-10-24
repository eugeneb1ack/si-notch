import Foundation

public enum AgentEventError: Error, Equatable, LocalizedError, Sendable {
    case payloadTooLarge
    case missingSessionID
    case invalidIdentifier(String)
    case invalidProvider
    case invalidTimestamp
    case invalidSequence
    case invalidUsage
    case invalidField(String)

    public var errorDescription: String? {
        switch self {
        case .payloadTooLarge: return "Event exceeds the 256 KiB limit."
        case .missingSessionID: return "Event needs a session_id or thread-id."
        case .invalidIdentifier(let field): return "Invalid identifier in \(field)."
        case .invalidProvider: return "Provider must be a short identifier."
        case .invalidTimestamp: return "Timestamp must be finite Unix seconds or ISO 8601."
        case .invalidSequence: return "Sequence must be a non-negative integer."
        case .invalidUsage: return "Usage values must be finite and non-negative; percentages must be 0–100."
        case .invalidField(let field): return "Invalid value in \(field)."
        }
    }
}

/// Transport-independent event envelope with adapters for documented hook payloads.
public struct AgentEvent: Codable, Equatable, Sendable {
    public static let maximumPayloadBytes = 256 * 1_024

    public var sessionID: String
    public var provider: String
    public var connectionID: String?
    public var connectionName: String?
    public var kind: AgentEventKind
    public var timestamp: Date
    public var id: String?
    public var sequence: Int?
    public var title: String?
    public var projectPath: String?
    public var message: String?
    public var toolName: String?
    public var task: AgentTask?
    public var subagent: AgentSubagent?
    public var usage: AgentUsage?
    public var terminalBundleID: String?
    public var targetURL: String?
    public var approvalID: String?
    public var modelName: String?
    public var reasoningEffort: String?
    public var firstPrompt: String?
    /// Hermes session.end with a turn ID closes that execution; without it,
    /// the event finalizes the durable session until another session.start.
    public var turnID: String?
    /// Native Codex source classification; nil means this observer has no metadata.
    public var isInternalSession: Bool?
    /// Native local Work identity; absent hook metadata preserves the known product.
    public var isWorkSession: Bool?
    /// Identity of an observed, unresolved human-input request; not a runtime wait flag.
    public var attentionRequestID: String?
    public var historyItems: [AgentHistoryItem]?

    public init(sessionID: String, provider: String = "custom", kind: AgentEventKind,
                timestamp: Date = Date(), id: String? = nil, sequence: Int? = nil,
                title: String? = nil, projectPath: String? = nil, message: String? = nil,
                toolName: String? = nil, task: AgentTask? = nil, subagent: AgentSubagent? = nil,
                usage: AgentUsage? = nil, terminalBundleID: String? = nil,
                targetURL: String? = nil, approvalID: String? = nil,
                modelName: String? = nil, reasoningEffort: String? = nil, firstPrompt: String? = nil,
                turnID: String? = nil, isInternalSession: Bool? = nil, attentionRequestID: String? = nil,
                connectionID: String? = nil, connectionName: String? = nil, isWorkSession: Bool? = nil,
                historyItems: [AgentHistoryItem]? = nil) {
        self.sessionID = sessionID
        self.provider = provider
        self.connectionID = connectionID
        self.connectionName = connectionName
        self.kind = kind
        self.timestamp = timestamp
        self.id = id
        self.sequence = sequence
        self.title = title
        self.projectPath = projectPath
        self.message = message
        self.toolName = toolName
        self.task = task
        self.subagent = subagent
        self.usage = usage
        self.terminalBundleID = terminalBundleID
        self.targetURL = targetURL
        self.approvalID = approvalID
        self.modelName = modelName
        self.reasoningEffort = reasoningEffort
        self.firstPrompt = firstPrompt
        self.turnID = turnID
        self.isInternalSession = isInternalSession
        self.isWorkSession = isWorkSession
        self.attentionRequestID = attentionRequestID
        self.historyItems = historyItems
    }

    public static func parse(data: Data, receivedAt: Date = Date()) throws -> AgentEvent {
        guard data.count <= maximumPayloadBytes else { throw AgentEventError.payloadTooLarge }
        let decoder = JSONDecoder()
        decoder.userInfo[.eventReceivedAt] = receivedAt
        return try decoder.decode(AgentEvent.self, from: data)
    }

    public func validate() throws {
        try Self.validateID(sessionID, field: "session_id")
        if let id { try Self.validateID(id, field: "id", maximum: 512) }
        guard Self.isIdentifier(provider, maximum: 64) else { throw AgentEventError.invalidProvider }
        if let connectionID { try Self.validateID(connectionID, field: "connection_id") }
        if connectionName != nil && connectionID == nil { throw AgentEventError.invalidField("connection_id") }
        if kind == .agentPresence && connectionID == nil { throw AgentEventError.invalidField("connection_id") }
        guard timestamp.timeIntervalSince1970.isFinite else { throw AgentEventError.invalidTimestamp }
        if let sequence, sequence < 0 { throw AgentEventError.invalidSequence }
        if let task {
            try Self.validateID(task.id, field: "task.id")
            try Self.validateText(task.title, field: "task.title", maximum: 512)
        }
        if let subagent {
            try Self.validateID(subagent.id, field: "subagent.id")
            try Self.validateText(subagent.name, field: "subagent.name", maximum: 512)
            if let id = subagent.parentTurnID { try Self.validateID(id, field: "subagent.parentTurnID") }
            if let id = subagent.sessionID { try Self.validateID(id, field: "subagent.sessionID") }
        }
        if let approvalID { try Self.validateID(approvalID, field: "approval_id") }
        if let turnID { try Self.validateID(turnID, field: "turn_id") }
        if let attentionRequestID { try Self.validateID(attentionRequestID, field: "attention_request_id", maximum: 512) }
        if let historyItems {
            guard historyItems.count <= 64, historyItems.reduce(0, { $0 + $1.text.utf8.count }) <= 128 * 1024 else {
                throw AgentEventError.invalidField("history_items")
            }
            for item in historyItems {
                try Self.validateID(item.id, field: "history_items.id", maximum: 512)
                try Self.validateText(item.text, field: "history_items.text", maximum: 16384)
            }
        }
        for (value, name, maximum) in [(connectionName, "connection_name", 512), (title, "title", 512), (projectPath, "cwd", 4096),
                                       (message, "message", 16384), (toolName, "tool_name", 512),
                                       (terminalBundleID, "terminal_bundle_id", 256), (targetURL, "target_url", 4096),
                                       (modelName, "model", 256), (reasoningEffort, "reasoning_effort", 128), (firstPrompt, "first_prompt", 16384)] {
            if let value { try Self.validateText(value, field: name, maximum: maximum) }
        }
        if let usage {
            if let id = usage.requestID { try Self.validateID(id, field: "usage.request_id", maximum: 512) }
            if let id = usage.parentSessionID { try Self.validateID(id, field: "usage.parent_session_id") }
            if let id = usage.parentTurnID { try Self.validateID(id, field: "usage.parent_turn_id") }
            if let kind = usage.callKind { try Self.validateID(kind, field: "usage.call_kind", maximum: 64) }
            guard [usage.startedAt, usage.endedAt].allSatisfy({ $0.map { $0.isFinite && $0 >= 0 } ?? true }) else { throw AgentEventError.invalidUsage }
            let counts = [usage.inputTokens, usage.outputTokens, usage.contextTokens, usage.contextWindow,
                          usage.cachedInputTokens, usage.cacheWriteInputTokens, usage.reasoningOutputTokens]
            guard counts.allSatisfy({ $0 == nil || $0! >= 0 }),
                  usage.costUSD.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  [usage.primaryUsedPercent, usage.secondaryUsedPercent].allSatisfy({
                      $0.map { $0.isFinite && (0...100).contains($0) } ?? true
                  }) else { throw AgentEventError.invalidUsage }
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
        let hook = try raw.string("hook_event_name")
        let eventName = try raw.string("event", "kind", "type") ?? "unknown"
        let isCodex = raw["thread-id"] != nil || eventName.hasPrefix("agent-turn-")
        guard let sessionID = try raw.string("session_id", "sessionID", "thread-id", "thread_id") else {
            throw AgentEventError.missingSessionID
        }
        self.sessionID = sessionID
        provider = try raw.string("provider", "agent") ?? (hook != nil ? "claude" : isCodex ? "codex" : "custom")
        connectionID = try raw.string("connection_id")
        connectionName = try raw.string("connection_name")
        kind = Self.normalize(hook ?? eventName)
        if hook == "Notification" {
            let type = try raw.string("notification_type")
            kind = type == "permission_prompt" || type == "elicitation_dialog" ? .approvalRequested : .waiting
        }
        timestamp = try raw.date("timestamp", "occurred_at") ?? (decoder.userInfo[.eventReceivedAt] as? Date ?? Date())
        id = try raw.string("id", "event_id", "event-id")
        sequence = try raw.integer("sequence", "seq")
        title = try raw.string("title", "session_title")
        projectPath = try raw.string("cwd", "project_path", "projectPath")
        message = try raw.string("message", "last-assistant-message", "last_assistant_message", "prompt", "error")
        toolName = try raw.string("tool_name", "toolName")
        terminalBundleID = try raw.string("terminal_bundle_id", "terminalBundleID")
        targetURL = try raw.string("target_url", "targetURL")
        approvalID = try raw.string("approval_id", "request_id", "tool_use_id")
        modelName = try raw.string("model", "model_name")
        reasoningEffort = try raw.string("reasoning_effort")
        firstPrompt = try raw.string("first_prompt")
        turnID = try raw.string("turn_id", "turn-id", "turnID", "turnId")
        isInternalSession = try raw.decode(Bool.self, key: "is_internal_session")
        isWorkSession = try raw.decode(Bool.self, key: "is_work_session")
        attentionRequestID = try raw.string("attention_request_id")
        historyItems = try raw.decode([AgentHistoryItem].self, key: "history_items")
        task = try raw.decode(AgentTask.self, key: "task")
        subagent = try raw.decode(AgentSubagent.self, key: "subagent")
        usage = try raw.decode(AgentUsage.self, key: "usage")
        if task == nil, kind == .taskUpdated, let taskID = try raw.string("task_id") {
            task = AgentTask(id: taskID, title: try raw.string("task_subject", "task_description") ?? "Task", status: .completed)
        }
        if subagent == nil, kind == .subagentStarted || kind == .subagentEnded,
           let agentID = try raw.string("agent_id", "subagent_id") {
            subagent = AgentSubagent(id: agentID, name: try raw.string("agent_type", "subagent_type") ?? "Subagent",
                                     status: kind == .subagentEnded ? .completed : .working)
        }
        if id == nil, let turnID, isCodex {
            id = "codex:\(sessionID):\(turnID):\(kind.rawValue)"
        } else if id == nil, let toolID = try raw.string("tool_use_id"),
                  [.toolStarted, .toolFinished, .toolFailed].contains(kind) {
            id = "\(kind.rawValue):\(toolID)"
        }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var raw: [String: JSONValue] = ["session_id": .string(sessionID), "provider": .string(provider),
                                      "event": .string(kind.rawValue), "timestamp": .number(timestamp.timeIntervalSince1970)]
        let strings = [("connection_id", connectionID), ("connection_name", connectionName),
                       ("id", id), ("title", title), ("cwd", projectPath), ("message", message),
                       ("tool_name", toolName), ("terminal_bundle_id", terminalBundleID),
                       ("target_url", targetURL), ("approval_id", approvalID),
                       ("model", modelName), ("reasoning_effort", reasoningEffort), ("first_prompt", firstPrompt), ("turn_id", turnID)]
        for (key, value) in strings { if let value { raw[key] = .string(value) } }
        if let sequence { raw["sequence"] = .number(Double(sequence)) }
        if let isInternalSession { raw["is_internal_session"] = .bool(isInternalSession) }
        if let isWorkSession { raw["is_work_session"] = .bool(isWorkSession) }
        if let attentionRequestID { raw["attention_request_id"] = .string(attentionRequestID) }
        if let historyItems { raw["history_items"] = try JSONValue.wrapping(historyItems) }
        if let task { raw["task"] = try JSONValue.wrapping(task) }
        if let subagent { raw["subagent"] = try JSONValue.wrapping(subagent) }
        if let usage { raw["usage"] = try JSONValue.wrapping(usage) }
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    private static func normalize(_ name: String) -> AgentEventKind {
        switch name.lowercased().filter({ $0.isLetter || $0.isNumber }) {
        case "agentpresence": return .agentPresence
        case "sessionstart", "sessionstarted", "start": return .sessionStarted
        case "agentworking", "working", "userpromptsubmit", "agentturnstart", "precompact", "postcompact": return .working
        case "toolstart", "toolstarted", "pretooluse": return .toolStarted
        case "toolfinish", "toolfinished", "posttooluse": return .toolFinished
        case "toolfailed", "posttoolusefailure": return .toolFailed
        case "agentwaiting", "waiting", "teammateidle": return .waiting
        case "approvalrequest", "approvalrequested", "permissionrequest", "approval": return .approvalRequested
        case "agentcompleted", "completed", "stop", "agentturncomplete": return .completed
        case "agentfailed", "failed", "error", "stopfailure": return .failed
        case "sessionend", "sessionended", "ended": return .sessionEnded
        case "taskupdate", "taskupdated", "taskcompleted": return .taskUpdated
        case "subagentstart", "subagentstarted": return .subagentStarted
        case "subagentend", "subagentended", "subagentstop": return .subagentEnded
        case "usageupdate", "usageupdated": return .usageUpdated
        default: return .unknown
        }
    }

    private static func validateID(_ value: String, field: String, maximum: Int = 256) throws {
        guard isIdentifier(value, maximum: maximum) else { throw AgentEventError.invalidIdentifier(field) }
    }

    private static func isIdentifier(_ value: String, maximum: Int) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maximum, let first = bytes.first,
              (48...57).contains(first) || (65...90).contains(first) || (97...122).contains(first) else { return false }
        return bytes.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95, 58].contains($0) }
    }

    private static func validateText(_ value: String, field: String, maximum: Int) throws {
        guard value.utf8.count <= maximum, !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw AgentEventError.invalidField(field)
        }
    }
}

private extension CodingUserInfoKey {
    static let eventReceivedAt = CodingUserInfoKey(rawValue: "si-notch.eventReceivedAt")!
}

private indirect enum JSONValue: Codable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let object = try? value.decode([String: JSONValue].self) { self = .object(object) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }

    static func wrapping<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func string(_ keys: String...) throws -> String? {
        for key in keys {
            guard let value = self[key] else { continue }
            if case .null = value { continue }
            guard case .string(let string) = value else { throw AgentEventError.invalidField(key) }
            return string
        }
        return nil
    }

    func integer(_ keys: String...) throws -> Int? {
        for key in keys {
            guard let value = self[key] else { continue }
            if case .null = value { continue }
            guard case .number(let number) = value, number.isFinite, number.rounded() == number,
                  number >= 0, number < Double(Int.max) else { throw AgentEventError.invalidSequence }
            return Int(number)
        }
        return nil
    }

    func date(_ keys: String...) throws -> Date? {
        for key in keys {
            guard let value = self[key] else { continue }
            switch value {
            case .null: continue
            case .number(let number):
                guard number.isFinite, abs(number) <= 253_402_300_799 else { throw AgentEventError.invalidTimestamp }
                return Date(timeIntervalSince1970: number)
            case .string(let text):
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: text) { return date }
                formatter.formatOptions = [.withInternetDateTime]
                guard let date = formatter.date(from: text) else { throw AgentEventError.invalidTimestamp }
                return date
            default: throw AgentEventError.invalidTimestamp
            }
        }
        return nil
    }

    func decode<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        guard let value = self[key] else { return nil }
        if case .null = value { return nil }
        return try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }
}
