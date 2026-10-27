import Foundation
import XCTest
@testable import SINotch

final class CodexInteractionTests: XCTestCase {
    private let session = "11111111-2222-4333-8444-555555555555"
    private let owner = "00112233-4455-6677-8899-aabbccddeeff"
    private let turn = "turn-a"
    private func snapshot(_ items: [[String: Any]] = [], requests: [[String: Any]] = [], revision: Int = 1) -> [String: Any] {
        ["type": "snapshot", "revision": revision, "conversationState": ["id": session, "cwd": "/tmp/test",
            "turns": [["turnId": turn, "status": "inProgress", "turnStartedAtMs": 1000, "items": items]], "requests": requests]]
    }
    private func question() -> [String: Any] {
        ["type": "agentMessage", "id": "question-call", "questions": [["title": "Which option?", "options": ["First", "Second"]]]]
    }
    private func approval(decisions: [Any] = ["accept", "acceptForSession", "decline", "cancel"]) -> [String: Any] {
        ["id": 42, "method": "item/commandExecution/requestApproval", "params": ["threadId": session, "turnId": turn,
            "itemId": "command-1", "command": "printf test", "availableDecisions": decisions, "proposedExecpolicyAmendment": ["printf", "test"]]]
    }
    func testAsyncQuestionOptionsAndExactResponseIdentity() throws {
        var state = CodexInteractionState()
        XCTAssertTrue(state.apply(snapshot([question()])))
        let request = try XCTUnwrap(state.requests(sessionID: session).first)
        let question = try XCTUnwrap(request.questions.first)
        XCTAssertEqual(question.options, ["First", "Second"])
        XCTAssertEqual(question.id, "[\"request_user_input_async\",\"question-call\",0]")
        XCTAssertNil(request.response(action: nil, answers: [:]))
        XCTAssertNil(request.response(action: nil, answers: ["other": "First"]))
        let reply = try XCTUnwrap(request.response(action: nil, answers: [question.id: "Second"]))
        XCTAssertEqual(reply.method, "thread-follower-steer-turn")
        let input = try XCTUnwrap(reply.params["input"] as? [[String: Any]])
        XCTAssertEqual(CodexDesktopState.replyQuestionIDs(input[0]["text"] as? String ?? ""), [question.id])
        XCTAssertEqual(reply.params["conversationId"] as? String, session)
        XCTAssertNil(reply.params["permissionProfileId"])
    }
    func testAcceptedAnswerClearsQuestionButPendingAnswerDoesNot() throws {
        var state = CodexInteractionState()
        state.apply(snapshot([question()]))
        let request = try XCTUnwrap(state.requests(sessionID: session).first)
        let q = request.questions[0]
        let input = try XCTUnwrap(request.response(action: nil, answers: [q.id: "First"])?.params["input"])
        let answer: [String: Any] = ["type": "steeringUserMessage", "status": "pending", "input": input]
        state.apply(snapshot([question(), answer], revision: 2))
        XCTAssertEqual(state.requests(sessionID: session).count, 1)
        XCTAssertTrue(state.apply(["type": "patches", "baseRevision": 2, "revision": 3,
            "patches": [["op": "replace", "path": ["turns", 0, "items", 1, "status"], "value": "accepted"]]]))
        XCTAssertTrue(state.requests(sessionID: session).isEmpty)
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: state.root), as: UTF8.self).contains("First\"}]}"))
    }
    func testAsyncQuestionCardClearsWhenAgentContinuesAfterUserReply() throws {
        var state = CodexInteractionState()
        let twoQuestions: [String: Any] = ["type": "agentMessage", "id": "question-call", "questions": [
            ["title": "Network?"], ["title": "VPN client?"]]]
        state.apply(snapshot([twoQuestions]))
        XCTAssertEqual(state.requests(sessionID: session).first?.questions.count, 2)
        let firstOnly = "<send_user_message_question_reply>[{\"questionItemId\":\"[\\\"request_user_input_async\\\",\\\"question-call\\\",0]\",\"question\":\"\",\"answer\":\"First\"}]</send_user_message_question_reply>"
        let items: [[String: Any]] = [twoQuestions,
            ["type": "userMessage", "content": [["type": "text", "text": firstOnly]]],
            ["type": "userMessage", "content": [["type": "text", "text": "A follow-up message"]]]]
        state.apply(snapshot(items, revision: 2))
        XCTAssertEqual(state.requests(sessionID: session).first?.questions.map(\.title), ["VPN client?"])
        state.apply(snapshot(items + [["type": "agentMessage", "id": "continuation", "text": "Continuing", "phase": "commentary"]], revision: 3))
        XCTAssertTrue(state.requests(sessionID: session).isEmpty)
        state.apply(snapshot(items + [["type": "agentMessage", "id": "continuation", "text": "Continuing", "phase": "commentary"],
                                      ["type": "agentMessage", "id": "new-question", "questions": [["title": "Still needed?"]]]], revision: 4))
        XCTAssertEqual(state.requests(sessionID: session).first?.questions.map(\.title), ["Still needed?"])
    }
    func testApprovalOnlyOffersAdvertisedDecisionsAndExactRule() throws {
        var state = CodexInteractionState()
        let rule = ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": ["printf", "test"]]]
        let unsafeRule = ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": ["sh"]]]
        state.apply(snapshot(requests: [approval(decisions: ["accept", "decline", rule, unsafeRule, "approveEverything"])]))
        let request = try XCTUnwrap(state.requests(sessionID: session).first)
        XCTAssertEqual(request.actions.map(\.label), ["interaction.allowOnce", "interaction.deny", "interaction.allowRule"])
        XCTAssertNil(request.response(action: "unadvertised", answers: [:]))
        let response = try XCTUnwrap(request.response(action: request.actions[2].id, answers: [:]))
        XCTAssertEqual(response.params["requestId"] as? Int, 42)
        XCTAssertEqual(CodexInteractionState.json(response.params["decision"]!), CodexInteractionState.json(rule))
    }
    func testForeignCompletedOversizedAndUnknownRequestsFailClosed() {
        var state = CodexInteractionState()
        for change in ["turnId": "old", "threadId": "another", "command": String(repeating: "x", count: 50000)] {
            var raw = approval(), params = raw["params"] as! [String: Any]
            params[change.key] = change.value; raw["params"] = params
            state.apply(snapshot(requests: [raw]))
            XCTAssertTrue(state.requests(sessionID: session).isEmpty)
        }
        var raw = approval(); raw["completed"] = true
        state.apply(snapshot(requests: [raw])); XCTAssertTrue(state.requests(sessionID: session).isEmpty)
        raw["completed"] = false; raw["method"] = "unknown/approval"
        state.apply(snapshot(requests: [raw])); XCTAssertTrue(state.requests(sessionID: session).isEmpty)
    }
    func testProjectionExcludesPromptsReasoningOutputsAndUnrelatedPermissions() throws {
        var state = CodexInteractionState()
        var snap = snapshot([["type": "reasoning", "text": "PRIVATE REASONING"],
                             ["type": "userMessage", "content": [["type": "text", "text": "PRIVATE PROMPT"]]],
                             ["type": "commandExecution", "aggregatedOutput": "PRIVATE OUTPUT"]])
        var root = snap["conversationState"] as! [String: Any]
        root["currentPermissions"] = ["secret": "PRIVATE PERMISSIONS"]
        snap["conversationState"] = root; state.apply(snap)
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: state.root), as: UTF8.self).contains("PRIVATE"))
    }
    func testBlockingQuestionMapsAllAnswersWithoutApprovalDecisions() throws {
        var raw = approval(); raw["method"] = "item/tool/requestUserInput"
        raw["params"] = ["threadId": session, "turnId": turn, "questions": [
            ["id": "one", "question": "Choose", "options": [["label": "A", "description": "First"]]],
            ["id": "two", "question": "Explain"]]]
        var state = CodexInteractionState(); state.apply(snapshot(requests: [raw]))
        let request = try XCTUnwrap(state.requests(sessionID: session).first)
        XCTAssertEqual(request.presentation.questions[0].optionDescriptions, ["First"])
        XCTAssertNil(request.response(action: nil, answers: ["one": "A"]))
        let result = try XCTUnwrap(request.response(action: nil, answers: ["one": "A", "two": "My answer"]))
        XCTAssertEqual(result.method, "thread-follower-submit-user-input")
        XCTAssertNil(result.params["decision"])
        XCTAssertEqual((result.params["response"] as? [String: [String: [String: [String]]]])?["answers"]?["two"]?["answers"], ["My answer"])
    }

    func testBridgeRejectsWrongOwnerAndUnconfirmedAsyncCompletion() throws {
        for wrongOwner in [true, false] {
            var displayed: [CodexInteraction] = [], frames: [[String: Any]] = [], outcomes: [Bool] = []
            let bridge = CodexInteractionBridge(update: { _, value in displayed = value }, send: { frames.append($0) }, refresh: { _ in })
            bridge.connected(clientID: owner)
            bridge.consume(sessionID: session, host: "local", owner: owner, change: snapshot([question()]))
            let request = try XCTUnwrap(displayed.first)
            bridge.submit(request, action: nil, answers: [request.questions[0].id: "First"]) { outcomes.append($0) }
            bridge.consume(sessionID: session, host: "local", owner: owner, change: snapshot([question()], revision: 2))
            bridge.receive(["type": "response", "method": "thread-owner-discovery", "requestId": frames[0]["requestId"]!,
                "resultType": "success", "handledByClientId": wrongOwner ? UUID().uuidString : owner])
            if wrongOwner { XCTAssertEqual(frames.count, 1) }
            else {
                XCTAssertEqual(frames.count, 2)
                bridge.receive(["type": "response", "method": frames[1]["method"]!, "requestId": frames[1]["requestId"]!,
                    "resultType": "success", "handledByClientId": owner, "result": ["result": ["turnId": turn]]])
                bridge.consume(sessionID: session, host: "local", owner: owner, change: snapshot(revision: 3))
            }
            XCTAssertEqual(outcomes, [false])
        }
    }

    func testBridgeRevalidatesOwnerSendsOnceAndWaitsForResolution() throws {
        var frames: [[String: Any]] = [], displayed: [CodexInteraction] = []
        var refreshes = 0, outcomes: [Bool] = []
        let bridge = CodexInteractionBridge(update: { _, value in displayed = value }, send: { frames.append($0) }, refresh: { _ in refreshes += 1 })
        bridge.connected(clientID: owner)
        bridge.consume(sessionID: session, host: "local", owner: owner, change: snapshot(requests: [approval()]))
        let request = try XCTUnwrap(displayed.first)
        bridge.submit(request, action: request.actions[0].id, answers: [:]) { outcomes.append($0) }
        XCTAssertEqual(refreshes, 1); XCTAssertTrue(frames.isEmpty)
        bridge.consume(sessionID: session, host: "local", owner: owner, change: snapshot(requests: [approval()], revision: 2))
        XCTAssertEqual(frames.count, 1); XCTAssertEqual(frames[0]["method"] as? String, "thread-owner-discovery")
        bridge.receive(["type": "response", "method": "thread-owner-discovery", "requestId": frames[0]["requestId"]!, "resultType": "success", "handledByClientId": owner])
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[1]["targetClientId"] as? String, owner)
        XCTAssertEqual(frames[1]["method"] as? String, "thread-follower-command-approval-decision")
        bridge.receive(["type": "response", "method": frames[1]["method"]!, "requestId": frames[1]["requestId"]!, "resultType": "success", "handledByClientId": owner, "result": ["ok": true]])
        XCTAssertTrue(outcomes.isEmpty, "Dispatch ACK is not resolution")
        bridge.consume(sessionID: session, host: "local", owner: owner, change: snapshot(revision: 3))
        XCTAssertEqual(outcomes, [true]); XCTAssertTrue(displayed.isEmpty)
        bridge.submit(request, action: request.actions[0].id, answers: [:]) { outcomes.append($0) }
        XCTAssertEqual(frames.count, 2); XCTAssertEqual(outcomes, [true, false])
    }
    func testBridgeCancelsIfRequestChangesBetweenClickAndSnapshot() throws {
        var displayed: [CodexInteraction] = [], frames: [[String: Any]] = [], outcomes: [Bool] = []
        let bridge = CodexInteractionBridge(update: { _, value in displayed = value }, send: { frames.append($0) }, refresh: { _ in })
        bridge.connected(clientID: owner)
        bridge.consume(sessionID: session, host: "local", owner: owner, change: snapshot(requests: [approval()]))
        let request = try XCTUnwrap(displayed.first)
        bridge.submit(request, action: request.actions[0].id, answers: [:]) { outcomes.append($0) }
        bridge.consume(sessionID: session, host: "local", owner: owner, change: snapshot(revision: 2))
        XCTAssertEqual(outcomes, [false]); XCTAssertTrue(frames.isEmpty)
    }
    func testBridgeExpiresAndDisconnectsWithoutSendingDecision() throws {
        var displayed: [CodexInteraction] = [], frames: [[String: Any]] = [], outcomes: [Bool] = []
        let bridge = CodexInteractionBridge(update: { _, value in displayed = value }, send: { frames.append($0) }, refresh: { _ in })
        bridge.connected(clientID: owner)
        let now = ProcessInfo.processInfo.systemUptime
        bridge.consume(sessionID: session, host: "local", owner: owner, change: snapshot(requests: [approval()]), now: now)
        let request = try XCTUnwrap(displayed.first)
        bridge.submit(request, action: request.actions[0].id, answers: [:], now: now) { outcomes.append($0) }
        bridge.tick(now: now + 11)
        XCTAssertEqual(outcomes, [false]); XCTAssertTrue(frames.isEmpty)
        bridge.tick(now: now + 301); XCTAssertTrue(displayed.isEmpty)
        bridge.disconnect(); XCTAssertTrue(frames.isEmpty)
    }
}
