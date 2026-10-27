import Foundation
import XCTest
import SINotchCore
@testable import SINotch

final class CodexDesktopStateTests: XCTestCase {
    func testWorkIdentityUsesNativeServiceAndSurvivesProjection() throws {
        var state = CodexDesktopState()
        XCTAssertTrue(state.apply(["type": "snapshot", "revision": 1, "conversationState": [
            "id": id, "serviceName": "codex_work_desktop", "originator": "codex_work_desktop",
            "title": "Check a task", "threadRuntimeStatus": ["type": "active"]]]))
        let event = try XCTUnwrap(state.event(sessionID: id))
        XCTAssertEqual(event.isWorkSession, true)
        XCTAssertEqual(try AgentEvent.parse(data: JSONEncoder().encode(event)).isWorkSession, true)
        XCTAssertTrue(state.apply(["type": "snapshot", "revision": 2, "conversationState": [
            "id": id, "originator": "Codex Desktop", "title": "Discuss ChatGPT Work"]]))
        XCTAssertEqual(state.event(sessionID: id)?.isWorkSession, false)
    }
    private let id = "01a1496d-a1d8-7629-abb4-f8a799d63038"
    private let key = "tail:6:local:fixture"
    private func snapshot() -> [String: Any] {
        ["type": "snapshot", "revision": 10, "conversationState": [
            "id": id, "title": "Repair session display", "cwd": "/tmp/project", "latestModel": "test-model",
            "threadRuntimeStatus": ["type": "active", "activeFlags": []],
            "turnHistory": ["kind": "canonical", "history": ["entitiesByKey": [key: [
                "turnId": "01a1496d-a1d8-7629-abb4-f8a799d63039", "turnStartedAtMs": 1000, "status": "inProgress", "items": [
                    ["type": "userMessage", "content": [["type": "text", "text": "Show session context"]]],
                    ["type": "reasoning", "content": "PRIVATE REASONING", "summary": "PRIVATE SUMMARY"],
                    ["type": "agentMessage", "phase": "commentary", "text": "Checking the event stream"],
                    ["type": "commandExecution", "status": "inProgress", "command": "swift test", "aggregatedOutput": "PRIVATE OUTPUT"]
                ]
            ]]]], "currentPermissions": ["secret": "PRIVATE PERMISSIONS"]
        ]]
    }

    func testPublicContextAndCurrentToolFromCanonicalHistory() throws {
        var state = CodexDesktopState()
        XCTAssertTrue(state.apply(snapshot()))
        let event = try XCTUnwrap(state.event(sessionID: id))
        XCTAssertEqual(event.title, "Repair session display")
        XCTAssertEqual(event.firstPrompt, "Show session context")
        XCTAssertEqual(event.message, "Checking the event stream")
        XCTAssertEqual(event.toolName, "terminal")
        XCTAssertEqual(event.modelName, "test-model")
        XCTAssertEqual(event.kind, .working)
        XCTAssertEqual(event.turnID, "01a1496d-a1d8-7629-abb4-f8a799d63039")
        let retained = String(data: try JSONSerialization.data(withJSONObject: state.root), encoding: .utf8)!
        XCTAssertFalse(retained.contains("PRIVATE"))
        XCTAssertEqual(event.historyItems?.map(\.role), [.user, .assistant, .command])
        XCTAssertEqual(event.historyItems?.last?.text, "swift test")
        XCTAssertNil(state.event(sessionID: UUID().uuidString))
    }

