import Foundation
import CryptoKit
import SINotchCore

/// A small, public-content projection of Desktop's local follower stream.
/// Command output, generic arguments, reasoning, permissions and attachments are discarded.
struct CodexDesktopState {
    private(set) var root: [String: Any] = [:]
    private(set) var revision: Int?

    mutating func apply(_ change: [String: Any]) -> Bool {
        guard let next = change["revision"] as? Int else { return false }
        if change["type"] as? String == "snapshot", let state = change["conversationState"] as? [String: Any] {
            root = Self.project(state) as? [String: Any] ?? [:]
            revision = next
            return true
        }
        guard change["type"] as? String == "patches", let revision,
              change["baseRevision"] as? Int == revision, next > revision,
              let patches = change["patches"] as? [[String: Any]], patches.count <= 4096 else { return false }
        var value: Any = root
        for patch in patches {
            guard let path = patch["path"] as? [Any], path.count <= 40,
                  let operation = patch["op"] as? String, ["add", "replace", "remove"].contains(operation) else { return false }
            // Ignored properties never enter the retained state, even through a delta.
            if path.contains(where: { ($0 as? String).map { !Self.fields.contains($0) && !Self.isDynamicKey($0) } ?? false }) { continue }
            if path.last as? String == "command" {
                var parent: Any = root
                for key in path.dropLast() {
                    if let key = key as? String { parent = (parent as? [String: Any])?[key] ?? NSNull() }
                    else if let index = key as? Int, let array = parent as? [Any], array.indices.contains(index) { parent = array[index] }
                    else { parent = NSNull(); break }
                }
                guard (parent as? [String: Any])?["type"] as? String == "commandExecution" else { continue }
            }
            Self.edit(&value, path: ArraySlice(path), operation: operation,
                      replacement: Self.project(patch["value"] ?? NSNull(), field: path.last as? String))
        }
        // Every inserted/replaced value was projected above. Re-projecting the
        // entire retained history for each streaming delta repeats the same work.
        root = value as? [String: Any] ?? [:]
        self.revision = next
        return true
    }

    func event(sessionID: String, now: Date = Date()) -> AgentEvent? {
        guard root["id"] as? String == sessionID else { return nil }
        let history = ((root["turnHistory"] as? [String: Any])?["history"] as? [String: Any])?["entitiesByKey"] as? [String: Any]
        let turns = (history?.values.compactMap { $0 as? [String: Any] } ?? []) + (root["turns"] as? [[String: Any]] ?? [])
        let turn = turns.max { ($0["turnStartedAtMs"] as? Double ?? 0) < ($1["turnStartedAtMs"] as? Double ?? 0) } ?? [:]
        let items = turn["items"] as? [[String: Any]] ?? []
        let historyItems = HistoryContent.bounded(items.enumerated().suffix(64).compactMap { index, item -> AgentHistoryItem? in
            let id = item["id"] as? String ?? "item-\(index)"
            switch item["type"] as? String {
            case "userMessage":
                // Projection already sanitized every retained text block. Do
                // not run all redaction regexes over the turn on each delta.
                let content = item["content"]
                let text = content as? String ?? (content as? [[String: Any]])?.prefix(16).compactMap {
                    ["text", "input_text", "output_text"].contains($0["type"] as? String ?? "") ? $0["text"] as? String : nil
                }.joined(separator: "\n")
                return text.flatMap { $0.isEmpty || Self.replyQuestionIDs($0) != nil ? nil : .init(id: id, role: .user, text: String($0.prefix(HistoryStore.maximumTextCharacters))) }
            case "agentMessage" where item["phase"] as? String != "analysis":
                return (item["text"] as? String).flatMap { $0.isEmpty ? nil : .init(id: id, role: .assistant, text: $0) }
            case "commandExecution":
                return (item["command"] as? String).flatMap { $0.isEmpty ? nil : .init(id: id, role: .command, text: $0) }
            default: return nil
            }
        })
        let runtime = root["threadRuntimeStatus"] as? [String: Any] ?? [:]
        let flags = runtime["activeFlags"] as? [String] ?? []
        let status = turn["status"] as? String
        let terminal = ["completed", "failed", "interrupted", "cancelled"].contains(status ?? "")
        // Runtime flags can lag behind a restored conversation. A concrete
        // turn's outcome wins; loading a thread without a turn is not work.
        let active = status == "inProgress"
        let attention = terminal ? nil : Self.attentionRequest(in: root, turn: turn)
        let kind: AgentEventKind = status == "completed" ? .completed : status == "failed" ? .failed :
            terminal ? .sessionStarted : active && flags.contains("waitingOnApproval") ? .approvalRequested :
            attention != nil || (active && flags.contains("waitingOnUserInput")) ? .waiting :
            active ? .working : .sessionStarted
        let message = items.reversed().first { $0["type"] as? String == "agentMessage" && $0["phase"] as? String != "analysis" }
        let prompt = items.first { $0["type"] as? String == "userMessage" }
        let tool = active ? items.reversed().first { Self.toolName($0) != nil && $0["status"] as? String == "inProgress" } : nil
        let params = turn["params"] as? [String: Any] ?? [:]
        let settings = (params["collaborationMode"] as? [String: Any])?["settings"] as? [String: Any] ?? [:]
        // Desktop may leave the legacy fields null and resolve metadata in the
        // current turn's collaboration mode instead.
        let model = [root["latestModel"], params["model"], settings["model"]]
            .compactMap { SessionSnippet.text($0, limit: 256) }.first
        let effort = [root["latestReasoningEffort"], turn["requestedReasoningEffort"], params["effort"], settings["reasoning_effort"]]
            .compactMap { SessionSnippet.text($0, limit: 128) }.first
        let usage = root["latestTokenUsageInfo"] as? [String: Any] ?? [:]
        let total = usage["total"] as? [String: Any] ?? [:]
        let last = usage["last"] as? [String: Any] ?? [:]
        return AgentEvent(sessionID: sessionID, provider: "codex", kind: kind, timestamp: now,
            id: "desktop-stream:\(sessionID):\(revision ?? 0)", title: SessionSnippet.text(root["title"], limit: 160),
            projectPath: SessionSnippet.text(root["cwd"], limit: 4096), message: SessionSnippet.text(message?["text"]),
            toolName: tool.flatMap(Self.toolName),
            usage: AgentUsage(inputTokens: total["inputTokens"] as? Int, outputTokens: total["outputTokens"] as? Int,
                              contextTokens: last["totalTokens"] as? Int, contextWindow: usage["modelContextWindow"] as? Int),
            targetURL: "codex://threads/\(sessionID)", modelName: model, reasoningEffort: effort ?? "",
            firstPrompt: SessionSnippet.message(prompt?["content"]),
            turnID: (turn["turnId"] as? String ?? turn["id"] as? String).flatMap { UUID(uuidString: $0)?.uuidString.lowercased() },
            isInternalSession: CodexServiceSessionFilter.nativeClassification(source: root["source"], threadSource: root["threadSource"]),
            attentionRequestID: attention,
            isWorkSession: CodexSessionOrigin.isWork(originator: root["originator"], serviceName: root["serviceName"]),
            historyItems: historyItems.isEmpty ? nil : historyItems)
    }

