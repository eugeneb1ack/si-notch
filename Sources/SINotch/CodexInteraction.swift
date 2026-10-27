import Foundation
import CryptoKit
import CoreFoundation

/// Ephemeral request content. Never passed to the session/history/usage stores.
struct CodexInteraction: Identifiable, Equatable {
    typealias Question = AgentInteraction.Question
    struct Action: Identifiable, Equatable {
        let id: String
        let label: String
        let decision: Data
        let destructive: Bool
    }
    let id: String
    let sessionID: String
    let turnID: String
    let method: String
    let requestID: Data?
    let detail: String
    let questions: [Question]
    let actions: [Action]
    let cwd: String
    var expiresAt: TimeInterval = 0
    var isApproval: Bool { questions.isEmpty }

    func response(action: String?, answers: [String: String]) -> (method: String, params: [String: Any])? {
        var params: [String: Any] = ["conversationId": sessionID]
        if let requestID, let value = try? JSONSerialization.jsonObject(with: requestID, options: .fragmentsAllowed) {
            params["requestId"] = value
        }
        if isApproval {
            guard let choice = actions.first(where: { $0.id == action }),
                  let value = try? JSONSerialization.jsonObject(with: choice.decision, options: .fragmentsAllowed) else { return nil }
            params["decision"] = value
            return (method, params)
        }
        guard Set(answers.keys) == Set(questions.map(\.id)), questions.allSatisfy({
            guard let answer = answers[$0.id] else { return false }
            return !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && answer.utf8.count <= 12000
        }) else { return nil }
        if method == "thread-follower-submit-user-input" {
            params["response"] = ["answers": answers.mapValues { ["answers": [$0]] }]
        } else {
            let replies = questions.map { ["questionItemId": $0.id, "question": $0.title, "answer": answers[$0.id]!] }
            guard let data = try? JSONSerialization.data(withJSONObject: replies, options: [.withoutEscapingSlashes]),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            let text = "<send_user_message_question_reply>\n\(json)\n</send_user_message_question_reply>"
            let messageID = UUID().uuidString
            let context: [String: Any] = ["prompt": text, "turnTrigger": "send_user_message_async_question",
                "addedFiles": [], "fileAttachments": [], "imageAttachments": [], "ideContext": NSNull()]
            params["input"] = [["type": "text", "text": text, "text_elements": []]]
            params["clientUserMessageId"] = messageID
            params["attachments"] = []
            params["restoreMessage"] = ["id": messageID, "text": text, "context": context, "cwd": cwd,
                "createdAt": Date().timeIntervalSince1970 * 1000, "responsesapiClientMetadata": ["source": "codex"]]
        }
        return (method, params)
    }
}

/// A second, narrowly projected stream view for interactive content. Keeping this
/// separate prevents commands awaiting consent and answers from entering history.
struct CodexInteractionState {
    private(set) var root: [String: Any] = [:]
    private var revision: Int?
    private static let fields: Set<String> = ["id", "cwd", "turns", "turnHistory", "history", "entitiesByKey",
        "turnId", "turnStartedAtMs", "status", "type", "phase", "items", "content", "input", "text", "requests", "questions", "changes"]

    @discardableResult mutating func apply(_ change: [String: Any]) -> Bool {
        guard let next = change["revision"] as? Int else { return false }
        if change["type"] as? String == "snapshot", let state = change["conversationState"] as? [String: Any] {
            root = Self.project(state, path: []) as? [String: Any] ?? [:]
        } else {
            guard change["type"] as? String == "patches", let revision,
                  change["baseRevision"] as? Int == revision, next > revision,
                  let patches = change["patches"] as? [[String: Any]], patches.count <= 4096 else { return false }
            var value: Any = root
            for patch in patches {
                guard let path = patch["path"] as? [Any], path.count <= 40,
                      let operation = patch["op"] as? String, ["add", "replace", "remove"].contains(operation) else { return false }
                // Request objects and question bodies have their own byte bounds.
                if !path.contains(where: { ["requests", "questions", "changes"].contains($0 as? String ?? "") }),
                   path.contains(where: { ($0 as? String).map { !Self.fields.contains($0) && !$0.hasPrefix("turn:") && !$0.hasPrefix("tail:") && UUID(uuidString: $0) == nil } ?? false }) { continue }
                CodexDesktopState.edit(&value, path: ArraySlice(path), operation: operation,
                    replacement: Self.project(patch["value"] ?? NSNull(), path: path))
            }
            root = value as? [String: Any] ?? [:]
        }
        revision = next
        return true
    }

