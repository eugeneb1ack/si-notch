import XCTest
import SINotchCore
@testable import SINotch

final class SessionNavigationTests: XCTestCase {
    @MainActor
    func testRemoteNavigationExplainsLocationWithoutOpeningLocalAppAndExpires() async {
        let model = model()
        defer { model.shutdown() }
        let navigator = NavigatorStub()
        model.sessionNavigator = navigator
        var task = session(bundle: "com.apple.Terminal")
        task.connectionID = "remote"
        let observed = AgentConnection.Observation(provider: "codex", connectionID: "remote", name: "Remote",
            lastSeen: Date(), eventAt: Date(), eventID: "heartbeat", origin: .remoteUnmanaged)
        model.connectionReceipts[observed.id] = observed
        model.jump(task)
        XCTAssertEqual(model.navigationNoticeKey, "session.remote")
        XCTAssertEqual(model.navigationErrorID, task.id)
        XCTAssertTrue(navigator.destinations.isEmpty)
        let cleared = expectation(description: "Remote notice automatically disappears")
        model.onLayout = { if model.navigationErrorID == nil { cleared.fulfill() } }
        await fulfillment(of: [cleared], timeout: 4)
        XCTAssertNil(model.navigationNoticeKey)
    }

    @MainActor
    func testOldNoticeTimerAndNavigationCallbackCannotClearNewNotice() async {
        let model = model()
        defer { model.shutdown() }
        let navigator = NavigatorStub(); model.sessionNavigator = navigator
        model.jump(session())
        let old = model.navigationNoticeTimer
        XCTAssertEqual(model.navigationNoticeKey, "session.noLocalTarget")
        model.jump(session(bundle: "com.apple.Terminal"))
        model.jump(session())
        navigator.completions[0](false)
        old?.fire()
        await Task.yield()
        XCTAssertEqual(model.navigationNoticeKey, "session.noLocalTarget")
        XCTAssertEqual(model.navigationErrorID, "task")
    }

    private let thread = "11111111-2222-4333-8444-555555555555"

    private func session(url: String? = nil, bundle: String? = nil) -> AgentSession {
        var session = AgentSession(id: "task", provider: "codex", title: "Review changes")
        session.targetURL = url
        session.terminalBundleID = bundle
        return session
    }

    func testCodexThreadOpensInCodexWithPriorityOverTerminal() {
        let url = "codex://threads/\(thread)"
        XCTAssertEqual(SessionDestination.resolve(session(url: url, bundle: "com.apple.Terminal")),
                       .link(URL(string: url)!, bundleID: "com.openai.codex"))
    }

    func testEditorFileLinksAndTerminalActivation() {
        let url = "vscode://file/Users/me/My%20Project/src.swift:10:2"
        XCTAssertEqual(SessionDestination.resolve(session(url: url)),
                       .link(URL(string: url)!, bundleID: "com.microsoft.VSCode"))
        XCTAssertEqual(SessionDestination.resolve(session(bundle: "com.mitchellh.ghostty")),
                       .application("com.mitchellh.ghostty"))
        XCTAssertNil(SessionDestination.resolve(session()))
        XCTAssertNil(SessionDestination.resolve(session(bundle: "bad app;command")))
    }

    func testUntrustedCommandAndMalformedRoutesAreNotOpened() {
        for url in ["https://example.com", "file:///tmp/example", "vscode://publisher.extension/action",
                    "vscode://file/tmp/x?command=run", "cursor://command/run", "zed://file/tmp/x#run",
                    "ghostty://run?command=ls", "codex://threads/not-a-thread", "codex://threads/\(thread)/extra",
                    "codex://user@threads/\(thread)", "codex://threads/\(thread)?prompt=run",
                    "vscode://file/tmp/%0Ax"] {
            XCTAssertNil(SessionDestination.resolve(session(url: url)), url)
            XCTAssertEqual(SessionDestination.resolve(session(url: url, bundle: "com.apple.Terminal")),
                           .application("com.apple.Terminal"), url)
        }
    }

    @MainActor
    private func model() -> AppModel {
        let suite = "si-notch.navigation-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppModel(defaults: defaults)
    }

    @MainActor
    func testSuccessfulJumpKeepsPanelOpenAndSessionAvailable() {
        let model = model()
        defer { model.shutdown() }
        let navigator = NavigatorStub()
        model.sessionNavigator = navigator
        let task = session(bundle: "com.mitchellh.ghostty")
        model.store.apply(AgentEvent(sessionID: task.id, provider: "codex", kind: .working))
        model.setExpanded(true)
        model.activateSession(task)
        XCTAssertEqual(navigator.destinations, [.application("com.mitchellh.ghostty")])
        XCTAssertTrue(model.expanded)
        navigator.completions[0](true)
        XCTAssertTrue(model.expanded)
        XCTAssertNotNil(model.store.sessions[task.id])
        XCTAssertNil(model.navigationErrorID)
    }

