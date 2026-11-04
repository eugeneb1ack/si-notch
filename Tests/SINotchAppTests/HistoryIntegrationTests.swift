import XCTest
import SINotchCore
@testable import SINotch

final class HistoryIntegrationTests: XCTestCase {
    @MainActor
    func testStartupRepairsStoppedGoalFromItsCorrelatedCompletionInALaterTurn() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("si-notch.history-goal." + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let archivePath = path.appendingPathComponent("archive")
        let sources = path.appendingPathComponent("sessions")
        let folder = sources.appendingPathComponent("2026/10/23")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sid = UUID().uuidString.lowercased(), firstTurn = UUID().uuidString.lowercased(), nextTurn = UUID().uuidString.lowercased()
        let created = Date(timeIntervalSince1970: 1792761979)
        let archive = try HistoryStore(directory: archivePath, policy: .init())
        _ = try archive.accept(AgentEvent(sessionID: sid, provider: "codex", kind: .sessionEnded,
            timestamp: created, firstPrompt: "/goal Ship the app", turnID: firstTurn),
            session: AgentSession(id: sid, provider: "codex", title: "/goal Ship the app", status: .ended))
        try archive.flush()
        let before = try XCTUnwrap(archive.entry(archive.ordered[0].id))
        func goal(_ status: String, at offset: Double) -> [String: Any] {
            ["threadId": sid, "objective": "Ship the app", "status": status,
             "createdAt": created.timeIntervalSince1970, "updatedAt": created.timeIntervalSince1970 + offset]
        }
        func row(_ type: String, _ payload: [String: Any], at offset: Double = 0) -> [String: Any] {
            ["timestamp": ISO8601DateFormatter().string(from: created.addingTimeInterval(offset)), "type": type, "payload": payload]
        }
        let completed = String(decoding: try JSONSerialization.data(withJSONObject: ["goal": goal("complete", at: 90),
            "remainingTokens": NSNull(), "completionBudgetReport": NSNull()]), as: UTF8.self)
        let rows = [
            row("session_meta", ["id": sid, "source": "cli"]),
            row("event_msg", ["type": "task_started", "turn_id": firstTurn]),
            row("event_msg", ["type": "thread_goal_updated", "threadId": sid, "goal": goal("active", at: 0)]),
            row("event_msg", ["type": "turn_aborted", "turn_id": firstTurn, "reason": "interrupted"], at: 30),
            row("event_msg", ["type": "task_started", "turn_id": nextTurn], at: 60),
            row("response_item", ["type": "custom_tool_call", "name": "functions.exec", "call_id": "goal-complete",
                                  "input": "text(await tools.update_goal({status:\"complete\"}));"], at: 90),
            row("response_item", ["type": "custom_tool_call_output", "call_id": "goal-complete",
                                  "output": [["type": "input_text", "text": completed]]], at: 90),
            row("event_msg", ["type": "task_complete", "turn_id": nextTurn], at: 91)
        ]
        var data = Data()
        for value in rows { data.append(try JSONSerialization.data(withJSONObject: value)); data.append(10) }
        try data.write(to: folder.appendingPathComponent("rollout-test-\(sid).jsonl"))
        let controller = HistoryController(policy: .init())
        controller.start(directory: archivePath, codexSessionsRoot: sources)
        controller.shutdown()
        let reopened = try HistoryStore(directory: archivePath, policy: .init())
        let after = try XCTUnwrap(reopened.entry(before.id))
        XCTAssertEqual(after.summary.status, .completed)
        XCTAssertEqual(after.items, before.items)
        XCTAssertEqual(after.summary.updatedAt, before.summary.updatedAt)
        XCTAssertEqual(reopened.ordered.count, 1)
    }

