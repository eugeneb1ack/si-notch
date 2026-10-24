import Foundation
import SINotchCore

/// Provider availability is independent of the tasks shown in the island.
struct AgentConnection: Identifiable, Equatable {
    /// Assigned by the receiving endpoint, never by event-supplied display metadata.
    enum Origin: Equatable {
        case unknown, local, remote(UUID)
    }
    struct Observation: Equatable {
        let provider: String
        let connectionID: String
        let name: String
        let lastSeen: Date
        let eventAt: Date
        let eventID: String?
        var origin: Origin = .unknown
        var id: String { provider + "/" + connectionID }
    }
    struct Configuration {
        let connectionID: String
        let name: String
        let connectorID: UUID
        let visible: Bool
        var transportState: RemoteConnectionState? = nil
        var provider: String = "hermes"
        var id: String { provider + "/" + connectionID }
    }
    enum State: String {
        case online, lastSeen, installed, offline
        var label: String {
            switch self {
            case .online: L10n.tr("agents.state.online")
            case .lastSeen: L10n.tr("agents.state.lastSeen")
            case .installed: L10n.tr("agents.state.installed")
            case .offline: L10n.tr("agents.state.offline")
            }
        }
    }
    enum Activity: String {
        case unknown, idle, working, attention
        var label: String {
            switch self {
            case .unknown: L10n.tr("agents.activity.unknown")
            case .idle: L10n.tr("agents.activity.idle")
            case .working: L10n.tr("agents.activity.working")
            case .attention: L10n.tr("agents.activity.attention")
            }
        }
    }
    let id: String
    let provider: String
    let displayName: String?
    let state: State
    let lastSeen: Date?
    var connectorID: UUID? = nil
    var activity: Activity = .unknown
    var activeTaskCount = 0
    var name: String { displayName ?? HarnessKind(rawValue: provider)?.displayName ?? provider }

    static func localOrigin(peerExecutable: String?, helperURL: URL) -> Origin {
        guard let peerExecutable,
              URL(fileURLWithPath: peerExecutable).resolvingSymlinksInPath() == helperURL.resolvingSymlinksInPath() else { return .unknown }
        return .local
    }

    static func runningProviders(detected: [HarnessDetection], applicationPaths: Set<String>,
                                 bundleIdentifiers: Set<String>) -> Set<String> {
        var providers = Set(detected.filter { detection in
            detection.locations.contains { $0.kind == .application && applicationPaths.contains($0.resolvedURL.path) }
        }.map(\.id))
        // Distribution names can change; the app's identity does not depend on
        // whether its bundle is named Codex.app or ChatGPT.app.
        if bundleIdentifiers.contains("com.openai.codex") { providers.insert("codex") }
        return providers
    }

    static func isTask(_ session: AgentSession) -> Bool {
        guard session.status != .idle && session.status != .ended else { return false }
        // Lifecycle-only Desktop fallback has no task context. Keep its provider
        // in Agents until the public-content stream or rollout supplies a task.
        if session.provider == "codex", session.lastEventID?.hasPrefix("desktop:") == true,
           session.title == "Codex Desktop", session.firstPrompt == nil,
           session.lastMessage == nil, session.tasks.isEmpty { return false }
        return true
    }

    static func project(detected: [HarnessDetection], sessions: [AgentSession],
                        receipts: [String: Date], running: Set<String>, now: Date,
                        connections: [String: Observation] = [:],
                        configurations: [Configuration] = []) -> [Self] {
        let installed = Set(detected.filter(\.isDetected).map(\.id))
        let legacySessions = sessions.filter { $0.connectionID == nil }
        let legacyByProvider = Dictionary(grouping: legacySessions, by: \.provider)
        let configured = Dictionary(configurations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localProviders = Set(connections.values.filter {
            $0.origin == .local && configured[$0.id] == nil && isFresh($0.lastSeen, at: now)
        }.map(\.provider))
        // Discovery is a fallback for an application, not another profile. Only
        // independent legacy activity may coexist with a confirmed local profile.
        // Idle sessions need a fresh receipt to prove a separate live agent.
        let independentLegacy = Set(legacySessions.filter { $0.status.isActive || $0.status == .failed }.map(\.provider))
            .union(receipts.filter { isFresh($0.value, at: now) }.keys)
        let providers = installed.union(legacyByProvider.keys).union(receipts.keys).union(running)
            .filter { !localProviders.contains($0) || independentLegacy.contains($0) }
        let legacy = providers.map { provider in
            let observations = legacyByProvider[provider] ?? []
            let latest = observations.max { $0.lastEventAt < $1.lastEventAt }
            let seen = receipts[provider] ?? latest?.lastEventAt
            // A quiet hook cannot prove that its process is still running. Only
            // fresh events or an observed native app establish online presence.
            let fresh = receipts[provider].map { isFresh($0, at: now) } ?? false
            let ended = !observations.isEmpty && observations.allSatisfy { $0.status == .ended }
            let state: State = (running.contains(provider) && !localProviders.contains(provider)) || (fresh && !ended) ? .online :
                ended ? .offline : seen != nil ? .lastSeen : .installed
            return Self(id: provider, provider: provider, displayName: nil, state: state, lastSeen: seen)
        }
        // Local configuration owns grouping and display names. Incoming events cannot
        // impersonate another saved SSH connector by supplying a group name.
        let observedIDs = Set(connections.values.map(\.id))
        let named = connections.values.compactMap { observation -> Self? in
            let config = configured[observation.id]
            if case .remote = observation.origin, config == nil { return nil }
            if config?.visible == false { return nil }
            let connected = config?.transportState.map { $0 == .connected } ?? true
            return Self(id: observation.id, provider: observation.provider, displayName: config?.name ?? observation.name,
                        state: connected && isFresh(observation.lastSeen, at: now) ? .online : .lastSeen, lastSeen: observation.lastSeen,
                        connectorID: config?.connectorID)
        }
        let quiet = configured.values.filter { $0.visible && !observedIDs.contains($0.id) }.map {
            Self(id: $0.id, provider: $0.provider, displayName: $0.name,
                 state: .installed, lastSeen: nil, connectorID: $0.connectorID)
        }
        let activeByIdentity = Dictionary(grouping: sessions.filter {
            Self.isTask($0) && [.working, .waiting, .approval, .failed].contains($0.status)
        }, by: { session in session.connectionID.map { session.provider + "/" + $0 } ?? session.provider })
        return (legacy + named + quiet).map { agent in
            var agent = agent
            guard agent.state == .online else { return agent }
            let active = activeByIdentity[agent.id] ?? []
            agent.activeTaskCount = active.count
            agent.activity = active.contains { [.waiting, .approval, .failed].contains($0.status) } ? .attention :
                active.isEmpty ? .idle : .working
            return agent
        }.sorted {
            if ($0.state == .online) != ($1.state == .online) { return $0.state == .online }
            let names = $0.name.localizedStandardCompare($1.name)
            return names == .orderedSame ? $0.id < $1.id : names == .orderedAscending
        }
    }

    static func isFresh(_ seen: Date, at now: Date) -> Bool {
        (-5...120).contains(now.timeIntervalSince(seen))
    }
}