    private static func attentionRequest(in root: [String: Any], turn: [String: Any]) -> String? {
        let methods: Set<String> = ["item/tool/requestUserInput", "item/tool/requestOptionPicker",
            "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
            "item/permissions/requestApproval", "mcpServer/elicitation/request"]
        let turnID = turn["turnId"] as? String ?? turn["id"] as? String
        for request in root["requests"] as? [[String: Any]] ?? [] {
            guard let method = request["method"] as? String, methods.contains(method),
                  request["completed"] as? Bool != true,
                  let id = request["id"], id is String || id is Int else { continue }
            let params = request["params"] as? [String: Any] ?? [:]
            if let requestTurn = params["turnId"] as? String, let turnID, requestTurn != turnID { continue }
            return attentionKey([method, turnID ?? "thread", id])
        }
        guard turn["status"] as? String == "inProgress", let turnID else { return nil }
        let items = turn["items"] as? [[String: Any]] ?? []
        let answered = Set(items.flatMap { item -> [String] in
            let type = item["type"] as? String
            guard type == "userMessage" || (type == "steeringUserMessage" && item["status"] as? String == "accepted"),
                  let content = item[type == "userMessage" ? "content" : "input"] as? [[String: Any]],
                  content.count == 1, content[0]["type"] as? String == "text",
                  let text = content[0]["text"] as? String else { return [] }
            return Self.replyQuestionIDs(text) ?? []
        })
        for item in items where item["type"] as? String == "agentMessage" {
            guard let messageID = item["id"] as? String, let questions = item["questions"] as? [Any] else { continue }
            for index in questions.indices {
                guard let data = try? JSONSerialization.data(withJSONObject: ["request_user_input_async", messageID, index], options: [.withoutEscapingSlashes]),
                      let questionID = String(data: data, encoding: .utf8), !answered.contains(questionID) else { continue }
                return attentionKey(["async", turnID, messageID, index])
            }
        }
        return nil
    }

