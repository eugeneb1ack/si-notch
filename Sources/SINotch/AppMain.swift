import AppKit
import Combine
import SwiftUI
import Carbon
import ServiceManagement
import SINotchCore
import SINotchTransport

@main
struct SINotchMain {
    static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--install-update" {
            exit(UpdateInstaller.run(receipt: URL(fileURLWithPath: CommandLine.arguments[2])))
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppModel: ObservableObject {
    // Retain multiple simultaneous tasks for at least a hundred profiles while
    // keeping the live in-memory store bounded independently of History.
    @Published var store = SessionStore(maximumSessions: 1024)
    @Published var expanded = false
    @Published var paused = false
    @Published var serverError: AppDisplayError?
    @Published var receivedCount = 0
    @Published var providerReceipts: [String: Date] = [:]
    @Published var legacyProviderReceipts: [String: Date] = [:]
    @Published var connectionReceipts: [String: AgentConnection.Observation] = [:]
    @Published var activity: [String: [SessionActivity]] = [:]
    @Published var selectedID: String?
    @Published var pending: [String: PendingRequest] = [:]
    @Published var codexInteractions: [String: [CodexInteraction]] = [:]
    @Published var interactionSubmitting: Set<String> = []
    @Published var interactionErrors: Set<String> = []
    var codexResponder: ((CodexInteraction, String?, [String: String], @escaping (Bool) -> Void) -> Void)?
    @Published var navigationErrorID: String?
    @Published var navigationNoticeKey: String?
    var navigationNoticeTimer: Timer?
    var sessionNavigator: any SessionNavigating = SessionNavigator()
    private var navigationGeneration = 0
    @Published var settingsError: AppDisplayError?
    @Published var activeFilter = "Все" {
        didSet { if oldValue != activeFilter { sessionQueryChanged() } }
    }
    @Published var search = "" {
        didSet { if oldValue != search { sessionQueryChanged() } }
    }
    @Published var showAgents = false
    @Published var expandedConnectors: Set<UUID> = []
    @Published var detectedHarnesses: [HarnessDetection] = []
    @Published var runningAgentProviders: Set<String> = []
    @Published var presenceNow = Date()
    var appOwnedTitles: [String: String] = [:]
    var appOwnedMessages: [String: String] = [:]
    var measuredSessionHeights: [String: CGFloat] = [:]
    @Published var revision = 0
    @Published var cameraWidth: CGFloat = 190
    @Published var headerHeight: CGFloat = 36
    @Published var floatingSurface = false
    @Published var trailingSurface = false
    @Published var expandedPanelWidth: CGFloat = 680
    @Published var expandedPanelHeight: CGFloat = 210
    var server: IPCServer?
    var codexObserver: CodexSessionObserver?
    var piObserver: PiSessionObserver?
    let remoteConnections: RemoteConnectionManager
    private var remoteSubscription: AnyCancellable?
    var onLayout: (() -> Void)?
    var openSettings: (() -> Void)?
    var openUsage: ((String?) -> Void)?
    var openIntegrations: (() -> Void)?
    var openRemoteConnections: (() -> Void)?
    var closeSettings: (() -> Void)?
    var focusPanel: (() -> Void)?
    var timer: Timer?
    var expansionTimer: Timer?
    var revealTimer: Timer?
    private var hoverIntent: HoverIntent?
    var hoverLocation: () -> CGPoint = { NSEvent.mouseLocation }
    var hoverHitTest: ((CGPoint) -> Bool)?
    var hoverRegion: CGRect?
    var compactHoverRegion: CGRect?
    private var hoverCooldownUntil: TimeInterval = 0
    private(set) var expansionHistory: [[String: Any]] = []
    private var expansionGeneration: UInt64 = 0
    private var revealGeneration: UInt64 = 0
    private var expansionOrigin: IslandExpansionOrigin = .manual
    private var codexServiceSessions = CodexServiceSessionFilter()
    private var observedAttention: [String: (id: String, seenAt: TimeInterval)] = [:]
    var pointerInside = false
    var reminders = FollowUpReminders()
    var presentationPolicy: PresentationPolicy?
    var transientMessage: String?
    let defaults: UserDefaults
    let soundPlayer: EventSoundPlayer
    let usage = UsageController()
    let quota: CodexQuotaController
    private var usageSubscription: AnyCancellable?
    let history: HistoryController
    private var historySubscription: AnyCancellable?
    private var sessionSounds = SessionSoundPolicy()
    private var presenceObservers: [NSObjectProtocol] = []

    struct PendingRequest {
        let token = UUID().uuidString
        let expiresAt: TimeInterval
        let sessionID: String
        let requestID: String
        let message: String
        let messageIsAppOwned: Bool
        let question: Bool
        let receivedAt: Date
        let reply: (Data) -> Void
    }

    var sessionFilter: SessionFilter { SessionFilter(directories: defaults.string(forKey: "blockedDirectories") ?? "", promptPrefixes: defaults.string(forKey: "blockedPromptPrefixes") ?? "") }
    var sessions: [AgentSession] { store.orderedSessions.filter { AgentConnection.isTask($0) && !sessionFilter.hides(path: $0.projectPath, firstPrompt: $0.firstPrompt) } }
    var agents: [AgentConnection] {
        AgentConnection.project(detected: detectedHarnesses, sessions: store.orderedSessions,
            receipts: legacyProviderReceipts, running: runningAgentProviders, now: presenceNow, connections: connectionReceipts,
            configurations: remoteConnections.agentConfigurations(for: connectionReceipts))
    }
    var agentsSectionHeight: CGFloat { 40 }
    func displayTitle(_ session: AgentSession) -> String {
        guard let key = appOwnedTitles[session.id], session.title == key else { return session.title }
        return L10n.tr(key)
    }
    func displayMessage(_ session: AgentSession, _ message: String) -> String {
        guard let key = appOwnedMessages[session.id], message == key else { return message }
        return L10n.tr(key)
    }
    var filtered: [AgentSession] {
        sessions.filter { s in
            if attentionIdentity(s.id) != nil { return true }
            let matchesFilter = activeFilter == "Все" || (activeFilter == "В работе" && s.status == .working) || (activeFilter == "Внимание" && [.approval, .waiting, .failed].contains(s.status)) || (activeFilter == "Готово" && s.status == .completed)
            let matchesSearch = search.isEmpty || "\(s.title) \(s.provider) \(s.projectPath ?? "")".localizedCaseInsensitiveContains(search)
            return matchesFilter && matchesSearch
        }
    }
    var dominantStatus: AgentStatus {
        if serverError != nil { return .failed }
        for status: AgentStatus in [.approval, .waiting, .failed, .working, .completed] {
            if sessions.contains(where: { $0.status == status }) { return status }
        }
        return .idle
    }
    let compactWingWidth: CGFloat = 26
    let compactStatusWidth: CGFloat = 18
    var compactShoulderWidth: CGFloat { floatingSurface ? 10 : 3 }
    var compactHeight: CGFloat { floatingSurface ? 30 : max(33, headerHeight) }
    var desiredPanelHeight: CGFloat {
        if showAgents {
            let connections = remoteConnections.connections.filter(\.showInAgents)
            let rows = agents.filter { $0.connectorID == nil }.count + connections.count +
                connections.filter { expandedConnectors.contains($0.id) }.reduce(0) { count, connection in
                    count + max(1, agents.filter { $0.connectorID == connection.id }.count)
                }
            return headerHeight + agentsSectionHeight + 52 + (rows == 0 ? 56 : CGFloat(rows) * 32)
        }
        if showingHistory { return headerHeight + agentsSectionHeight + 420 }
        if sessions.isEmpty { return headerHeight + (quiet ? 204 : 180) + agentsSectionHeight }
        let filters: CGFloat = 38
        let searchHeight: CGFloat = sessions.count > 3 || !search.isEmpty ? 44 : 0
        let footer: CGFloat = quiet || sessions.contains(where: { $0.status == .completed || $0.status == .failed }) ? 32 : 0
        let cards = filtered.prefix(4).reduce(0.0) { height, session in
            let estimate = SessionCardContent(session: session, displayTitle: displayTitle(session),
                displayMessage: session.lastMessage.map { displayMessage(session, $0) })
                .estimatedCollapsedHeight(fontSize: defaults.double(forKey: "fontSize"),
                                          showActivity: defaults.bool(forKey: "showActivity"),
                                          showModel: defaults.bool(forKey: "showModel"),
                                          showReasoning: defaults.bool(forKey: "showReasoning"))
            return height + (measuredSessionHeights[session.id] ??
                            (estimate + (selectedID == session.id || pending[session.id] != nil ? 100 : 0))) + 2
        }
        return headerHeight + 14 + filters + searchHeight + footer + agentsSectionHeight + (filtered.isEmpty ? 78 : cards)
    }

    func panelHeight(limitedTo maximum: CGFloat) -> CGFloat {
        min(maximum, desiredPanelHeight)
    }

    func selectAgents(_ value: Bool) {
        showAgents = value
        setExpanded(true)
        onLayout?()
    }

    func setConnectorExpanded(_ id: UUID, _ value: Bool) {
        if value { expandedConnectors.insert(id) } else { expandedConnectors.remove(id) }
        if showAgents { onLayout?() }
    }

    private func sessionQueryChanged() {
        // Filters sit at the top, so their hit targets stay put while the panel
        // resizes. Do not wait for a card measurement or the next agent event.
        cancelExpansionTimer()
        cancelRevealTimer()
        if showingHistory { history.back() }
        onLayout?()
    }
    var showingHistory: Bool { activeFilter == "history.title" }

    func measureSessionCards(_ values: [String: CGFloat]) {
        let valid = values.filter { store.sessions[$0.key] != nil && $0.value.isFinite && (30...10000).contains($0.value) }
        guard valid.contains(where: { abs((measuredSessionHeights[$0.key] ?? 0) - $0.value) > 0.5 }) else { return }
        measuredSessionHeights = measuredSessionHeights.filter { store.sessions[$0.key] != nil }
        measuredSessionHeights.merge(valid) { _, new in new }
        onLayout?()
    }
    var attentionCount: Int { sessions.filter { [.approval, .waiting, .failed].contains($0.status) }.count }
    var workingCount: Int { sessions.filter { $0.status == .working }.count }
    var presentationState: IslandPresentationState {
        IslandPresentationState(hasSessions: !sessions.isEmpty, hasWorkingSessions: workingCount > 0,
            hasPendingRequest: !pending.isEmpty || !codexInteractions.isEmpty, pointerInside: pointerInside,
            isExpanded: expanded, keepOpen: defaults.bool(forKey: "keepOpen"))
    }
    var showHover: Bool { defaults.object(forKey: "hoverExpand") as? Bool ?? true }
    var quiet: Bool { defaults.bool(forKey: "quiet") }
    var socketPath: String { ProcessInfo.processInfo.environment["SI_NOTCH_SOCKET"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".si-notch/run/events.sock").path }

    init(defaults: UserDefaults = .standard, soundPlayer: EventSoundPlayer? = nil) {
        self.defaults = defaults
        self.quota = CodexQuotaController(defaults: defaults)
        self.remoteConnections = RemoteConnectionManager(defaults: defaults)
        self.soundPlayer = soundPlayer ?? EventSoundPlayer(defaults: defaults)
        self.history = HistoryController(policy: HistoryPolicy(defaults: defaults))
        usageSubscription = usage.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        historySubscription = history.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        remoteSubscription = remoteConnections.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.revision += 1; self?.onLayout?() }
        }
        remoteConnections.onEvent = { [weak self] data, connectorID, reply in
            guard let self else { reply(nil); return }
            self.receive(data, origin: .remote(connectorID), reply: { reply($0) })
        }
        defaults.register(defaults: ["codexAutoDetect": true, "updateBackgroundChecks": true])
        defaults.register(defaults: PresentationPolicy.registeredDefaults)
        defaults.register(defaults: DisplayPreferences.defaults)
        defaults.register(defaults: ["hoverExpand": true, "autoExpand": true, "sound": false, "soundVolume": 0.3, "soundWorking": false, "idleMinutes": 120, "showCompanion": true, "hoverDelay": IslandTiming.hoverEnter, "revealDwell": 5.0, "completionReveal": false, "attentionReveal": true, "shortcutEnabled": true, "shortcutModifier": "ctrlAlt"])
    }

    func start() {
        usage.start()
        quota.start()
        history.start(codexSessionsRoot: defaults.bool(forKey: "codexAutoDetect") ?
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true) : nil)
        detectedHarnesses = HarnessDiscoveryService().scan().detected
        refreshAgentPresence()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            presenceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshAgentPresence() }
            })
        }
        do {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/si-notchctl")
            let ipc = IPCServer(socketPath: socketPath, maxConnections: 128, onPeerMessage: { [weak self] data, executable, reply in
                let origin = AgentConnection.receivingOrigin(peerExecutable: executable, helperURL: helper)
                DispatchQueue.main.async { self?.receive(data, origin: origin, reply: { reply($0) }) }
            })
            try ipc.start()
            server = ipc
            serverError = nil
            remoteConnections.restoreConnections(localSocketPath: socketPath)
        } catch { serverError = .channel(error.localizedDescription) }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 0.2
        refreshCodexObserver()
        piObserver = PiSessionObserver { [weak self] event, bootstrap in
            Task { @MainActor in
                guard let self, self.pending[event.sessionID] == nil,
                      !bootstrap || self.store.sessions[event.sessionID] == nil,
                      let data = try? JSONEncoder().encode(event) else { return }
                self.receive(data, suppressPresentation: bootstrap, reply: { _ in })
            }
        }
        piObserver?.start()
    }

    func refreshCodexObserver() {
        guard defaults.bool(forKey: "codexAutoDetect") else { codexObserver?.stop(); codexInteractions.removeAll(); return }
        if codexObserver == nil {
            codexObserver = CodexSessionObserver(onHistory: { [weak self] event in
                Task { @MainActor in self?.recordHistoryContent(event) }
            }, onInteractions: { [weak self] id, requests in
                Task { @MainActor in self?.receiveCodexInteractions(id, requests: requests) }
            }) { [weak self] event, bootstrap in
                Task { @MainActor in
                    self?.receiveCodexObservation(event, bootstrap: bootstrap)
                }
            }
        }
        codexObserver?.start()
    }

    func recordHistoryContent(_ event: AgentEvent) {
        guard !paused else { return }
        if event.kind.historyTerminalStatus != nil { history.finish(event) }
        guard event.historyItems?.isEmpty == false,
              let session = store.sessions[event.sessionID], AgentConnection.isTask(session),
              !codexServiceSessions.hides(event),
              !sessionFilter.hides(path: event.projectPath ?? session.projectPath, firstPrompt: event.firstPrompt ?? session.firstPrompt) else { return }
        history.record(event, session: session)
    }

    func receiveCodexObservation(_ event: AgentEvent, bootstrap: Bool) {
        guard defaults.bool(forKey: "codexAutoDetect"), pending[event.sessionID] == nil else { return }
        let previous = store.sessions[event.sessionID]
        let nativeSnapshot = event.id?.hasPrefix("desktop-stream:") == true
        let rolloutStart = event.turnID.map { turn in
            event.id == "rollout:\(turn):start" || event.id == "rollout:\(turn):bootstrap"
        } ?? false
        // SessionEnd from a CLI process closes that process, not the durable
        // conversation. Only a fresh, identified turn may reopen it. Keep the
        // reducer's terminal-state protection for arbitrary late tool events.
        let reopens = previous?.status == .ended && event.turnID != nil &&
            [.working, .waiting].contains(event.kind) && (nativeSnapshot || rolloutStart) &&
            event.timestamp >= (previous?.lastEventAt ?? .distantFuture)
        let freshRolloutTurn = rolloutStart && event.kind == .working &&
            event.timestamp >= (previous?.lastEventAt ?? .distantFuture)
        guard !bootstrap || previous == nil || nativeSnapshot || freshRolloutTurn else { return }
        if reopens {
            var start = event
            start.kind = .sessionStarted; start.id = event.id.map { $0 + ":reopen" }
            start.title = nil; start.message = nil; start.firstPrompt = nil
            start.attentionRequestID = nil
            if let data = try? JSONEncoder().encode(start) { receive(data, suppressPresentation: true, reply: { _ in }) }
        }
        var update = event
        if update.id?.hasPrefix("desktop:") == true, previous != nil { update.title = nil }
        guard let data = try? JSONEncoder().encode(update) else { return }
        receive(data, suppressPresentation: bootstrap, reply: { _ in })
    }

    func receive(_ data: Data, origin: AgentConnection.Origin = .unknown,
                 suppressPresentation: Bool = false, reply: @escaping (Data) -> Void) {
        if let control = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           control.count == 2, control["command"] as? String == "status",
           control["protocol_version"] as? Int == 1 {
            reply(json(["ok": true, "protocol_version": 1, "received_count": receivedCount,
                        "paused": paused, "session_count": sessions.count,
                        "visible_session_count": showAgents ? 0 : filtered.count, "active_filter": activeFilter, "tab": showAgents ? "agents" : "sessions",
                        "agents": agents.map { ["id": $0.id, "provider": $0.provider, "name": $0.name, "state": $0.state.rawValue,
                            "activity": $0.activity.rawValue, "active_task_count": $0.activeTaskCount,
                            "remote": $0.connectorID != nil || connectionReceipts[$0.id]?.origin.isRemote == true,
                            "last_seen": $0.lastSeen.map { $0.timeIntervalSince1970 as Any } ?? NSNull()] as [String: Any] },
                        "remote_connections": remoteConnections.connections.map { ["id": $0.id.uuidString, "name": $0.displayName,
                            "status": remoteConnections.state($0.id).statusName] },
                        "expanded": expanded, "expansion_history": expansionHistory,
                        "presentation": presentationPolicy?.diagnostics ?? [:],
                        "providers": providerReceipts.mapValues { $0.timeIntervalSince1970 },
                        "sessions": sessions.map { ["id": $0.id, "provider": $0.provider, "status": $0.status.rawValue,
                            "connection_id": $0.connectionID as Any? ?? NSNull(), "turn_id": $0.turnID as Any? ?? NSNull(),
                            "last_event_at": $0.lastEventAt.timeIntervalSince1970,
                            "last_sequence": $0.lastSequence as Any? ?? NSNull(), "current_tool": $0.currentTool as Any? ?? NSNull()] }]))
            return
        }
        guard !paused else { reply(json(["ok": false, "error": "paused"])); return }
        do {
            var event = try AgentEvent.parse(data: data)
            event.provider = event.provider.lowercased()
            // Later hooks may omit profile metadata; the session's existing
            // identity remains authoritative and cannot become a legacy receipt.
            if event.connectionID == nil, let session = store.sessions[event.sessionID], session.provider == event.provider {
                event.connectionID = session.connectionID
                event.connectionName = session.connectionName
            }
            guard let connectionOrigin = connectionOrigin(for: event, from: origin) else {
                reply(json(["ok": false, "error": "connection_origin_conflict"])); return
            }
            // Tool hooks continue during asynchronous questions. Only the
            // authoritative Desktop stream may resolve a displayed request.
            if event.provider == "codex", let request = codexInteractions[event.sessionID]?.first,
               request.expiresAt > ProcessInfo.processInfo.systemUptime,
               ![.completed, .failed, .sessionEnded].contains(event.kind) {
                event.kind = request.isApproval ? .approvalRequested : .waiting
                event.attentionRequestID = request.id
            } else if event.provider == "codex", event.id?.hasPrefix("desktop-stream:") != true,
                      [.working, .toolStarted, .toolFinished, .toolFailed].contains(event.kind),
                      let attention = attentionIdentity(event.sessionID) {
                event.kind = store.sessions[event.sessionID]?.status == .approval ? .approvalRequested : .waiting
                event.attentionRequestID = attention
            }
            if event.provider.lowercased() == "pi", event.id?.hasPrefix("pi-file:") != true {
                piObserver?.markHookObserved(sessionID: event.sessionID)
            }
            let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let waitingForReply = raw["await_response"] as? Bool == true
            // Observers can identify a request without owning a response channel.
            // Such requests still reveal the common fallback, never action buttons.
            if !waitingForReply, event.id?.hasPrefix("interaction-submitted:") != true,
               event.attentionRequestID == nil, [.waiting, .approvalRequested].contains(event.kind),
               let requestID = event.approvalID {
                event.attentionRequestID = requestID
            }
            // Desktop's follower can report a stale running/waiting snapshot
            // while a PermissionRequest hook owns a live reply channel. It must
            // not remove the buttons or decide that request on the user's behalf.
            let desktopObservation = event.provider == "codex" && event.id?.hasPrefix("desktop-stream:") == true
            let replacesRequest = event.approvalID != nil && event.approvalID != pending[event.sessionID]?.requestID
            let preservesPending = !waitingForReply && pending[event.sessionID] != nil &&
                ![.sessionStarted, .completed, .failed, .sessionEnded].contains(event.kind) &&
                (desktopObservation || !replacesRequest)
            if preservesPending, let request = pending[event.sessionID] {
                event.kind = request.question ? .waiting : .approvalRequested
                event.message = nil
                event.approvalID = request.requestID
            }
            if event.kind == .agentPresence {
                guard !waitingForReply else { reply(json(["ok": false, "error": "invalid_presence"])); return }
                presenceNow = Date()
                let applied = noteConnection(event, at: presenceNow, origin: connectionOrigin)
                receivedCount += 1
                if applied {
                    providerReceipts[event.provider.lowercased()] = presenceNow
                    revision += 1
                    onLayout?()
                }
                reply(json(["ok": true, "disposition": applied ? "applied" : "duplicate"]))
                return
            }
            if !waitingForReply, event.kind == .usageUpdated, event.usage?.requestID != nil {
                usage.commit(event) { [weak self] saved in
                    guard let self else { return }
                    reply(self.json(["ok": saved, "disposition": saved ? "usage_committed" : "usage_not_saved"]))
                }
                return
            }
            let previous = store.sessions[event.sessionID]
            if waitingForReply {
                let rid = raw["request_id"] as? String ?? ""
                let timeout = raw["response_timeout"] as? Double ?? 60
                guard [.approvalRequested, .waiting].contains(event.kind),
                      !rid.isEmpty, rid.count <= 160,
                      rid.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0) }),
                      timeout.isFinite, (0.1...110).contains(timeout) else {
                    reply(json(["ok": false, "decision": "invalid_request", "request_id": rid])); return
                }
                guard pending[event.sessionID] != nil || pending.count < 8 else {
                    reply(json(["ok": false, "decision": "busy", "request_id": rid])); return
                }
            }
            let oldStatus = store.sessions[event.sessionID]?.status
            let oldAttention = attentionIdentity(event.sessionID)
            let previousObservedAttention = observedAttention[event.sessionID]?.id
            var nextStore = store
            let disposition = nextStore.apply(event)
            receivedCount += 1
            guard disposition != .invalid else { reply(json(["ok": false, "error": "session_provider_conflict"])); return }
            if disposition == .applied, codexServiceSessions.hides(event) {
                // Native source classifies the whole session, including a card
                // discovered before provenance arrived. Prompt-only suggestions
                // can instead be a background turn reusing a genuine user task.
                let hasUserTask = event.isInternalSession != true &&
                    (previous?.firstPrompt.map { !CodexServiceSessionFilter.isSuggestionRequest($0) } ?? false)
                if !hasUserTask {
                    dismiss(event.sessionID)
                    activity[event.sessionID] = nil
                    measuredSessionHeights[event.sessionID] = nil
                }
                reply(json(["ok": !waitingForReply, "disposition": "filtered", "decision": "filtered",
                            "request_id": raw["request_id"] as? String ?? ""]))
                return
            }
            if disposition == .applied, sessionFilter.hides(path: event.projectPath ?? previous?.projectPath, firstPrompt: previous?.firstPrompt ?? event.firstPrompt) {
                dismiss(event.sessionID)
                reply(json(["ok": !waitingForReply, "disposition": "filtered", "decision": "filtered", "request_id": raw["request_id"] as? String ?? ""]))
                return
            }
            store = nextStore
            if disposition == .applied {
                usage.record(event)
                if !suppressPresentation, !waitingForReply, !preservesPending,
                   let session = store.sessions[event.sessionID] {
                    history.record(event, session: session)
                }
                if !suppressPresentation {
                    presenceNow = Date()
                    providerReceipts[event.provider.lowercased()] = presenceNow
                    if event.connectionID == nil { legacyProviderReceipts[event.provider] = presenceNow }
                    _ = noteConnection(event, at: presenceNow, origin: connectionOrigin)
                }
                if let item = SessionActivity(event) {
                    var history = activity[event.sessionID] ?? []
                    if history.last?.kind != item.kind || history.last?.tool != item.tool || history.last?.message != item.message {
                        history.append(item)
                        activity[event.sessionID] = Array(history.suffix(12))
                    }
                }
                activity = activity.filter { store.sessions[$0.key] != nil }
            }
            if raw["title"] != nil { appOwnedTitles[event.sessionID] = nil }
            if raw["message"] != nil { appOwnedMessages[event.sessionID] = nil }
            let supersedesDecision: Set<AgentEventKind> = [.sessionStarted, .working, .toolStarted, .toolFinished, .toolFailed, .waiting, .approvalRequested, .completed, .failed, .sessionEnded]
            if disposition == .applied && !preservesPending && supersedesDecision.contains(event.kind) { cancelRequest(event.sessionID) }
            if waitingForReply && disposition == .applied && [.approval, .waiting].contains(store.sessions[event.sessionID]?.status ?? .idle), let rid = raw["request_id"] as? String, !rid.isEmpty, rid.count <= 160 {
                guard pending.count < 8 else { reply(json(["ok": false, "decision": "busy", "request_id": rid])); return }
                let requestedTimeout = raw["response_timeout"] as? Double ?? 60
                guard requestedTimeout.isFinite, (0.1...110).contains(requestedTimeout) else { reply(json(["ok": false, "decision": "invalid_timeout", "request_id": rid])); return }
                pending[event.sessionID] = PendingRequest(expiresAt: ProcessInfo.processInfo.systemUptime + requestedTimeout, sessionID: event.sessionID, requestID: rid, message: raw["message"] as? String ?? raw["prompt"] as? String ?? "Агент ожидает ответа", messageIsAppOwned: raw["message"] == nil && raw["prompt"] == nil, question: raw["question"] as? Bool == true, receivedAt: Date(), reply: reply)
                if showingHistory { activeFilter = "Внимание" }
            } else { reply(json(["ok": true, "disposition": String(describing: disposition)])) }
            if disposition == .applied, let status = store.sessions[event.sessionID]?.status, ![.approval, .waiting].contains(status) { cancelRequest(event.sessionID) }
            if disposition == .applied { presentationPolicy?.noteActivity() }
            let newStatus = store.sessions[event.sessionID]?.status
            if disposition == .applied {
                if let id = event.attentionRequestID {
                    observedAttention[event.sessionID] = (id, ProcessInfo.processInfo.systemUptime)
                } else if event.id?.hasPrefix("desktop-stream:") == true ||
                            (event.provider != "codex" && event.kind == .working) ||
                            [.sessionStarted, .completed, .failed, .sessionEnded].contains(event.kind) {
                    observedAttention[event.sessionID] = nil
                }
                let newAttention = attentionIdentity(event.sessionID)
                if !suppressPresentation, let status = newStatus,
                   oldStatus != newStatus || oldAttention != newAttention || event.attentionRequestID != previousObservedAttention {
                    reminders.update(id: event.sessionID, status: status, now: ProcessInfo.processInfo.systemUptime,
                        delay: defaults.double(forKey: "followupMinutes") * 60, includeCompleted: defaults.bool(forKey: "followupCompleted"))
                    let repeatedObservation = event.attentionRequestID != nil && event.attentionRequestID == previousObservedAttention
                    let needsAnswer = newAttention != nil && !repeatedObservation && defaults.bool(forKey: "attentionReveal")
                    let completed = status == .completed && oldStatus != status && defaults.bool(forKey: "completionReveal")
                    if (needsAnswer || completed), !quiet, defaults.bool(forKey: "autoExpand"),
                       presentationPolicy?.canAutomaticallyReveal(for: store.sessions[event.sessionID]) ?? true {
                        if needsAnswer { showAgents = false; if showingHistory { activeFilter = "Внимание" } }
                        reveal(reason: needsAnswer ? "response-needed" : "completed")
                    }
                }
                if oldAttention != nil, newAttention == nil { resumeAutoDismiss() }
            }
            if disposition == .applied, let status = newStatus,
               let cue = sessionSounds.consume(event, status: status, restoring: suppressPresentation) {
                soundPlayer.play(cue: cue, sessionID: event.sessionID,
                    enabled: defaults.bool(forKey: "sound"), quiet: quiet,
                    volume: defaults.double(forKey: "soundVolume"),
                    workingEnabled: defaults.bool(forKey: "soundWorking"))
            }
            revision += 1
            onLayout?()
        } catch { reply(json(["ok": false, "error": "invalid_event", "message": L10n.eventError(error)])) }
    }

    private func connectionOrigin(for event: AgentEvent, from source: AgentConnection.Origin) -> AgentConnection.Origin? {
        guard let id = event.connectionID else {
            // SSH events need a profile identity; otherwise they could mutate a
            // local legacy session or lend remote presence to a local app.
            if source.isRemote { return nil }
            return source
        }
        let configurations = remoteConnections.agentConfigurations.filter { $0.provider == event.provider && $0.connectionID == id }
        guard configurations.count <= 1 else { return nil }
        let owners = Set(configurations.map(\.connectorID))
        switch source {
        case .local:
            guard owners.isEmpty else { return nil }
        case .remoteUnmanaged:
            guard owners.isEmpty else { return nil }
        case .remote(let connectorID):
            guard remoteConnections.connections.contains(where: { $0.id == connectorID }),
                  owners.isEmpty || owners == [connectorID] else { return nil }
        case .unknown:
            guard owners.count <= 1 else { return nil }
        }
        if let previous = connectionReceipts[event.provider + "/" + id], previous.origin != .unknown {
            guard previous.origin == source else { return nil }
        }
        return source
    }

    private func noteConnection(_ event: AgentEvent, at receivedAt: Date, origin: AgentConnection.Origin) -> Bool {
        guard let connectionID = event.connectionID else { return false }
        let provider = event.provider.lowercased()
        let key = provider + "/" + connectionID
        if let previous = connectionReceipts[key] {
            guard event.timestamp >= previous.eventAt,
                  event.id == nil || event.id != previous.eventID else { return false }
        }
        if connectionReceipts[key] == nil, connectionReceipts.count >= 1024,
           let oldest = connectionReceipts.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key {
            connectionReceipts.removeValue(forKey: oldest)
        }
        let name = event.connectionName?.trimmingCharacters(in: .whitespacesAndNewlines)
        connectionReceipts[key] = AgentConnection.Observation(provider: provider, connectionID: connectionID,
            name: name.flatMap { $0.isEmpty ? nil : $0 } ?? connectionReceipts[key]?.name ?? provider, lastSeen: receivedAt,
            eventAt: event.timestamp, eventID: event.id, origin: origin)
        return true
    }

    func tick(at monotonicNow: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        var changed = false
        let visibleBefore = sessions.map { $0.id }
        let now = Date()
        let currentAgents = AgentConnection.project(detected: detectedHarnesses, sessions: store.orderedSessions,
            receipts: legacyProviderReceipts, running: runningAgentProviders, now: now, connections: connectionReceipts,
            configurations: remoteConnections.agentConfigurations(for: connectionReceipts))
        if currentAgents != agents { presenceNow = now }
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let foreground = Set(sessions.filter { $0.terminalBundleID != nil && $0.terminalBundleID == frontBundle }.map(\.id))
        let due = reminders.due(now: monotonicNow, states: Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.status) }), foregroundIDs: defaults.bool(forKey: "suppressWhenTargetAppFrontmost") ? foreground : [])
        let eligibleReminder = due.contains { id in
            guard let session = store.sessions[id] else { return false }
            let enabled = session.status == .completed
                ? defaults.bool(forKey: "followupCompleted") && defaults.bool(forKey: "completionReveal")
                : defaults.bool(forKey: "attentionReveal")
            let actionable = session.status == .completed || attentionIdentity(id, at: monotonicNow) != nil
            return enabled && actionable && (presentationPolicy?.canAutomaticallyReveal(for: session) ?? true)
        }
        if !quiet && !expanded && defaults.bool(forKey: "autoExpand") && defaults.double(forKey: "followupMinutes") > 0 && eligibleReminder { presentationPolicy?.noteActivity(); reveal(reason: "reminder") }
        for (id, request) in pending where monotonicNow >= request.expiresAt {
            request.reply(json(["ok": false, "decision": "timeout", "request_id": request.requestID]))
            pending.removeValue(forKey: id)
            changed = true
        }
        // Retain identity after its freshness lease so a delayed heartbeat of
        // the same unresolved question cannot become a new reveal. Eligibility
        // still expires after 45 s; terminal events and removal clear identity.
        observedAttention = observedAttention.filter { store.sessions[$0.key] != nil }
        if changed { resumeAutoDismiss() }
        let timeout = defaults.integer(forKey: "idleMinutes")
        // A mutating call on @Published sends objectWillChange even if the
        // reducer leaves every session untouched. Publish actual changes only.
        var nextStore = store
        let expired = timeout > 0 ? nextStore.expireStaleSessions(now: now, timeout: Double(timeout) * 60) : []
        let pruned = nextStore.pruneSessions(now: now, retention: 24 * 60 * 60)
        if !expired.isEmpty || !pruned.isEmpty {
            store = nextStore
            for id in expired { cancelRequest(id) }
        }
        if let selectedID, !sessions.contains(where: { $0.id == selectedID }) { self.selectedID = nil; changed = true }
        if changed || visibleBefore != sessions.map({ $0.id }) { revision += 1; onLayout?() }
    }

    private func refreshAgentPresence() {
        let applications = NSWorkspace.shared.runningApplications
        let running = AgentConnection.runningProviders(detected: detectedHarnesses,
            applicationPaths: Set(applications.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path }),
            bundleIdentifiers: Set(applications.compactMap(\.bundleIdentifier)))
        if running != runningAgentProviders { runningAgentProviders = running; onLayout?() }
    }

    func respond(_ id: String, expectedToken: String, decision: String, answer: String? = nil) {
        guard let request = pending[id], request.token == expectedToken else { return }
        guard ProcessInfo.processInfo.systemUptime < request.expiresAt else { cancelRequest(id); return }
        guard [.approval, .waiting].contains(store.sessions[id]?.status ?? .idle) else { cancelRequest(id); return }
        guard ["allow", "deny", "answer"].contains(decision) else { return }
        pending.removeValue(forKey: id)
        var response: [String: Any] = ["ok": true, "decision": decision, "request_id": request.requestID]
        if let answer { response["answer"] = answer }
        request.reply(json(response))
        observedAttention[id] = nil
        let messageKey = decision == "deny" ? "Вы отклонили действие" : decision == "answer" ? "Вы выбрали ответ. Ожидаем событие агента." : "Вы разрешили этот запрос. Ожидаем событие агента."
        inject(["event": "waiting", "session_id": id, "provider": store.sessions[id]?.provider ?? "custom",
                "id": "interaction-submitted:\(request.token)", "message": messageKey], appOwnedMessageKey: messageKey)
        resumeAutoDismiss()
    }
    func interactions(for id: String) -> [AgentInteraction] {
        // A live hook owns its reply channel; do not show a second set of
        // Desktop controls for the same permission request.
        if let request = pending[id] {
            let message = request.messageIsAppOwned ? L10n.tr(request.message) : request.message
            return [AgentInteraction(id: request.token, sessionID: id, detail: request.question ? "" : message,
                questions: request.question ? [.init(id: "answer", title: message, options: [], optionDescriptions: [], secret: false)] : [],
                actions: request.question ? [.init(id: "deny", label: "interaction.deny", destructive: true)] : [.init(id: "allow", label: "interaction.allowOnce", destructive: false),
                    .init(id: "deny", label: "interaction.deny", destructive: true)], expiresAt: request.expiresAt)]
        }
        return codexInteractions[id]?.map(\.presentation) ?? []
    }

    func respondToInteraction(_ request: AgentInteraction, action: String? = nil, answers: [String: String] = [:]) {
        guard interactions(for: request.sessionID).contains(request),
              request.expiresAt > ProcessInfo.processInfo.systemUptime,
              request.actions.contains(where: { $0.id == action }) || (action == nil && request.accepts(answers: answers)) else { return }
        if let hook = pending[request.sessionID], hook.token == request.id {
            respond(request.sessionID, expectedToken: hook.token,
                decision: action ?? "answer", answer: answers["answer"])
        } else if let native = codexInteractions[request.sessionID]?.first(where: { $0.id == request.id }) {
            respondToCodex(native, action: action, answers: answers)
        }
    }

    func receiveCodexInteractions(_ id: String, requests: [CodexInteraction]) {
        guard defaults.bool(forKey: "codexAutoDetect") else { return }
        let previous = codexInteractions[id] ?? []
        guard previous != requests else { return }
        codexInteractions[id] = requests.isEmpty ? nil : requests
        let active = Set(codexInteractions.values.flatMap { $0.map(\.id) })
        interactionErrors.formIntersection(active)
        if let request = requests.first, let session = store.sessions[id], !sessionFilter.hides(path: session.projectPath, firstPrompt: session.firstPrompt) {
            inject(["event": request.isApproval ? "approval.request" : "agent.waiting", "provider": "codex",
                "session_id": id, "attention_request_id": request.id])
            selectedID = id
            showAgents = false
        }
        revision += 1
        onLayout?()
        if requests.isEmpty { resumeAutoDismiss() }
    }
    func respondToCodex(_ request: CodexInteraction, action: String? = nil, answers: [String: String] = [:]) {
        guard codexInteractions[request.sessionID]?.contains(request) == true,
              request.expiresAt > ProcessInfo.processInfo.systemUptime,
              !interactionSubmitting.contains(request.id), !interactionErrors.contains(request.id) else { return }
        interactionSubmitting.insert(request.id)
        let completion: (Bool) -> Void = { [weak self] success in
            guard let self else { return }
            self.interactionSubmitting.remove(request.id)
            if !success, self.codexInteractions[request.sessionID]?.contains(where: { $0.id == request.id }) == true {
                self.interactionErrors.insert(request.id)
            }
        }
        if let codexResponder { codexResponder(request, action, answers, completion) }
        else if let codexObserver { codexObserver.respond(request, action: action, answers: answers, completion: completion) }
        else { completion(false) }
    }
    func cancelRequest(_ id: String) {
        if let p = pending.removeValue(forKey: id) { p.reply(json(["ok": false, "decision": "cancelled", "request_id": p.requestID])) }
    }
    func attentionIdentity(_ id: String, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> String? {
        if let request = codexInteractions[id]?.first, now < request.expiresAt { return request.id }
        if let request = pending[id], now < request.expiresAt { return "reply:\(request.requestID)" }
        guard let request = observedAttention[id], (0..<45).contains(now - request.seenAt),
              let status = store.sessions[id]?.status, [.waiting, .approval].contains(status) else { return nil }
        return request.id
    }
    private func resumeAutoDismiss() {
        guard expanded, expansionOrigin == .automatic, !pointerInside,
              pending.isEmpty, codexInteractions.isEmpty, !sessions.contains(where: { attentionIdentity($0.id) != nil }) else { return }
        reveal()
    }
    func dismiss(_ id: String) { dismissSessions([id]) }
    private func dismissSessions(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            reminders.cancel(id)
            cancelRequest(id)
            codexInteractions[id] = nil
            observedAttention[id] = nil
            store.removeSession(id: id)
            appOwnedTitles[id] = nil
            appOwnedMessages[id] = nil
            measuredSessionHeights[id] = nil
            if selectedID == id { selectedID = nil }
        }
        revision += 1
        onLayout?()
    }
    func reconcileFilters() {
        for session in store.orderedSessions where sessionFilter.hides(path: session.projectPath, firstPrompt: session.firstPrompt) {
            dismiss(session.id)
        }
    }
    func clearFinished() {
        let ids = sessions.filter { [.completed, .failed, .ended].contains($0.status) }.map(\.id)
        guard !ids.isEmpty else { return }
        // Clear is a deliberate interaction with an open panel. Preserve that
        // ownership even when the last session disappears in session-only mode.
        if expanded { setExpanded(true, origin: .manual) }
        dismissSessions(ids)
    }
    func inject(_ object: [String: Any], appOwnedTitleKey: String? = nil, appOwnedMessageKey: String? = nil) {
        receive(json(object), reply: { _ in })
        if let id = object["session_id"] as? String {
            if let appOwnedTitleKey { appOwnedTitles[id] = appOwnedTitleKey }
            if let appOwnedMessageKey { appOwnedMessages[id] = appOwnedMessageKey }
        }
    }
    func json(_ object: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8) }
    func setExpanded(_ value: Bool, origin: IslandExpansionOrigin = .manual, reason: String? = nil) {
        cancelExpansionTimer()
        cancelRevealTimer()
        if value { expansionOrigin = origin }
        if value && !expanded && (!pending.isEmpty || !codexInteractions.isEmpty) { showAgents = false }
        guard expanded != value else { presentationPolicy?.expansionChanged(value, origin: origin); return }
        if !value {
            let overPill = compactHoverRegion?.contains(hoverLocation()) ?? pointerInside
            hoverCooldownUntil = overPill ? ProcessInfo.processInfo.systemUptime + 0.6 : 0
        }
        expansionHistory.append(["time": Date().timeIntervalSince1970, "expanded": value,
                                 "origin": String(describing: origin), "reason": reason ?? String(describing: origin)])
        expansionHistory = Array(expansionHistory.suffix(24))
        // AppKit owns the outer geometry. Do not run a second SwiftUI layout
        // transition while the hosting view is being resized by its window.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { expanded = value }
        if origin != .automatic {
            soundPlayer.play(cue: value ? .expand : .collapse, sessionID: "island-ui",
                enabled: defaults.bool(forKey: "sound"), quiet: quiet,
                volume: defaults.double(forKey: "soundVolume"))
        }
        presentationPolicy?.expansionChanged(value, origin: origin)
        onLayout?()
        if value && origin == .manual { focusPanel?() }
    }
    private func cancelExpansionTimer() {
        expansionGeneration &+= 1
        expansionTimer?.invalidate()
        expansionTimer = nil
        hoverIntent = nil
    }
    private func cancelRevealTimer() {
        revealGeneration &+= 1
        revealTimer?.invalidate()
        revealTimer = nil
    }
    func reveal(reason: String = "response-needed") {
        if expanded, expansionOrigin != .automatic { return }
        setExpanded(true, origin: .automatic, reason: reason)
        guard pending.isEmpty, codexInteractions.isEmpty else { return }
        let generation = revealGeneration
        revealTimer = Timer.scheduledTimer(withTimeInterval: max(2, defaults.double(forKey: "revealDwell")), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.revealGeneration == generation, self.expanded,
                      !self.pointerInside, self.pending.isEmpty, self.codexInteractions.isEmpty,
                      !self.defaults.bool(forKey: "keepOpen") else { return }
                self.setExpanded(false, origin: .automatic, reason: "dwell-expired")
            }
        }
    }
    func hover(_ inside: Bool) {
        let inside = inside && containsHoverLocation(hoverLocation())
        guard pointerInside != inside else { return }
        pointerInside = inside
        cancelExpansionTimer()
        if inside && !showHover { return }
        let generation = expansionGeneration
        if inside {
            guard !expanded else { return }
            guard ProcessInfo.processInfo.systemUptime >= hoverCooldownUntil else { return }
            hoverIntent = HoverIntent(location: hoverLocation(), at: ProcessInfo.processInfo.systemUptime)
            let timer = Timer(timeInterval: HoverIntent.sampleInterval, repeats: true) { [weak self] timer in
                Task { @MainActor in
                    guard let self, self.expansionGeneration == generation else { timer.invalidate(); return }
                    guard self.showHover, self.pointerInside, !self.expanded else { self.cancelExpansionTimer(); return }
                    let location = self.hoverLocation()
                    guard self.containsHoverLocation(location) else { self.hover(false); return }
                    if self.hoverIntent?.sample(location: location, at: ProcessInfo.processInfo.systemUptime,
                                                delay: self.defaults.double(forKey: "hoverDelay")) == true {
                        self.setExpanded(true, origin: .hover)
                    }
                }
            }
            expansionTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else if canCollapseAfterPointerLeave {
            expansionTimer = Timer.scheduledTimer(withTimeInterval: IslandTiming.hoverExit, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.expansionGeneration == generation,
                          self.canCollapseAfterPointerLeave else { return }
                    self.setExpanded(false, origin: self.expansionOrigin == .automatic ? .automatic : .hover)
                }
            }
        }
    }
    private func containsHoverLocation(_ location: CGPoint) -> Bool {
        hoverHitTest?(location) ?? hoverRegion?.contains(location) ?? true
    }
    func hoverMovement(to location: CGPoint) {
        guard pointerInside, !expanded else { return }
        guard containsHoverLocation(location) else { hover(false); return }
        // Observe motion between timer ticks as well, so crossing and returning
        // within a sample interval cannot count as a stationary pause.
        _ = hoverIntent?.sample(location: location, at: ProcessInfo.processInfo.systemUptime,
                                delay: defaults.double(forKey: "hoverDelay"))
    }
    private var canCollapseAfterPointerLeave: Bool {
        presentationPolicy?.canCollapseOnMouseLeave ??
            (expanded && !pointerInside && pending.isEmpty && codexInteractions.isEmpty && !defaults.bool(forKey: "keepOpen"))
    }
    func activateSession(_ session: AgentSession) {
        if defaults.bool(forKey: "disableClickJump") {
            selectSession(selectedID == session.id ? nil : session.id)
        } else { jump(session) }
    }
    func jump(_ session: AgentSession) {
        guard !defaults.bool(forKey: "disableClickJump") else { return }
        navigationGeneration += 1
        let generation = navigationGeneration
        navigationNoticeTimer?.invalidate(); navigationNoticeTimer = nil
        navigationErrorID = nil
        navigationNoticeKey = nil
        if isRemoteSession(session) {
            showNavigationNotice(session.id, key: "session.remote", generation: generation)
            return
        }
        guard let destination = SessionDestination.resolve(session) else {
            showNavigationNotice(session.id, key: "session.noLocalTarget", generation: generation)
            return
        }
        sessionNavigator.open(destination) { [weak self] success in
            guard let self, self.navigationGeneration == generation else { return }
            if success {
                self.reminders.cancel(session.id)
            } else {
                self.showNavigationNotice(session.id, key: "session.openFailed", generation: generation)
            }
        }
    }
    func isRemoteSession(_ session: AgentSession) -> Bool {
        guard let id = session.connectionID else { return false }
        if connectionReceipts[session.provider + "/" + id]?.origin.isRemote == true { return true }
        return remoteConnections.agentConfigurations.contains { $0.provider == session.provider && $0.connectionID == id }
    }
    private func showNavigationNotice(_ id: String, key: String, generation: Int) {
        navigationNoticeTimer?.invalidate()
        navigationErrorID = id; navigationNoticeKey = key
        navigationNoticeTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.navigationGeneration == generation else { return }
                self.navigationErrorID = nil; self.navigationNoticeKey = nil
                self.navigationNoticeTimer = nil
                self.onLayout?()
            }
        }
        onLayout?()
    }
    func selectSession(_ id: String?) {
        presentationPolicy?.noteActivity()
        if expanded {
            expansionOrigin = .manual
            cancelRevealTimer()
            presentationPolicy?.expansionChanged(true, origin: .manual)
        }
        selectedID = id
        if let id { reminders.cancel(id) }
        onLayout?()
    }
    func moveSelection(_ delta: Int) {
        guard !showAgents, !showingHistory else { return }
        let items = filtered
        guard !items.isEmpty else { return }
        let index = selectedID.flatMap { id in items.firstIndex { $0.id == id } } ?? (delta > 0 ? -1 : items.count)
        selectSession(items[min(items.count - 1, max(0, index + delta))].id)
    }
    /// Task shortcuts only act on the currently visible list. A remembered
    /// selection from another tab or filter must never launch a hidden task.
    func handlePanelKey(_ keyCode: UInt16, characters: String?) -> Bool {
        guard expanded else { return false }
        if keyCode == 53 { setExpanded(false); return true }
        guard !showAgents, !showingHistory else { return false }
        let items = filtered
        switch keyCode {
        case 125, 126:
            guard !items.isEmpty else { return false }
            moveSelection(keyCode == 125 ? 1 : -1)
        case 36, 76:
            guard !defaults.bool(forKey: "disableClickJump"),
                  let id = selectedID, let session = items.first(where: { $0.id == id }) else { return false }
            jump(session)
        default:
            guard let characters, let number = Int(characters), (1...9).contains(number),
                  items.indices.contains(number - 1) else { return false }
            selectSession(items[number - 1].id)
        }
        return true
    }

    func shutdown() {
        history.shutdown()
        usage.shutdown(); quota.stop()
        remoteConnections.disconnectAll(); codexObserver?.stop(); piObserver?.stop(); timer?.invalidate()
        for observer in presenceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        presenceObservers.removeAll()
        cancelExpansionTimer(); cancelRevealTimer()
        navigationNoticeTimer?.invalidate(); navigationNoticeTimer = nil
        for id in Array(pending.keys) { cancelRequest(id) }
        server?.stop()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: AppModel
    var panel: IslandPanel!
    var statusItem: NSStatusItem!
    private(set) var statusIconStyle: CompanionStyle?
    var settingsWindow: NSWindow?
    var settingsPresented = false
    private var settingsTab = 0
    private var settingsProvider = "codex"
    var hotKey: EventHotKeyRef?
    var eventHandler: EventHandlerRef?
    var panelKeyMonitor: Any?
    var observers: [NSObjectProtocol] = []
    private var frameAnimation: IslandWindowAnimator?
    // Populated only by the development QA exporter; no production logging.
    var onAnimationFrame: ((IslandWindowAnimator.FrameTiming) -> Void)?
    private var targetPanelFrame: NSRect?
    private var targetScreenID: String?
    private var targetBelowMenu = false
    private var targetExpanded = false
    private var shortcutConfiguration: String?

    init(model: AppModel? = nil) {
        self.model = model ?? AppModel(defaults: CommandLine.arguments.contains(where: { ["--qa-interactions", "--qa-showcase-only"].contains($0) })
            ? UserDefaults(suiteName: "si-notch.interaction-qa.\(UUID().uuidString)")! : .standard)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isMovable = false; panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.animationBehavior = .none
        let host = TrackingHost(rootView: IslandView(model: model))
        // SwiftUI content must not impose a new window minimum/ideal size midway
        // through the AppKit frame animation.
        host.sizingOptions = []
        host.onHover = { [weak model] inside in model?.hover(inside) }
        host.onPointerMove = { [weak model] location in model?.hoverMovement(to: location) }
        model.hoverHitTest = { [weak host] location in host?.containsHoverPoint(location) ?? false }
        panel.contentView = host
        model.onLayout = { [weak self] in
            self?.model.presentationPolicy?.refresh()
            self?.layout()
        }
        model.openSettings = { [weak self] in self?.showSettings() }
        model.openUsage = { [weak self] id in
            guard let self else { return }
            self.model.usage.selectedID = id
            self.showSettings(); self.setSettingsContent(tab: 8)
        }
        model.openIntegrations = { [weak self] in
            guard let self else { return }
            self.showSettings()
            self.setSettingsContent(tab: 1, provider: "codex")
        }
        model.openRemoteConnections = { [weak self] in
            self?.showSettings()
            self?.setSettingsContent(tab: 10, provider: "hermes")
        }
        model.closeSettings = { [weak self] in self?.settingsWindow?.close() }
        model.focusPanel = { [weak self] in self?.panel.makeKey() }
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.toolTip = "si-notch"
        }
        refreshStatusIcon()
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshStatusIcon() }
            })
        rebuildMenu()
        layout()
        if let i = CommandLine.arguments.firstIndex(of: "--qa-export"), CommandLine.arguments.indices.contains(i + 1) {
            panel.orderFrontRegardless()
            QAExporter.run(delegate: self, directory: URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true))
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--qa-interactions"), CommandLine.arguments.indices.contains(i + 2) {
            QAInteractionSession.start(delegate: self, socket: CommandLine.arguments[i + 1], sessionID: CommandLine.arguments[i + 2])
            return
        }
        model.presentationPolicy = PresentationPolicy(defaults: model.defaults,
            state: { [weak self] in
                guard let self else { return IslandPresentationState() }
                var state = self.model.presentationState
                state.isSettingsVisible = self.settingsPresented
                return state
            }, panel: { [weak self] in self?.panel },
            onVisibilityChange: { [weak self] in self?.applyIslandVisibility($0) },
            onAutoDismiss: { [weak model] in model?.setExpanded(false, origin: .automatic) },
            fullScreen: { [weak self] in FullScreenDetector.isFullScreen(on: self?.selectedScreen()) },
            onFullScreenChange: { [weak self] in self?.fullScreenChanged($0) })
        model.presentationPolicy?.start()
        model.start()
        UpdateBackgroundChecker.shared.start()
        installShortcut()
        panelKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel, self.model.expanded,
                  !(self.panel.firstResponder is NSTextView),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            return self.model.handlePanelKey(event.keyCode, characters: event.charactersIgnoringModifiers) ? nil : event
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.layout(allowAnimation: false) } })
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.layout(allowAnimation: false) }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layout(allowAnimation: false) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in
            self?.model.reconcileFilters(); self?.model.refreshCodexObserver(); self?.layout(); self?.rebuildMenu(); self?.installMainMenu(); self?.installShortcut()
            self?.settingsWindow?.title = L10n.tr("si-notch · Настройки")
            self?.statusItem.button?.toolTip = "si-notch"
        } })
        if CommandLine.arguments.contains("--settings") { showSettings() }
        else if !model.defaults.bool(forKey: "agentDiscoveryPresented") {
            model.defaults.set(true, forKey: "agentDiscoveryPresented")
            model.openIntegrations?()
        }
    }
    func applicationWillTerminate(_ notification: Notification) { frameAnimation?.stop(); model.presentationPolicy?.stop(); model.shutdown(); if let panelKeyMonitor { NSEvent.removeMonitor(panelKeyMonitor) }; if let hotKey { UnregisterEventHotKey(hotKey) }; if let eventHandler { RemoveEventHandler(eventHandler) } }
    func selectedScreen() -> NSScreen? {
        let preferred = model.defaults.string(forKey: "screenID")
        if let preferred, let screen = NSScreen.screens.first(where: { screenID($0) == preferred }) { return screen }
        if model.defaults.bool(forKey: "followFocus"), let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) { return screen }
        return NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first
    }
    func layout(allowAnimation: Bool = true) {
        guard let screen = selectedScreen() else { return }
        let geometry = NotchGeometry(screenFrame: screen.frame, topInset: screen.safeAreaInsets.top,
                                     auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
                                     auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
                                     backingScaleFactor: screen.backingScaleFactor)
        let placement = IslandPlacement(geometry: geometry,
            belowMenu: model.defaults.string(forKey: "displayMode") == "belowMenu",
            menuBarHeight: max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY))
        if model.floatingSurface != placement.isFloating { model.floatingSurface = placement.isFloating }
        if model.trailingSurface != placement.isTrailing { model.trailingSurface = placement.isTrailing }
        if model.cameraWidth != placement.cameraWidth { model.cameraWidth = placement.cameraWidth }
        if model.headerHeight != placement.headerHeight { model.headerHeight = placement.headerHeight }
        panel.hasShadow = placement.isFloating
        let width = min(screen.frame.width - 24, max(360, model.defaults.double(forKey: "panelWidth")))
        if model.expandedPanelWidth != width { model.expandedPanelWidth = width }
        let maxHeight = max(345, model.defaults.double(forKey: "panelHeight"))
        let height = model.panelHeight(limitedTo: min(screen.frame.height - 80, maxHeight))
        if model.expandedPanelHeight != height { model.expandedPanelHeight = height }
        let menuMode = placement.isFloating
        let compactFrame = placement.compactFrame(leftWidth: model.compactWingWidth, rightWidth: model.compactStatusWidth)
        let rect = model.expanded
            ? placement.expandedFrame(width: width, height: height)
            : compactFrame
        // Compact activation always follows the destination immediately. An
        // already open panel may retain an ongoing interaction across a resize.
        model.hoverRegion = rect
        model.compactHoverRegion = compactFrame
        if let host = panel.contentView as? TrackingHost<IslandView> {
            host.hiddenInteractionFrame = placement.fullScreenRevealFrame(
                leftWidth: model.compactWingWidth, rightWidth: model.compactStatusWidth)
            host.allowsHoverDuringDrag = model.expanded
            host.updateInteraction(frame: rect,
                shape: IslandSilhouette(shoulder: model.expanded ? 14 : model.compactShoulderWidth,
                                        bottomRadius: model.expanded ? 24 : (placement.isFloating ? 15 : 13),
                                        floating: placement.isFloating),
                preservingHover: model.expanded && targetExpanded && targetScreenID == screenID(screen) &&
                    targetBelowMenu == menuMode)
        }
        let currentScreenID = screenID(screen)
        let animate = allowAnimation && targetPanelFrame != nil && panel.isVisible &&
            targetScreenID == currentScreenID && targetBelowMenu == menuMode &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Events and preferences may request the same destination while the
        // visible window is still travelling. Do not restart that animation.
        if targetPanelFrame == rect && animate && (panel.frame == rect || frameAnimation?.isRunning == true) { return }
        let velocity = frameAnimation?.isRunning == true ? frameAnimation!.velocity : .init()
        let transition: IslandFrameMotion.Transition
        if model.expanded != targetExpanded { transition = model.expanded ? .expand : .collapse }
        else if let animation = frameAnimation, animation.isRunning { transition = animation.transition }
        else { transition = .resize }
        frameAnimation?.stop()
        frameAnimation = nil
        targetPanelFrame = rect
        targetScreenID = currentScreenID
        targetBelowMenu = menuMode
        targetExpanded = model.expanded
        guard panel.frame != rect else { return }
        // A system reposition is not an animation origin. Reattach first so the
        // next hover expands down from the screen edge rather than from a gap.
        guard animate, abs(panel.frame.maxY - rect.maxY) < 0.5 else {
            panel.setFrame(rect, display: true, animate: false)
            return
        }
        // Retain an explicitly cancellable animation so reversal, display changes,
        // and Reduce Motion start from the real current frame without a late snap.
        let animation = IslandWindowAnimator(window: panel, destination: rect,
            transition: transition, framesPerSecond: screen.maximumFramesPerSecond,
            initialVelocity: velocity, onFrame: onAnimationFrame)
        frameAnimation = animation
        animation.start()
    }
    func applyIslandVisibility(_ visible: Bool) {
        let host = panel.contentView as? TrackingHost<IslandView>
        host?.tracksHiddenHover = model.presentationPolicy?.currentDecision?.hiddenReason == .fullScreen
        if visible {
            let reveal = !panel.isVisible && model.presentationPolicy?.isFullScreen == true && model.expanded
            if model.presentationPolicy?.isFullScreen == true && model.expanded {
                let playerLevel = FullScreenDetector.coveringWindowLevel(on: selectedScreen()) ?? 0
                panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.statusBar.rawValue,
                    min(Int(CGShieldingWindowLevel()) + 1, playerLevel + 1)))
            }
            if !reveal { layout(allowAnimation: false) }
            panel.orderFrontRegardless()
            if reveal { layout() }
        } else {
            panel.orderOut(nil)
            panel.level = .statusBar
            model.hover(false)
            if model.presentationPolicy?.currentDecision?.hiddenReason == .noSessions {
                model.setExpanded(false, origin: .automatic)
            }
            layout(allowAnimation: false)
        }
    }
    func fullScreenChanged(_ active: Bool) {
        // Entering a fullscreen Space must also dismiss an already-open panel.
        // A pointer parked at the camera must leave and return before revealing.
        model.hover(false)
        model.setExpanded(false, origin: .automatic)
        (panel.contentView as? TrackingHost<IslandView>)?.resetHover(requiringExit: active)
    }
    func screenID(_ s: NSScreen) -> String { String(describing: s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "main") }
    func refreshStatusIcon() {
        let style = CompanionStyle(rawValue: model.defaults.string(forKey: "companionStyle") ?? "") ?? .robot
        guard let button = statusItem?.button, statusIconStyle != style else { return }
        button.image = StatusBarIcon.make(style: style)
        statusIconStyle = style
    }
    func windowDidMove(_ notification: Notification) {
        guard notification.object as? IslandPanel === panel, let targetPanelFrame,
              abs(panel.frame.maxY - targetPanelFrame.maxY) >= 0.5 else { return }
        // Show Desktop and focus transitions can reposition a nonactivating
        // panel. Keep the top anchor without ordering it above Exposé.
        layout(allowAnimation: false)
    }
    func rebuildMenu() {
        let m = NSMenu()
        m.addItem(withTitle: L10n.tr("Открыть si-notch"), action: #selector(toggleIsland), keyEquivalent: "")
        m.addItem(withTitle: L10n.tr("Настройки…"), action: #selector(showSettings), keyEquivalent: ",")
        m.addItem(withTitle: L10n.tr("settings.usage"), action: #selector(showUsage), keyEquivalent: "")
        let available = model.defaults.string(forKey: "updateAvailableVersion") ?? ""
        m.addItem(withTitle: available.isEmpty ? L10n.tr("updates.menuCheck") : L10n.tr("updates.menuAvailable", available), action: #selector(showUpdates), keyEquivalent: "")
        let plugins = PluginUpdateCatalog.displayed(
            data: model.defaults.data(forKey: "updatePluginCatalog") ?? Data(), availableVersion: available,
            channel: UpdateChannel(rawValue: model.defaults.string(forKey: "updateChannel") ?? "stable") ?? .stable)
        if !plugins.isEmpty {
            let item = m.addItem(withTitle: L10n.tr("updates.plugins.title"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for plugin in plugins {
                let link = submenu.addItem(withTitle: "\(plugin.name) \(plugin.version) · \(L10n.tr(plugin.change.labelKey))",
                                           action: #selector(openPluginInstallation(_:)), keyEquivalent: "")
                link.representedObject = plugin
                link.target = self
            }
            item.submenu = submenu
        }
        m.addItem(.separator())
        m.addItem(withTitle: model.paused ? L10n.tr("Возобновить события") : L10n.tr("Приостановить события"), action: #selector(togglePause), keyEquivalent: "")
        let quiet = m.addItem(withTitle: L10n.tr("Тихий режим"), action: #selector(toggleQuiet), keyEquivalent: "")
        quiet.state = model.quiet ? .on : .off
        m.addItem(withTitle: L10n.tr("Убрать завершённые"), action: #selector(clearFinished), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: L10n.tr("Выйти из si-notch"), action: #selector(quit), keyEquivalent: "q")
        for i in m.items { i.target = self }
        statusItem.menu = m
    }
    @objc func openPluginInstallation(_ sender: NSMenuItem) {
        guard let plugin = sender.representedObject as? PluginUpdate, plugin.isValid else { return }
        NSWorkspace.shared.open(plugin.installURL)
    }
    @objc func showUsage() { model.openUsage?(nil) }
    @objc func showUpdates() {
        showSettings()
        setSettingsContent(tab: 9)
    }
    @objc func toggleIsland() { let hidden = !panel.isVisible; model.presentationPolicy?.noteActivity(); model.setExpanded(hidden || !model.expanded) }
    @objc func togglePause() { model.paused.toggle(); rebuildMenu() }
    @objc func toggleQuiet() { model.defaults.set(!model.quiet, forKey: "quiet"); rebuildMenu() }
    @objc func clearFinished() { model.clearFinished() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func showSettings() {
        settingsPresented = true
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = L10n.tr("si-notch · Настройки"); w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 820, height: 660)
            w.titlebarAppearsTransparent = true
            w.backgroundColor = NSColor(white: 0.12, alpha: 1)
            w.appearance = NSAppearance(named: .darkAqua)
            w.delegate = self
            w.center(); settingsWindow = w
            setSettingsContent()
        } else if settingsWindow?.contentView == nil {
            setSettingsContent()
        }
        model.setExpanded(false, origin: .automatic, reason: "settings-opened")
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        model.presentationPolicy?.refresh(forceVisibilityUpdate: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === settingsWindow else { return }
        settingsPresented = false
        // A retained NSHostingView keeps observing agent events and animating
        // companion previews after its window closes. Recreate it on demand.
        closing.contentView = nil
        model.setExpanded(false, origin: .automatic, reason: "settings-closed")
        model.presentationPolicy?.noteActivity()
        model.presentationPolicy?.refresh(forceVisibilityUpdate: true)
    }
    private func setSettingsContent(tab: Int? = nil, provider: String? = nil) {
        if let tab { settingsTab = tab }
        if let provider { settingsProvider = provider }
        settingsWindow?.contentView = NSHostingView(rootView: SettingsView(model: model,
            tab: settingsTab, selectedProvider: settingsProvider, onSelectionChange: { [weak self] tab, provider in
                self?.settingsTab = tab
                self?.settingsProvider = provider
            }).defaultAppStorage(model.defaults))
    }
    func installMainMenu() {
        let root = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = appMenu.addItem(withTitle: L10n.tr("Настройки…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        let exit = appMenu.addItem(withTitle: L10n.tr("Выйти из si-notch"), action: #selector(quit), keyEquivalent: "q")
        exit.target = self
        appMenuItem.submenu = appMenu
        root.addItem(appMenuItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L10n.tr("Окно"))
        windowMenu.addItem(withTitle: L10n.tr("Закрыть окно"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        root.addItem(windowItem)
        NSApp.mainMenu = root
    }
    func installShortcut() {
        let configuration = "\(model.defaults.bool(forKey: "shortcutEnabled")):\(model.defaults.string(forKey: "shortcutModifier") ?? "ctrlAlt")"
        guard configuration != shortcutConfiguration else { return }
        shortcutConfiguration = configuration
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let eventHandler { RemoveEventHandler(eventHandler); self.eventHandler = nil }
        guard model.defaults.bool(forKey: "shortcutEnabled") else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.toggleIsland() }
            return noErr
        }, 1, &spec, opaque, &eventHandler)
        let modifiers = controlKey | optionKey | (model.defaults.string(forKey: "shortcutModifier") == "ctrlShiftAlt" ? shiftKey : 0)
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(modifiers), EventHotKeyID(signature: 0x53494E43, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { model.settingsError = .shortcut(Int(result)) }
    }
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Layout already bounds the panel to its display. AppKit's usable-area
        // constraint must not move this borderless overlay below the menu bar.
        frameRect
    }
}
final class TrackingHost<Content: View>: NSHostingView<Content> {
    var area: NSTrackingArea?
    var onHover: ((Bool) -> Void)?
    var onPointerMove: ((CGPoint) -> Void)?
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }
    var pointerButtons: () -> Int = { NSEvent.pressedMouseButtons }
    var allowsHoverDuringDrag = false
    var interactionShape: IslandSilhouette?
    private var retainedHoverRegion: (frame: CGRect, shape: IslandSilhouette?)?
    private var lastMotionTime: TimeInterval?
    var interactionFrame: CGRect? {
        didSet { if oldValue != interactionFrame { synchronizeHover() } }
    }
    private var pointerIsInside = false
    var hiddenInteractionFrame: CGRect?
    var tracksHiddenHover = false
    private var requiresReentry = false
    private var localMotionMonitor: Any?
    private var globalMotionMonitor: Any?

    func updateInteraction(frame: CGRect, shape: IslandSilhouette, preservingHover: Bool) {
        if !preservingHover {
            retainedHoverRegion = nil
        } else if pointerIsInside, retainedHoverRegion == nil, let previous = interactionFrame,
                  !shape.contains(pointerLocation(), inScreenFrame: frame) {
            // Content can shrink away from the Clear button or a collapsed card.
            // Keep a bridge through the previously occupied surface until the
            // pointer reaches the new surface or actually leaves the old one.
            retainedHoverRegion = (previous, interactionShape)
        }
        interactionShape = shape
        interactionFrame = frame
        synchronizeHover()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, localMotionMonitor == nil {
            // Both monitors are needed for our own and other apps' windows.
            // Dragging another window through the notch must cancel opening.
            let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            localMotionMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                self?.synchronizeHover(motion: event)
                return event
            }
            globalMotionMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
                self?.synchronizeHover(motion: event)
            }
        } else if window == nil { removeMotionMonitors() }
    }
    private func removeMotionMonitors() {
        if let localMotionMonitor { NSEvent.removeMonitor(localMotionMonitor) }
        if let globalMotionMonitor { NSEvent.removeMonitor(globalMotionMonitor) }
        localMotionMonitor = nil
        globalMotionMonitor = nil
        lastMotionTime = nil
    }
    deinit {
        if let localMotionMonitor { NSEvent.removeMonitor(localMotionMonitor) }
        if let globalMotionMonitor { NSEvent.removeMonitor(globalMotionMonitor) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        if let area { addTrackingArea(area) }
        synchronizeHover()
    }
    func resetHover(requiringExit: Bool) {
        retainedHoverRegion = nil
        requiresReentry = requiringExit && (hiddenInteractionFrame?.contains(pointerLocation()) ?? false)
        pointerIsInside = false
        lastMotionTime = nil
        onHover?(false)
    }
    func containsHoverPoint(_ location: CGPoint) -> Bool {
        guard !requiresReentry, allowsHoverDuringDrag || pointerButtons() == 0 else { return false }
        if let window, window.isVisible, let interactionFrame {
            return contains(location, frame: interactionFrame, shape: interactionShape) ||
                retainedHoverRegion.map { contains(location, frame: $0.frame, shape: $0.shape) } == true
        }
        return tracksHiddenHover && (hiddenInteractionFrame?.contains(location) ?? false)
    }
    private func contains(_ point: CGPoint, frame: CGRect, shape: IslandSilhouette?) -> Bool {
        shape?.contains(point, inScreenFrame: frame) ?? frame.contains(point)
    }
    private func synchronizeHover(motion: NSEvent? = nil) {
        let location = pointerLocation()
        var moved = false
        if let motion, motion.timestamp.isFinite,
           lastMotionTime == nil || motion.timestamp > lastMotionTime! {
            moved = true
            lastMotionTime = motion.timestamp
        }
        if moved, let retained = retainedHoverRegion {
            let reachedNewSurface = interactionFrame.map { contains(location, frame: $0, shape: interactionShape) } == true
            if reachedNewSurface || !contains(location, frame: retained.frame, shape: retained.shape) {
                retainedHoverRegion = nil
            }
        }
        let inside: Bool
        if requiresReentry {
            if hiddenInteractionFrame?.contains(location) != true { requiresReentry = false }
            inside = false
        } else { inside = containsHoverPoint(location) }
        // Resizing/showing a window under a parked pointer is not an entry.
        // A compact target never retains the old expanded interaction region.
        if inside && !pointerIsInside && !moved { return }
        if inside != pointerIsInside {
            pointerIsInside = inside
            if !inside { retainedHoverRegion = nil }
            onHover?(inside)
        }
        if inside, moved { onPointerMove?(location) }
    }
    override func mouseMoved(with event: NSEvent) { synchronizeHover(motion: event) }
    override func mouseEntered(with event: NSEvent) { synchronizeHover() }
    override func mouseExited(with event: NSEvent) { synchronizeHover() }
}
