import Foundation

public enum EventDisposition: String, Equatable, Sendable {
    case applied, duplicate, outOfOrder, ignoredUnknown, invalid
}

/// A synchronous value reducer. Callers own threading and persistence.
public struct SessionStore: Sendable {
    public private(set) var sessions: [String: AgentSession] = [:]
    public let maximumSessions: Int
    public let maximumRememberedEventIDs: Int
    public let maximumTasksPerSession: Int
    public let maximumSubagentsPerSession: Int
    private var rememberedIDs: Set<String> = []
    private var idOrder: [String] = []
    private var explicitlyEndedIDs: Set<String> = []
    private var endedTurnIDs: Set<String> = []

    public var orderedSessions: [AgentSession] {
        sessions.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    public init(maximumSessions: Int = 256, maximumRememberedEventIDs: Int = 4096,
                maximumTasksPerSession: Int = 256, maximumSubagentsPerSession: Int = 256) {
        self.maximumSessions = max(1, maximumSessions)
        self.maximumRememberedEventIDs = max(1, maximumRememberedEventIDs)
        self.maximumTasksPerSession = max(1, maximumTasksPerSession)
        self.maximumSubagentsPerSession = max(1, maximumSubagentsPerSession)
    }

    @discardableResult
    public mutating func apply(_ event: AgentEvent, receivedAt: Date = Date()) -> EventDisposition {
        guard (try? event.validate()) != nil, receivedAt.timeIntervalSince1970.isFinite else { return .invalid }
        guard event.kind != .unknown else { return .ignoredUnknown }
        // Connection announcements have no task lifecycle or history.
        guard event.kind != .agentPresence else { return .applied }
        let dedupeKey = event.id.map { event.provider + "\0" + event.sessionID + "\0" + $0 }
        if let dedupeKey, rememberedIDs.contains(dedupeKey) { return .duplicate }
        if let existing = sessions[event.sessionID] {
            guard existing.provider == event.provider else { return .invalid }
            // An established legacy session is a distinct identity too. A later
            // named event cannot adopt its tasks, history or pending request.
            if let connectionID = event.connectionID, connectionID != existing.connectionID { return .invalid }
            if let sequence = event.sequence, let previous = existing.lastSequence {
                guard sequence > previous else { return .outOfOrder }
            } else if event.timestamp < existing.lastEventAt {
                return .outOfOrder
            }
            // A turn outcome is final. Late callbacks cannot reopen that same
            // Hermes turn or create a new attention request in the app model.
            if existing.provider == "hermes",
               [.completed, .failed].contains(existing.status) || endedTurnIDs.contains(existing.id),
               existing.turnID != nil, event.turnID == existing.turnID,
               [.working, .toolStarted, .waiting, .approvalRequested, .completed, .failed].contains(event.kind) {
                return .outOfOrder
            }
        }
        var session = sessions[event.sessionID] ?? AgentSession(
            id: event.sessionID, provider: event.provider,
            title: event.title ?? Self.defaultTitle(for: event), projectPath: event.projectPath,
            createdAt: event.timestamp, updatedAt: receivedAt)
        if event.kind == .sessionStarted || (event.turnID != nil && event.turnID != session.turnID) {
            endedTurnIDs.remove(session.id)
        }
        if let title = event.title, !title.isEmpty { session.title = title }
        if let connectionID = event.connectionID { session.connectionID = connectionID }
        if let connectionName = event.connectionName { session.connectionName = connectionName }
        if let projectPath = event.projectPath {
            session.projectPath = projectPath
            if event.title == nil, session.title == "Agent session" { session.title = Self.defaultTitle(for: event) }
        }
        if let message = event.message { session.lastMessage = message }
        if let terminalBundleID = event.terminalBundleID { session.terminalBundleID = terminalBundleID }
        if let targetURL = event.targetURL { session.targetURL = targetURL }
        if let modelName = event.modelName {
            if modelName != session.modelName { session.reasoningEffort = nil }
            session.modelName = modelName
        }
        if let reasoningEffort = event.reasoningEffort { session.reasoningEffort = reasoningEffort }
        if let turnID = event.turnID { session.turnID = turnID }
        if session.firstPrompt == nil { session.firstPrompt = event.firstPrompt }
        if let isWorkSession = event.isWorkSession { session.isWorkSession = isWorkSession }
        if let usage = event.usage { session.usage = session.usage?.merging(usage) ?? usage }
        if let task = event.task {
            if task.status == .ended { session.tasks.removeAll { $0.id == task.id } }
            else { Self.upsert(task, in: &session.tasks, limit: maximumTasksPerSession) }
        }
        if var subagent = event.subagent {
            if event.kind == .subagentEnded && subagent.status.isActive { subagent.status = .completed }
            Self.upsert(subagent, in: &session.subagents, limit: maximumSubagentsPerSession)
        }

        if event.kind == .sessionStarted { explicitlyEndedIDs.remove(session.id) }
        if !explicitlyEndedIDs.contains(session.id) || event.kind == .sessionEnded {
            switch event.kind {
            case .sessionStarted:
                session.status = .idle
                session.currentTool = nil
                session.approvalID = nil
            case .working, .toolStarted:
                session.status = .working
                session.currentTool = event.toolName
                session.approvalID = nil
            case .toolFinished, .toolFailed:
                // A late tool completion cannot resurrect a completed turn.
                if session.status.isActive || session.status == .idle {
                    session.status = .working
                }
                if event.toolName == nil || event.toolName == session.currentTool { session.currentTool = nil }
                session.approvalID = nil
            case .waiting:
                session.status = .waiting
                session.currentTool = nil
                session.approvalID = nil
            case .approvalRequested:
                session.status = .approval
                session.currentTool = event.toolName
                session.approvalID = event.approvalID ?? event.id
            case .completed, .failed, .sessionEnded:
                session.status = event.kind == .completed ? .completed : event.kind == .failed ? .failed : .ended
                session.currentTool = nil
                session.approvalID = nil
                if event.kind == .sessionEnded {
                    // Hermes recovery can close one interrupted execution while
                    // its durable session remains available for the next turn.
                    // Finalize hooks omit turn_id and still close the session.
                    if event.provider != "hermes" || event.turnID == nil {
                        explicitlyEndedIDs.insert(session.id)
                        endedTurnIDs.remove(session.id)
                    } else {
                        endedTurnIDs.insert(session.id)
                    }
                }
                // Background children can outlive a completed parent turn.
                if event.kind != .completed {
                    for index in session.subagents.indices where session.subagents[index].status.isActive {
                        session.subagents[index].status = event.kind == .failed ? .failed : .ended
                    }
                }
            case .subagentStarted:
                if session.status == .idle { session.status = .working }
            case .taskUpdated, .subagentEnded, .usageUpdated, .agentPresence, .unknown: break
            }
        }
        session.updatedAt = max(session.updatedAt, receivedAt)
        session.lastEventAt = max(session.lastEventAt, event.timestamp)
        session.lastEventID = event.id
        if let sequence = event.sequence { session.lastSequence = sequence }
        sessions[session.id] = session
        if let dedupeKey { remember(dedupeKey) }
        trimSessions()
        return .applied
    }

    /// Ends silent active/idle sessions. A fresh event can resume an expired session.
    @discardableResult
    public mutating func expireStaleSessions(now: Date = Date(), timeout: TimeInterval = 1800) -> [String] {
        guard timeout.isFinite, timeout >= 0, now.timeIntervalSince1970.isFinite else { return [] }
        var expired: [String] = []
        for id in sessions.keys.sorted() {
            guard var session = sessions[id], Self.hasLiveWork(session),
                  now.timeIntervalSince(session.updatedAt) >= timeout else { continue }
            session.status = .ended
            session.currentTool = nil
            session.approvalID = nil
            for index in session.subagents.indices where session.subagents[index].status.isActive {
                session.subagents[index].status = .ended
            }
            sessions[id] = session
            expired.append(id)
        }
        return expired
    }

    @discardableResult
    public mutating func pruneSessions(now: Date = Date(), retention: TimeInterval = 86400) -> [String] {
        guard retention.isFinite, retention >= 0 else { return [] }
        let removed = sessions.values.filter {
            !Self.hasLiveWork($0) && now.timeIntervalSince($0.updatedAt) >= retention
        }.map(\.id).sorted()
        for id in removed { removeSession(id: id) }
        return removed
    }

    public mutating func removeSession(id: String) {
        sessions.removeValue(forKey: id)
        explicitlyEndedIDs.remove(id)
        endedTurnIDs.remove(id)
    }

    public mutating func clear() {
        sessions.removeAll()
        rememberedIDs.removeAll()
        idOrder.removeAll()
        explicitlyEndedIDs.removeAll()
        endedTurnIDs.removeAll()
    }

    private mutating func remember(_ id: String) {
        rememberedIDs.insert(id)
        idOrder.append(id)
        if idOrder.count > maximumRememberedEventIDs {
            rememberedIDs.remove(idOrder.removeFirst())
        }
    }

    private mutating func trimSessions() {
        while sessions.count > maximumSessions {
            // Evict inactive sessions before live work, then choose oldest deterministically.
            let oldest = sessions.values.sorted {
                let lhsActive = Self.hasLiveWork($0)
                let rhsActive = Self.hasLiveWork($1)
                if lhsActive != rhsActive { return !lhsActive }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                return $0.id < $1.id
            }.first!
            removeSession(id: oldest.id)
        }
    }

    private static func hasLiveWork(_ session: AgentSession) -> Bool {
        session.status.isActive || session.status == .idle || session.subagents.contains { $0.status.isActive }
    }

    private static func upsert<T: Identifiable>(_ item: T, in items: inout [T], limit: Int) where T.ID == String {
        // Keep the most recently updated children when a long-running session reaches its limit.
        if let index = items.firstIndex(where: { $0.id == item.id }) { items.remove(at: index) }
        items.append(item)
        if items.count > limit { items.removeFirst(items.count - limit) }
    }

    private static func defaultTitle(for event: AgentEvent) -> String {
        guard let path = event.projectPath, !path.isEmpty else { return "Agent session" }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? "Agent session" : name
    }
}