    func confirmsAsyncAnswer(_ request: CodexInteraction) -> Bool {
        let history = ((root["turnHistory"] as? [String: Any])?["history"] as? [String: Any])?["entitiesByKey"] as? [String: Any]
        let turns = (history?.values.compactMap { $0 as? [String: Any] } ?? []) + (root["turns"] as? [[String: Any]] ?? [])
        guard let turn = turns.first(where: { ($0["turnId"] as? String ?? $0["id"] as? String) == request.turnID }) else { return false }
        let answered = Self.answeredIDs(turn["items"] as? [[String: Any]] ?? [])
        return Set(request.questions.map(\.id)).isSubset(of: answered)
    }

    private static func answeredIDs(_ items: [[String: Any]]) -> Set<String> {
        Set(items.flatMap { item -> [String] in
            guard item["type"] as? String == "userMessage" || (item["type"] as? String == "steeringUserMessage" && item["status"] as? String == "accepted") else { return [] }
            let blocks = (item["content"] ?? item["input"]) as? [[String: Any]] ?? []
            return blocks.flatMap { CodexDesktopState.replyQuestionIDs($0["text"] as? String ?? "") ?? [] }
        })
    }

    func requests(sessionID: String) -> [CodexInteraction] {
        guard root["id"] as? String == sessionID else { return [] }
        let history = ((root["turnHistory"] as? [String: Any])?["history"] as? [String: Any])?["entitiesByKey"] as? [String: Any]
        let turns = (history?.values.compactMap { $0 as? [String: Any] } ?? []) + (root["turns"] as? [[String: Any]] ?? [])
        guard let turn = turns.max(by: { ($0["turnStartedAtMs"] as? Double ?? 0) < ($1["turnStartedAtMs"] as? Double ?? 0) }),
              turn["status"] as? String == "inProgress", let turnID = turn["turnId"] as? String ?? turn["id"] as? String else { return [] }
        let cwd = root["cwd"] as? String ?? ""
        let items = turn["items"] as? [[String: Any]] ?? []
        var result: [CodexInteraction] = []
        for raw in root["requests"] as? [[String: Any]] ?? [] {
            guard raw["completed"] as? Bool != true, let method = raw["method"] as? String,
                  let rid = raw["id"], rid is String || (rid as? NSNumber).map({ CFGetTypeID($0) != CFBooleanGetTypeID() }) == true,
                  let params = raw["params"] as? [String: Any], params["threadId"] as? String == sessionID,
                  params["turnId"] as? String == turnID, let encoded = Self.json(rid), Self.json(raw)?.count ?? .max <= 48000 else { continue }
            var questions: [CodexInteraction.Question] = [], actions: [CodexInteraction.Action] = []
            let route: String
            var preview: [String: Any] = params
            switch method {
            case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
                route = method.contains("commandExecution") ? "thread-follower-command-approval-decision" : "thread-follower-file-approval-decision"
                if method.contains("fileChange") {
                    guard let itemID = params["itemId"] as? String,
                          let changes = items.first(where: { $0["id"] as? String == itemID && $0["type"] as? String == "fileChange" })?["changes"],
                          Self.json(changes)?.count ?? .max <= 24000 else { continue }
                    preview["changes"] = changes
                } else if params["command"] == nil && params["networkApprovalContext"] == nil { continue }
                let decisions = params["availableDecisions"] as? [Any] ?? ["accept", "decline"]
                for decision in decisions {
                    let label: String, destructive: Bool
                    switch decision as? String {
                    case "accept": label = "interaction.allowOnce"; destructive = false
                    case "acceptForSession": label = "interaction.allowSession"; destructive = false
                    case "decline": label = "interaction.deny"; destructive = true
                    case "cancel": label = "interaction.cancel"; destructive = true
                    default:
                        guard method.contains("commandExecution"), let object = decision as? [String: Any], object.count == 1,
                              let amendment = object["acceptWithExecpolicyAmendment"] as? [String: Any], amendment.count == 1,
                              let rule = amendment["execpolicy_amendment"] as? [String], !rule.isEmpty,
                              rule == params["proposedExecpolicyAmendment"] as? [String] else { continue }
                        label = "interaction.allowRule"; destructive = false
                    }
                    guard let data = Self.json(decision) else { continue }
                    actions.append(.init(id: Self.hash(data), label: label, decision: data, destructive: destructive))
                }
                guard !actions.isEmpty else { continue }
            case "item/tool/requestUserInput":
                route = "thread-follower-submit-user-input"
                guard let parsed = Self.questions(params["questions"], messageID: nil) else { continue }
                questions = parsed
            default: continue
            }
            let display = preview.filter { !["threadId", "turnId", "itemId", "availableDecisions"].contains($0.key) }
            guard let data = try? JSONSerialization.data(withJSONObject: display, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]), data.count <= 48000,
                  let detail = String(data: data, encoding: .utf8),
                  let fingerprint = Self.json([sessionID, turnID, raw, preview]) else { continue }
            result.append(.init(id: Self.hash(fingerprint), sessionID: sessionID, turnID: turnID, method: route,
                requestID: encoded, detail: questions.isEmpty ? detail : "", questions: questions, actions: actions, cwd: cwd))
        }
        let answered = Self.answeredIDs(items)
        let superseded = CodexDesktopState.supersededAsyncQuestionMessageIDs(items)
        for item in items where item["type"] as? String == "agentMessage" {
            guard let messageID = item["id"] as? String, !superseded.contains(messageID),
                  let questions = Self.questions(item["questions"], messageID: messageID) else { continue }
            let pending = questions.filter { !answered.contains($0.id) }
            guard !pending.isEmpty, let fingerprint = Self.json([sessionID, turnID, messageID, pending.map { [$0.id, $0.title, $0.options] as [Any] }]) else { continue }
            result.append(.init(id: Self.hash(fingerprint), sessionID: sessionID, turnID: turnID,
                method: "thread-follower-steer-turn", requestID: nil, detail: "", questions: pending, actions: [], cwd: cwd))
        }
        return Array(result.prefix(8))
    }

    private static func questions(_ value: Any?, messageID: String?) -> [CodexInteraction.Question]? {
        guard let values = value as? [[String: Any]], (1...16).contains(values.count) else { return nil }
        var questions: [CodexInteraction.Question] = []
        for (index, value) in values.enumerated() {
            guard let title = (value["title"] ?? value["question"]) as? String, !title.isEmpty, title.utf8.count <= 12000 else { return nil }
            let id: String
            if let messageID, let data = json(["request_user_input_async", messageID, index]) {
                id = String(decoding: data, as: UTF8.self)
            } else if let key = value["id"] as? String, !key.isEmpty, key.utf8.count <= 256 { id = key }
            else { return nil }
            let options: [String], descriptions: [String]
            if let strings = value["options"] as? [String] { options = strings; descriptions = strings.map { _ in "" } }
            else if let objects = value["options"] as? [[String: Any]] {
                options = objects.compactMap { $0["label"] as? String }
                descriptions = objects.map { $0["description"] as? String ?? "" }
                guard options.count == objects.count else { return nil }
            } else if value["options"] == nil || value["options"] is NSNull { options = []; descriptions = [] }
            else { return nil }
            guard options.count <= 16, options.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4000 }),
                  descriptions.allSatisfy({ $0.utf8.count <= 4000 }) else { return nil }
            questions.append(.init(id: id, title: title, options: options, optionDescriptions: descriptions, secret: value["isSecret"] as? Bool == true))
        }
        return Set(questions.map(\.id)).count == questions.count ? questions : nil
    }

    private static func project(_ value: Any, path: [Any]) -> Any {
        if path.contains(where: { ["requests", "questions", "changes"].contains($0 as? String ?? "") }) {
            return (json(value)?.count ?? .max) <= 48000 ? value : NSNull()
        }
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, entry in
                let (key, child) = entry
                if fields.contains(key) || key.hasPrefix("turn:") || key.hasPrefix("tail:") || UUID(uuidString: key) != nil {
                    result[key] = project(child, path: path + [key])
                }
            }
        }
        if let array = value as? [Any] { return array.prefix(20000).enumerated().map { project($0.element, path: path + [$0.offset]) } }
        if let text = value as? String, path.last as? String == "text" {
            guard let ids = CodexDesktopState.replyQuestionIDs(text),
                  let data = json(ids.map { ["questionItemId": $0, "question": "", "answer": ""] }) else { return "" }
            return "<send_user_message_question_reply>\(String(decoding: data, as: UTF8.self))</send_user_message_question_reply>"
        }
        return value
    }
    static func json(_ value: Any) -> Data? { try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

extension CodexInteraction {
    var presentation: AgentInteraction {
        AgentInteraction(id: id, sessionID: sessionID, detail: detail, questions: questions,
            actions: actions.map { .init(id: $0.id, label: $0.label, destructive: $0.destructive) }, expiresAt: expiresAt)
    }
}