    func testConcreteRequestsAreSeparateFromRuntimeFlagsAndAutoReview() throws {
        var state = CodexDesktopState()
        var root: [String: Any] = ["id": id, "threadRuntimeStatus": ["type": "active", "activeFlags": ["waitingOnApproval"]],
            "turns": [["turnId": "turn-a", "status": "inProgress", "items": [["type": "automaticApprovalReview", "status": "inProgress"]]]]]
        func apply(_ revision: Int) {
            XCTAssertTrue(state.apply(["type": "snapshot", "revision": revision, "conversationState": root]))
        }
        apply(1)
        XCTAssertEqual(state.event(sessionID: id)?.kind, .approvalRequested)
        XCTAssertNil(state.event(sessionID: id)?.attentionRequestID)
        root["requests"] = [["method": "item/tool/requestUserInput", "id": 42,
                             "params": ["turnId": "turn-a", "questions": [["question": "PRIVATE QUESTION"]], "command": "PRIVATE COMMAND"]]]
        apply(2)
        XCTAssertNotNil(state.event(sessionID: id)?.attentionRequestID)
        let event = try XCTUnwrap(state.event(sessionID: id))
        XCTAssertEqual(try AgentEvent.parse(data: JSONEncoder().encode(event)).attentionRequestID, event.attentionRequestID)
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: state.root), as: UTF8.self).contains("PRIVATE"))
        XCTAssertTrue(state.apply(["type": "patches", "baseRevision": 2, "revision": 3,
                                  "patches": [["op": "remove", "path": ["requests", 0]]]]))
        XCTAssertNil(state.event(sessionID: id)?.attentionRequestID)
        root["requests"] = [["method": "mcpServer/elicitation/request", "id": 43, "completed": true],
                            ["method": "item/tool/requestUserInput", "id": 44, "params": ["turnId": "old-turn"]]]
        apply(4)
        XCTAssertNil(state.event(sessionID: id)?.attentionRequestID)
    }

    func testCurrentTurnReasoningWithNullLegacyMetadata() throws {
        var state = CodexDesktopState()
        let settings: [String: Any] = ["model": "current-model", "reasoning_effort": "xhigh",
                                       "developer_instructions": "PRIVATE INSTRUCTIONS"]
        let turn: [String: Any] = ["turnStartedAtMs": 1000, "status": "inProgress",
            "requestedReasoningEffort": "high", "params": ["model": NSNull(), "effort": NSNull(),
                "collaborationMode": ["settings": settings]],
            "items": [["type": "reasoning", "text": "PRIVATE REASONING"]]]
        XCTAssertTrue(state.apply(["type": "snapshot", "revision": 1, "conversationState": [
            "id": id, "latestModel": NSNull(), "latestReasoningEffort": NSNull(),
            "turnHistory": ["history": ["entitiesByKey": [key: turn]]]]]))
        let base: [Any] = ["turnHistory", "history", "entitiesByKey", key]
        XCTAssertEqual(state.event(sessionID: id)?.modelName, "current-model")
        XCTAssertEqual(state.event(sessionID: id)?.reasoningEffort, "high")
        XCTAssertTrue(state.apply(["type": "patches", "baseRevision": 1, "revision": 2,
            "patches": [["op": "remove", "path": base + ["requestedReasoningEffort"]]]]))
        XCTAssertEqual(state.event(sessionID: id)?.reasoningEffort, "xhigh")
        XCTAssertTrue(state.apply(["type": "patches", "baseRevision": 2, "revision": 3,
            "patches": [["op": "replace", "path": base + ["params", "collaborationMode", "settings", "reasoning_effort"], "value": "low"]]]))
        XCTAssertEqual(state.event(sessionID: id)?.reasoningEffort, "low")
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: state.root), as: UTF8.self).contains("PRIVATE"))
        var store = SessionStore()
        store.apply(try XCTUnwrap(state.event(sessionID: id)))
        XCTAssertEqual(store.sessions[id]?.reasoningEffort, "low")
    }

    func testReasoningUsesLatestTurnAndKeepsLegacyCompatibility() {
        var state = CodexDesktopState()
        var root: [String: Any] = ["id": id, "turns": [
            ["turnStartedAtMs": 1.0, "requestedReasoningEffort": "high"],
            ["turnStartedAtMs": 2.0, "params": ["model": "new-model", "effort": "medium"]]
        ]]
        XCTAssertTrue(state.apply(["type": "snapshot", "revision": 1, "conversationState": root]))
        XCTAssertEqual(state.event(sessionID: id)?.reasoningEffort, "medium")
        root["latestReasoningEffort"] = "xhigh"
        XCTAssertTrue(state.apply(["type": "snapshot", "revision": 2, "conversationState": root]))
        XCTAssertEqual(state.event(sessionID: id)?.reasoningEffort, "xhigh")
        var store = SessionStore()
        if let event = state.event(sessionID: id) { store.apply(event) }
        root["latestReasoningEffort"] = NSNull()
        root["turns"] = [["turnStartedAtMs": 3.0, "params": ["model": "new-model"]]]
        XCTAssertTrue(state.apply(["type": "snapshot", "revision": 3, "conversationState": root]))
        XCTAssertEqual(state.event(sessionID: id)?.reasoningEffort, "")
        if let event = state.event(sessionID: id) { store.apply(event) }
        XCTAssertEqual(store.sessions[id]?.reasoningEffort, "")
    }

    func testAsyncQuestionIsClearedByAcceptedLongReplyAndTurnCompletion() throws {
        var state = CodexDesktopState()
        let messageID = "call/ID"
        let questionID = String(decoding: try JSONSerialization.data(withJSONObject: ["request_user_input_async", messageID, 0], options: [.withoutEscapingSlashes]), as: UTF8.self)
        let reply = String(decoding: try JSONSerialization.data(withJSONObject: ["questionItemId": questionID,
            "question": "PRIVATE QUESTION", "answer": String(repeating: "PRIVATE ANSWER ", count: 500)]), as: UTF8.self)
        let turn: [String: Any] = ["turnId": "active", "status": "inProgress", "items": [
            ["type": "agentMessage", "id": messageID, "questions": [["question": "PRIVATE QUESTION"]]],
            ["type": "steeringUserMessage", "status": "pending", "input": [["type": "text", "text": "<send_user_message_question_reply>\(reply)</send_user_message_question_reply>"]]]]]
        XCTAssertTrue(state.apply(["type": "snapshot", "revision": 1, "conversationState": ["id": id, "turns": [turn]]]))
        XCTAssertNotNil(state.event(sessionID: id)?.attentionRequestID)
        let retained = String(decoding: try JSONSerialization.data(withJSONObject: state.root), as: UTF8.self)
        XCTAssertFalse(retained.contains("PRIVATE"))
        XCTAssertTrue(state.apply(["type": "patches", "baseRevision": 1, "revision": 2,
            "patches": [["op": "replace", "path": ["turns", 0, "items", 1, "status"], "value": "accepted"]]]))
        XCTAssertNil(state.event(sessionID: id)?.attentionRequestID)
        XCTAssertTrue(state.apply(["type": "snapshot", "revision": 3, "conversationState": ["id": id, "turns": [turn]]]))
        XCTAssertNotNil(state.event(sessionID: id)?.attentionRequestID)
        XCTAssertTrue(state.apply(["type": "patches", "baseRevision": 3, "revision": 4,
            "patches": [["op": "replace", "path": ["turns", 0, "status"], "value": "completed"]]]))
        XCTAssertNil(state.event(sessionID: id)?.attentionRequestID)
    }

    func testAsyncQuestionIsClearedWhenAgentContinuesAfterUserReply() throws {
        let question: [String: Any] = ["type": "agentMessage", "id": "question-call", "questions": [[:], [:]]]
        let turnID = UUID().uuidString
        let firstAnswer = "<send_user_message_question_reply>[{\"questionItemId\":\"[\\\"request_user_input_async\\\",\\\"question-call\\\",0]\",\"question\":\"\",\"answer\":\"First\"}]</send_user_message_question_reply>"
        let items: [[String: Any]] = [question,
            ["type": "userMessage", "content": [["type": "text", "text": firstAnswer]]],
            ["type": "userMessage", "content": [["type": "text", "text": "A follow-up message"]]]]
        var state = CodexDesktopState()
        func apply(_ items: [[String: Any]], revision: Int) {
            XCTAssertTrue(state.apply(["type": "snapshot", "revision": revision, "conversationState": [
                "id": id, "threadRuntimeStatus": ["type": "active", "activeFlags": []],
                "turns": [["turnId": turnID, "status": "inProgress", "items": items]]]]))
        }
        apply(items, revision: 1)
        XCTAssertEqual(state.event(sessionID: id)?.kind, .waiting)
        apply(items + [["type": "agentMessage", "id": "continuation", "text": "Continuing", "phase": "commentary"]], revision: 2)
        XCTAssertNil(state.event(sessionID: id)?.attentionRequestID)
        XCTAssertEqual(state.event(sessionID: id)?.kind, .working)
        apply(items + [["type": "agentMessage", "id": "continuation", "text": "Continuing", "phase": "commentary"],
                       ["type": "agentMessage", "id": "new-question", "questions": [[:]]]], revision: 3)
        XCTAssertNotNil(state.event(sessionID: id)?.attentionRequestID)
    }

    func testDeltasKeepIndicesButNeverRetainToolOutput() throws {
        var state = CodexDesktopState(); XCTAssertTrue(state.apply(snapshot()))
        let base: [Any] = ["turnHistory", "history", "entitiesByKey", key, "items"]
        XCTAssertTrue(state.apply(["type": "patches", "baseRevision": 10, "revision": 11, "patches": [
            ["op": "replace", "path": base + [3, "aggregatedOutput"], "value": "SECRET OUTPUT"],
            ["op": "replace", "path": base + [3, "status"], "value": "completed"],
            ["op": "add", "path": base + [4], "value": ["type": "agentMessage", "text": "The stream is connected", "phase": "commentary"]]
        ]]))
        XCTAssertEqual(state.event(sessionID: id)?.message, "The stream is connected")
        XCTAssertNil(state.event(sessionID: id)?.toolName)
        XCTAssertFalse(String(data: try JSONSerialization.data(withJSONObject: state.root), encoding: .utf8)!.contains("SECRET"))
    }

    func testMissingRevisionRequiresResnapshot() {
        var state = CodexDesktopState(); XCTAssertTrue(state.apply(snapshot()))
        XCTAssertFalse(state.apply(["type": "patches", "baseRevision": 9, "revision": 11, "patches": []]))
        XCTAssertEqual(state.revision, 10)
    }

    func testCompletedTurnAndWaitingFlagsHaveDifferentStates() {
        var state = CodexDesktopState(); XCTAssertTrue(state.apply(snapshot()))
        XCTAssertTrue(state.apply(["type": "patches", "baseRevision": 10, "revision": 11, "patches": [
            ["op": "replace", "path": ["threadRuntimeStatus", "activeFlags"], "value": ["waitingOnApproval"]]
        ]]))
        XCTAssertEqual(state.event(sessionID: id)?.kind, .approvalRequested)
        XCTAssertTrue(state.apply(["type": "patches", "baseRevision": 11, "revision": 12, "patches": [
            ["op": "replace", "path": ["threadRuntimeStatus"], "value": ["type": "idle"]],
            ["op": "replace", "path": ["turnHistory", "history", "entitiesByKey", key, "status"], "value": "completed"]
        ]]))
        XCTAssertEqual(state.event(sessionID: id)?.kind, .completed)
    }

    func testTerminalTurnWinsOverStaleRuntimeActivity() {
        for (status, expected) in [("completed", AgentEventKind.completed), ("failed", .failed),
                                   ("interrupted", .sessionStarted)] {
            for flags in [[], ["waitingOnApproval"], ["waitingOnUserInput"]] {
                var state = CodexDesktopState()
                XCTAssertTrue(state.apply(["type": "snapshot", "revision": 1, "conversationState": [
                    "id": id, "threadRuntimeStatus": ["type": "active", "activeFlags": flags],
                    "turns": [["turnId": UUID().uuidString, "status": status, "items": []]]]]))
                XCTAssertEqual(state.event(sessionID: id)?.kind, expected, status)
                XCTAssertNil(state.event(sessionID: id)?.attentionRequestID)
            }
        }
    }

    func testLoadingRuntimeWithoutCurrentTurnIsNotWorking() {
        for turns in [[], [["turnId": UUID().uuidString]]] {
            var state = CodexDesktopState()
            XCTAssertTrue(state.apply(["type": "snapshot", "revision": 1, "conversationState": [
                "id": id, "threadRuntimeStatus": ["type": "active", "activeFlags": ["waitingOnApproval"]],
                "turns": turns]]))
            XCTAssertEqual(state.event(sessionID: id)?.kind, .sessionStarted)
        }
    }

    func testClassicTurnsAndSafeTokens() {
        var state = CodexDesktopState()
        XCTAssertTrue(state.apply(["type": "snapshot", "revision": 1, "conversationState": [
            "id": id, "title": "Task", "turns": [["turnStartedAtMs": 1, "status": "completed", "items": [
                ["type": "agentMessage", "text": "Finished", "phase": "final_answer"]
            ]]], "latestTokenUsageInfo": ["total": ["inputTokens": 100, "outputTokens": 20], "last": ["totalTokens": 80], "modelContextWindow": 1000]
        ]]))
        XCTAssertEqual(state.event(sessionID: id)?.message, "Finished")
        XCTAssertEqual(state.event(sessionID: id)?.usage?.usedPercent, 8)
    }

    func testStaleSocketSnapshotDoesNotSuppressFallback() {
        var feed = CodexDesktopFeed()
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertNotNil(feed.consume(id: id, host: "durable", change: snapshot(), now: now).event)
        XCTAssertTrue(feed.isFresh(id, now: now.addingTimeInterval(10)))
        XCTAssertFalse(feed.isFresh(id, now: now.addingTimeInterval(16)))
        XCTAssertFalse(feed.isFresh(id, now: now.addingTimeInterval(-1)))
    }

    func testSeparateHostsCannotOverwriteActiveStateOrMixRevisions() {
        var feed = CodexDesktopFeed()
        let now = Date(timeIntervalSince1970: 1000)
        _ = feed.consume(id: id, host: "durable", change: snapshot(), now: now)
        var other = snapshot()
        other["conversationState"] = ["id": id, "threadRuntimeStatus": ["type": "idle"]]
        XCTAssertNil(feed.consume(id: id, host: "local", change: other, now: now.addingTimeInterval(1)).event)
        let delta: [String: Any] = ["type": "patches", "baseRevision": 10, "revision": 11, "patches": []]
        XCTAssertTrue(feed.consume(id: id, host: "local", change: delta, now: now.addingTimeInterval(16)).needsSnapshot)
        XCTAssertNotNil(feed.consume(id: id, host: "local", change: other, now: now.addingTimeInterval(17)).event)
    }

    func testUnchangedPublicContentStillRefreshesLongRunningSession() {
        var feed = CodexDesktopFeed()
        let now = Date(timeIntervalSince1970: 1000)
        let first = feed.consume(id: id, host: "durable", change: snapshot(), now: now)
        XCTAssertNil(feed.consume(id: id, host: "durable", change: snapshot(), now: now.addingTimeInterval(1)).event)
        let heartbeat = feed.consume(id: id, host: "durable", change: snapshot(), now: now.addingTimeInterval(31))
        XCTAssertEqual(heartbeat.event?.kind, .working)
        XCTAssertNotEqual(first.event?.id, heartbeat.event?.id)
        XCTAssertFalse(heartbeat.bootstrap)
    }

    func testBrokenRevisionRestoresFallbackUntilNewSnapshot() {
        var feed = CodexDesktopFeed()
        _ = feed.consume(id: id, host: "local", change: snapshot())
        XCTAssertTrue(feed.consume(id: id, host: "local", change: ["type": "patches", "baseRevision": 3, "revision": 11, "patches": []]).needsSnapshot)
        XCTAssertFalse(feed.isFresh(id))
        XCTAssertNotNil(feed.consume(id: id, host: "local", change: snapshot()).event)
    }
}