    @MainActor
    func testStartupRepairsAnOldRecordedTurnWithoutImportingOtherTurns() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("si-notch.history-old." + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let archivePath = path.appendingPathComponent("archive")
        let sources = path.appendingPathComponent("sessions")
        let folder = sources.appendingPathComponent("2026/10/21")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sessionID = UUID().uuidString.lowercased(), turn = UUID().uuidString.lowercased()
        let original = try HistoryStore(directory: archivePath, policy: .init())
        _ = try original.accept(AgentEvent(sessionID: sessionID, provider: "codex", kind: .working,
            firstPrompt: "Already finished", turnID: turn),
            session: AgentSession(id: sessionID, provider: "codex", title: "Already finished", status: .working))
        try original.flush()
        let before = try XCTUnwrap(original.entry(original.ordered[0].id))
        let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7200))
        let records: [[String: Any]] = [
            ["timestamp": stamp, "type": "session_meta", "payload": ["id": sessionID, "source": "cli"]],
            ["timestamp": stamp, "type": "event_msg", "payload": ["type": "task_complete", "turn_id": turn]],
            ["timestamp": stamp, "type": "event_msg", "payload": ["type": "task_complete", "turn_id": UUID().uuidString.lowercased()]]
        ]
        let file = folder.appendingPathComponent("rollout-test-\(sessionID).jsonl")
        var data = Data()
        for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
        // The old completion has scrolled beyond the normal live scanner tail.
        for _ in 0..<5 { data.append(Data(repeating: 120, count: 1024 * 1024)); data.append(10) }
        try data.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: file.path)
        var ordinaryScanner = CodexRolloutScanner(sessionsRoot: sources, includeContent: true)
        XCTAssertTrue(ordinaryScanner.poll().isEmpty, "Old history must not become a live session")
        let history = HistoryController(policy: .init())
        history.start(directory: archivePath, codexSessionsRoot: sources)
        history.shutdown()
        let reopened = try HistoryStore(directory: archivePath, policy: .init())
        let after = try XCTUnwrap(reopened.entry(before.id))
        XCTAssertEqual(reopened.ordered.count, 1)
        XCTAssertEqual(after.summary.status, .completed)
        XCTAssertEqual(after.items, before.items)
        XCTAssertEqual(after.summary.updatedAt, before.summary.updatedAt)
    }

    @MainActor
    func testStatusOnlyHistoryCompletionWorksWithoutALiveSessionAndCannotCreateOne() throws {
        let suite = "si-notch.history-reconciliation." + UUID().uuidString
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(defaults: defaults)
        defer { model.shutdown(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: path) }
        model.history.start(directory: path)
        let session = AgentSession(id: "saved", provider: "codex", title: "Review", status: .working)
        model.history.record(AgentEvent(sessionID: "saved", provider: "codex", kind: .working,
            firstPrompt: "Review", turnID: "saved-turn"), session: session)
        model.history.shutdown()
        model.recordHistoryContent(AgentEvent(sessionID: "saved", provider: "codex", kind: .completed, turnID: "saved-turn"))
        model.recordHistoryContent(AgentEvent(sessionID: "unrecorded", provider: "codex", kind: .completed, turnID: "unrecorded-turn"))
        model.history.shutdown()
        let archive = try HistoryStore(directory: path, policy: .init())
        XCTAssertEqual(archive.ordered.count, 1)
        XCTAssertEqual(archive.ordered.first?.status, .completed)
        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertFalse(model.expanded)
    }

    @MainActor
    func testRemoteOutcomeAfterRestartClosesHistoryWithoutCreatingACard() throws {
        let suite = "si-notch.hermes-reconnect." + UUID().uuidString
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(defaults: defaults)
        defer { model.shutdown(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: path) }
        model.history.start(directory: path)
        let session = AgentSession(id: "saved", provider: "hermes", title: "Remote task", status: .working)
        model.history.record(AgentEvent(sessionID: "saved", provider: "hermes", kind: .working,
            firstPrompt: "Remote task", turnID: "saved-turn"), session: session)
        model.history.shutdown()
        model.receive(try JSONEncoder().encode(AgentEvent(sessionID: "saved", provider: "hermes",
            kind: .completed, turnID: "saved-turn"))) { _ in }
        model.history.shutdown()
        let archive = try HistoryStore(directory: path, policy: .init())
        XCTAssertEqual(archive.ordered.count, 1)
        XCTAssertEqual(archive.ordered.first?.status, .completed)
        XCTAssertTrue(model.sessions.isEmpty)
    }

    @MainActor
    func testStreamingSnapshotsKeepLatestTextAndClearFencesTheBufferedTurn() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("si-notch-history-stream-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let history = HistoryController(policy: .init())
        history.start(directory: path)
        let session = AgentSession(id: "stream", provider: "codex", title: "Review", status: .working)
        var latest = AgentEvent(sessionID: "stream", provider: "codex", kind: .working, firstPrompt: "Review", turnID: "turn-1")
        for n in 0..<100 {
            latest.id = "desktop-stream:stream:\(n)"
            latest.historyItems = [.init(id: "reply", role: .assistant, text: "Reply version \(n)")]
            history.record(latest, session: session)
        }
        history.shutdown()
        let saved = try HistoryStore(directory: path, policy: .init())
        let entry = try XCTUnwrap(saved.ordered.first.flatMap { try saved.entry($0.id) })
        XCTAssertEqual(saved.ordered.count, 1)
        XCTAssertEqual(entry.items.filter { $0.role == .assistant }.map(\.text), ["Reply version 99"])
        history.record(latest, session: session)
        history.clear()
        history.record(latest, session: session)
        history.shutdown()
        let cleared = try HistoryStore(directory: path, policy: .init())
        XCTAssertTrue(cleared.ordered.isEmpty)
    }
    @MainActor
    func testParallelTextSourceDoesNotReplayLifecycleOverNativeStatus() throws {
        let suite = "si-notch-history-parallel-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: path) }
        let model = AppModel(defaults: defaults)
        defer { model.shutdown() }
        model.history.start(directory: path)
        _ = model.store.apply(.init(sessionID: "native", provider: "codex", kind: .completed, message: "Current reply"))
        let before = model.store
        let old = AgentEvent(sessionID: "native", provider: "codex", kind: .toolStarted,
            timestamp: Date().addingTimeInterval(-1), firstPrompt: "Fix panel", turnID: "turn-1",
            historyItems: [.init(id: "call", role: .command, text: "swift test")])
        model.recordHistoryContent(old)
        model.history.shutdown()
        XCTAssertEqual(model.store.sessions, before.sessions)
        let archive = try HistoryStore(directory: path, policy: .init())
        let entry = try XCTUnwrap(archive.ordered.first.flatMap { try archive.entry($0.id) })
        XCTAssertEqual(entry.items.last?.text, "swift test")
    }
    @MainActor
    func testAcceptedNewEventsSurviveDoneButBootstrapFiltersAndApprovalPayloadDoNotEnterHistory() async throws {
        let suite = "si-notch-history-model-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: path) }
        let model = AppModel(defaults: defaults)
        defer { model.shutdown() }
        model.history.start(directory: path)
        func receive(_ event: AgentEvent, bootstrap: Bool = false) throws {
            model.receive(try JSONEncoder().encode(event), suppressPresentation: bootstrap, reply: { _ in })
        }
        try receive(.init(sessionID: "old", kind: .completed, firstPrompt: "Old conversation"), bootstrap: true)
        defaults.set("/private-project", forKey: "blockedDirectories")
        try receive(.init(sessionID: "filtered", kind: .completed, projectPath: "/private-project", firstPrompt: "Excluded"))
        try receive(.init(sessionID: "new", provider: "codex", kind: .completed, message: "Fixed", firstPrompt: "Fix panel", turnID: "turn-1"))
        model.clearFinished()
        model.history.shutdown()
        await Task.yield()
        let store = try HistoryStore(directory: path, policy: .init())
        XCTAssertEqual(store.ordered.count, 1)
        let saved = try XCTUnwrap(store.entry(store.ordered[0].id))
        XCTAssertEqual(saved.items.map(\.text), ["Fix panel", "Fixed"])
        model.activeFilter = "history.title"
        XCTAssertTrue(model.showingHistory)
        XCTAssertGreaterThan(model.desiredPanelHeight, 400)
        let permission: [String: Any] = ["event": "approval.requested", "session_id": "approval", "provider": "codex",
            "await_response": true, "request_id": "request-1", "response_timeout": 60, "message": "PRIVATE_PERMISSION_ARGUMENTS"]
        model.receive(try JSONSerialization.data(withJSONObject: permission), reply: { _ in })
        XCTAssertEqual(model.activeFilter, "Внимание")
        XCTAssertNotNil(model.pending["approval"])
        model.history.shutdown()
        let after = try HistoryStore(directory: path, policy: .init())
        XCTAssertEqual(after.ordered.count, 1)
        XCTAssertNotNil(model.pending["approval"])
    }
    func testCommandSelectionExcludesUnknownInputsAndRedactsQuotedSecrets() throws {
        XCTAssertNil(HistoryContent.command(id: "x", name: "unknown_mcp", arguments: ["command": "PRIVATE"]))
        XCTAssertEqual(HistoryContent.command(id: "x", name: "functions.exec_command", arguments: "{\"cmd\":\"swift test\",\"output\":\"PRIVATE_OUTPUT\"}")?.text, "swift test")
        let item = try XCTUnwrap(HistoryContent.command(id: "x", name: "bash", arguments: ["command": "login --password 'a private phrase' API_TOKEN=\"another secret\""]))
        XCTAssertFalse(item.text.contains("private phrase"))
        XCTAssertFalse(item.text.contains("another secret"))
        XCTAssertEqual(item.text, "login --password [redacted] API_TOKEN=[redacted]")
    }
    func testDesktopCommandPatchesRetainOnlyCommandTextAndExcludePermissionArguments() throws {
        let id = UUID().uuidString, turn = UUID().uuidString
        var state = CodexDesktopState()
        XCTAssertTrue(state.apply(["type": "snapshot", "revision": 1, "conversationState": ["id": id, "turns": [[
            "id": turn, "status": "inProgress", "items": [["id": "cmd", "type": "commandExecution", "command": "swift test", "aggregatedOutput": "PRIVATE_OUTPUT"]]]],
            "requests": [["method": "item/commandExecution/requestApproval", "params": ["command": "PRIVATE_PERMISSION", "arguments": "PRIVATE_ARGS"]]]]]))
        XCTAssertTrue(state.apply(["type": "patches", "baseRevision": 1, "revision": 2, "patches": [
            ["op": "replace", "path": ["turns", 0, "items", 0, "command"], "value": "swift build"],
            ["op": "add", "path": ["requests", 0, "params", "command"], "value": "PRIVATE_PERMISSION"]]]))
        let event = try XCTUnwrap(state.event(sessionID: id))
        XCTAssertEqual(event.historyItems?.last?.text, "swift build")
        let data = try JSONSerialization.data(withJSONObject: state.root)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE"))
        XCTAssertNoThrow(try AgentEvent.parse(data: JSONEncoder().encode(event)))
    }
    func testHistoryEnvelopeHasIndependentCountTextAndByteBounds() throws {
        var event = AgentEvent(sessionID: "test", kind: .working, historyItems: [.init(id: "cmd", role: .command, text: "swift test")])
        XCTAssertEqual(try AgentEvent.parse(data: JSONEncoder().encode(event)).historyItems, event.historyItems)
        event.historyItems = Array(repeating: .init(id: "cmd", role: .command, text: "x"), count: 65)
        XCTAssertThrowsError(try event.validate())
        event.historyItems = [.init(id: "cmd", role: .command, text: String(repeating: "x", count: 16385))]
        XCTAssertThrowsError(try event.validate())
        event.historyItems = (0..<10).map { .init(id: "cmd-\($0)", role: .command, text: String(repeating: "я", count: 10000)) }
        XCTAssertThrowsError(try event.validate())
    }
}