    private static func attentionKey(_ parts: [Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: parts) else { return nil }
        return "codex-request:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func replyQuestionIDs(_ text: String) -> [String]? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = "<send_user_message_question_reply>", end = "</send_user_message_question_reply>"
        guard value.hasPrefix(start), value.hasSuffix(end), value.utf8.count <= AgentEvent.maximumPayloadBytes,
              let data = String(value.dropFirst(start.count).dropLast(end.count)).data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let replies = (decoded as? [[String: Any]]) ?? (decoded as? [String: Any]).map { [$0] } ?? []
        guard !replies.isEmpty, replies.count <= 256,
              replies.allSatisfy({ $0["questionItemId"] is String && $0["question"] is String && $0["answer"] is String }) else { return nil }
        return replies.compactMap { $0["questionItemId"] as? String }
    }

    private static func toolName(_ item: [String: Any]) -> String? {
        switch item["type"] as? String {
        case "commandExecution": return "terminal"
        case "fileChange": return "apply_patch"
        case "webSearch": return "web_search"
        case "imageGeneration": return "image_generation"
        case "mcpToolCall": return SessionSnippet.text(item["tool"], limit: 100)
        default: return nil
        }
    }

    // Dynamic turn keys are UUIDs or the observed canonical-history prefixes.
    private static func isDynamicKey(_ key: String) -> Bool {
        key.count <= 160 && (key.hasPrefix("turn:") || key.hasPrefix("tail:") || UUID(uuidString: key) != nil)
    }
    private static let fields: Set<String> = ["id", "title", "cwd", "latestModel", "latestReasoningEffort", "source", "threadSource", "originator", "serviceName",
        "threadRuntimeStatus", "activeFlags", "type", "turnHistory", "kind", "history", "entitiesByKey", "turns",
        "turnId", "turnStartedAtMs", "status", "params", "model", "effort", "requestedReasoningEffort", "collaborationMode", "settings", "reasoning_effort", "items", "phase", "text", "content", "input", "questions",
        "tool", "command", "requests", "method", "completed", "threadId", "latestTokenUsageInfo", "total", "last", "inputTokens", "outputTokens", "totalTokens", "modelContextWindow"]

    private static func project(_ value: Any, depth: Int = 0, field: String? = nil) -> Any {
        guard depth < 40 else { return NSNull() }
        if let object = value as? [String: Any] {
            if object["type"] as? String == "reasoning" { return ["type": "reasoning"] }
            var result: [String: Any] = [:]
            for (key, child) in object where fields.contains(key) || isDynamicKey(key) {
                if key == "command", object["type"] as? String != "commandExecution" { continue }
                if key == "questions", let questions = child as? [Any] {
                    result[key] = questions.prefix(256).map { _ in [String: String]() }
                } else if key == "source", let source = child as? [String: Any] {
                    // Retain only the source variant, never agent ancestry or
                    // arbitrary custom-source text.
                    result[key] = source.filter { ["internal", "subagent", "custom"].contains($0.key) }
                        .mapValues { _ in true }
                } else { result[key] = project(child, depth: depth + 1, field: key) }
            }
            return result
        }
        if let array = value as? [Any] { return array.prefix(20_000).map { project($0, depth: depth + 1) } }
        if let string = value as? String {
            // Preserve reply identities before snippet truncation, discarding
            // the question and answer bodies from this protocol-only marker.
            if let ids = replyQuestionIDs(string),
               let data = try? JSONSerialization.data(withJSONObject: ids.map { ["questionItemId": $0, "question": "", "answer": ""] }),
               let marker = String(data: data, encoding: .utf8) {
                return "<send_user_message_question_reply>\(marker)</send_user_message_question_reply>"
            }
            return SessionSnippet.text(string, limit: ["text", "content", "command"].contains(field ?? "") ? HistoryStore.maximumTextCharacters : 1600) ?? ""
        }
        return value
    }

    static func edit(_ value: inout Any, path: ArraySlice<Any>, operation: String, replacement: Any) {
        guard let key = path.first else { value = replacement; return }
        let tail = path.dropFirst()
        if let key = key as? String, var object = value as? [String: Any] {
            if tail.isEmpty {
                if operation == "remove" { object.removeValue(forKey: key) } else { object[key] = replacement }
            } else if var child = object[key] {
                edit(&child, path: tail, operation: operation, replacement: replacement); object[key] = child
            }
            value = object
        } else if let index = key as? Int, var array = value as? [Any], index >= 0, index <= array.count, array.count <= 20_000 {
            if tail.isEmpty {
                if operation == "add", array.count < 20_000 { array.insert(replacement, at: index) }
                else if index < array.count {
                    if operation == "remove" { array.remove(at: index) } else { array[index] = replacement }
                }
            } else if index < array.count { edit(&array[index], path: tail, operation: operation, replacement: replacement) }
            value = array
        }
    }
}