    @MainActor
    func testJumpLeavesCollapseToPointerExit() async throws {
        let model = model()
        defer { model.shutdown() }
        let navigator = NavigatorStub()
        model.sessionNavigator = navigator
        model.defaults.set(false, forKey: "keepOpen")
        model.pointerInside = true
        model.setExpanded(true)
        model.jump(session(bundle: "com.apple.Terminal"))
        navigator.completions[0](true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(model.expanded, "Opening another app must not collapse the hovered island")
        let closed = expectation(description: "Pointer exit collapses the island")
        model.onLayout = { if !model.expanded { closed.fulfill() } }
        let leavingAt = Date()
        model.hover(false)
        XCTAssertEqual(try XCTUnwrap(model.expansionTimer).fireDate.timeIntervalSince(leavingAt),
                       IslandTiming.hoverExit, accuracy: 0.05)
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertFalse(model.expanded, "Pointer exit should still collapse the island")
    }

    @MainActor
    func testFailedOrMissingTargetKeepsPanelOpenWithInlineError() {
        let model = model()
        defer { model.shutdown() }
        let navigator = NavigatorStub()
        model.sessionNavigator = navigator
        model.setExpanded(true)
        model.jump(session())
        XCTAssertEqual(model.navigationErrorID, "task")
        XCTAssertTrue(navigator.destinations.isEmpty)
        model.jump(session(bundle: "com.apple.Terminal"))
        XCTAssertNil(model.navigationErrorID)
        navigator.completions[0](false)
        XCTAssertTrue(model.expanded)
        XCTAssertEqual(model.navigationErrorID, "task")
    }

    @MainActor
    func testDisabledJumpTogglesDetailsAndNeverOpensApplication() {
        let model = model()
        defer { model.shutdown() }
        let navigator = NavigatorStub()
        model.sessionNavigator = navigator
        model.defaults.set(true, forKey: "disableClickJump")
        model.activateSession(session(bundle: "com.apple.Terminal"))
        XCTAssertEqual(model.selectedID, "task")
        model.activateSession(session(bundle: "com.apple.Terminal"))
        XCTAssertNil(model.selectedID)
        model.jump(session(bundle: "com.apple.Terminal"))
        XCTAssertTrue(navigator.destinations.isEmpty)
    }

    @MainActor
    func testPanelTaskShortcutsIgnoreAgentsAndHistory() {
        let model = model()
        defer { model.shutdown() }
        let navigator = NavigatorStub()
        model.sessionNavigator = navigator
        model.store.apply(AgentEvent(sessionID: "task", provider: "codex", kind: .working,
                                     terminalBundleID: "com.apple.Terminal"))
        model.setExpanded(true)
        model.selectedID = "task"
        for history in [false, true] {
            model.showAgents = !history
            model.activeFilter = history ? "history.title" : "Все"
            for key in [125, 126, 36, 76, 18] as [UInt16] {
                XCTAssertFalse(model.handlePanelKey(key, characters: key == 18 ? "1" : nil))
            }
            model.selectedID = nil
            model.moveSelection(1)
            XCTAssertNil(model.selectedID)
            model.selectedID = "task"
        }
        XCTAssertTrue(navigator.destinations.isEmpty)
        XCTAssertTrue(model.handlePanelKey(53, characters: nil), "Escape still closes either tab")
        XCTAssertFalse(model.expanded)
    }

    @MainActor
    func testPanelReturnNeverOpensSelectionHiddenByFilterOrSearch() {
        let model = model()
        defer { model.shutdown() }
        let navigator = NavigatorStub()
        model.sessionNavigator = navigator
        model.store.apply(AgentEvent(sessionID: "task", provider: "codex", kind: .working,
                                     title: "Visible task", terminalBundleID: "com.apple.Terminal"))
        model.setExpanded(true)
        model.selectedID = "task"
        model.activeFilter = "Готово"
        XCTAssertFalse(model.handlePanelKey(36, characters: nil))
        model.activeFilter = "Все"
        model.search = "no matching task"
        XCTAssertFalse(model.handlePanelKey(36, characters: nil))
        XCTAssertTrue(navigator.destinations.isEmpty)
        model.search = ""
        XCTAssertTrue(model.handlePanelKey(36, characters: nil))
        XCTAssertEqual(navigator.destinations, [.application("com.apple.Terminal")])
        model.selectedID = nil
        XCTAssertTrue(model.handlePanelKey(18, characters: "1"))
        XCTAssertEqual(model.selectedID, "task")
    }

    @MainActor
    func testStaleCompletionCannotClosePanelAfterAnotherJumpFails() {
        let model = model()
        defer { model.shutdown() }
        let navigator = NavigatorStub()
        model.sessionNavigator = navigator
        model.setExpanded(true)
        model.jump(session(bundle: "com.apple.Terminal"))
        model.jump(session())
        navigator.completions[0](true)
        XCTAssertTrue(model.expanded)
        XCTAssertEqual(model.navigationErrorID, "task")
    }
}

@MainActor
private final class NavigatorStub: SessionNavigating {
    var destinations: [SessionDestination] = []
    var completions: [@MainActor @Sendable (Bool) -> Void] = []
    func open(_ destination: SessionDestination, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        destinations.append(destination)
        completions.append(completion)
    }
}
