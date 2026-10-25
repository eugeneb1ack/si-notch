import Darwin
import Foundation
import Network
import SINotchCore

/// Follows Desktop without taking ownership. The interaction bridge only sends
/// a request-bound response after an explicit click and a fresh owner check.
/// All mutable state and public operations are confined to the supplied queue.
final class CodexDesktopStream: @unchecked Sendable {
    private let queue: DispatchQueue
    private let socketURL: URL
    private let onEvent: (AgentEvent, Bool) -> Void
    private let onInteractions: (String, [CodexInteraction]) -> Void
    private lazy var interactions = CodexInteractionBridge(update: onInteractions,
        send: { [weak self] in self?.send($0) }, refresh: { [weak self] in self?.follow($0, following: true) })
    private var connection: NWConnection?
    private var clientID: String?
    private var pending = Data()
    private var tracked: [String: Date] = [:]
    private var activity = CodexDesktopActivity()
    private var feed = CodexDesktopFeed()
    private var subscribed: Set<String> = []
    private var resnapshotAt: [String: Date] = [:]
    private var retryAfter = Date.distantPast
    private var connectingAt: Date?
    private let maximumFrame = 32 * 1024 * 1024

    init(queue: DispatchQueue, socketURL: URL = FileManager.default.homeDirectoryForCurrentUser
         .appendingPathComponent(".codex/ipc/ipc.sock"),
         onInteractions: @escaping (String, [CodexInteraction]) -> Void = { _, _ in },
         onEvent: @escaping (AgentEvent, Bool) -> Void) {
        self.queue = queue
        self.socketURL = socketURL
        self.onEvent = onEvent
        self.onInteractions = onInteractions
    }

    func observe(_ observations: [CodexSessionObservation], now: Date = Date()) {
        interactions.tick()
        for observation in observations where !observation.isHistoryOnly {
            track([observation.event.sessionID], now: now)
            activity.observe(observation.event)
        }
        for (id, seen) in tracked where now.timeIntervalSince(seen) > 3600 {
            follow(id, following: false); tracked[id] = nil; activity.remove(id)
            feed.remove(id); subscribed.remove(id); resnapshotAt[id] = nil
            interactions.remove(id)
        }
        if let connectingAt, now.timeIntervalSince(connectingAt) > 10, clientID == nil { disconnect() }
        // Connect before the first log/rollout signal so native local discovery
        // can subscribe before a short turn (or a turn without reasoning) ends.
        if connection == nil, now >= retryAfter { connect() }
        subscribe(now: now)
    }

    func discover(_ ids: [String], now: Date = Date()) {
        track(ids, now: now)
        observe([], now: now)
    }

    private func track(_ ids: [String], now: Date) {
        for id in ids where UUID(uuidString: id) != nil {
            tracked[id] = now
        }
    }

    private func subscribe(now: Date = Date()) {
        guard clientID != nil else { return }
        for id in tracked.keys where !subscribed.contains(id) ||
            (!feed.hasSnapshot(id) && now.timeIntervalSince(resnapshotAt[id] ?? .distantPast) >= 5) {
            follow(id, following: true)
            subscribed.insert(id)
            resnapshotAt[id] = now
        }
    }

    func contains(_ id: String) -> Bool { connection != nil && feed.isFresh(id) }

    func respond(_ request: CodexInteraction, action: String?, answers: [String: String], completion: @escaping (Bool) -> Void) {
        interactions.submit(request, action: action, answers: answers, completion: completion)
    }

    func stop() {
        for id in subscribed { follow(id, following: false) }
        disconnect()
        tracked.removeAll(); activity = CodexDesktopActivity()
    }

    private func connect() {
        // Never follow symlinks or connect outside the current user's private IPC directory.
        var directory = stat(), socketInfo = stat()
        guard lstat(socketURL.deletingLastPathComponent().path, &directory) == 0,
              directory.st_mode & S_IFMT == S_IFDIR, directory.st_uid == getuid(), directory.st_mode & 0o077 == 0,
              lstat(socketURL.path, &socketInfo) == 0, socketInfo.st_mode & S_IFMT == S_IFSOCK,
              socketInfo.st_uid == getuid(), socketInfo.st_mode & 0o077 == 0 else {
            retryAfter = Date().addingTimeInterval(15); return
        }
        let socket = NWConnection(to: .unix(path: socketURL.path), using: .tcp)
        connection = socket
        connectingAt = Date()
        socket.stateUpdateHandler = { [weak self, weak socket] state in
            guard let self, let socket, self.connection === socket else { return }
            switch state {
            case .ready:
                self.send(["type": "request", "requestId": UUID().uuidString, "sourceClientId": "si-notch",
                           "version": 0, "method": "initialize", "params": ["clientType": "si-notch"], "timeoutMs": 3000])
                self.read(socket)
            case .failed, .cancelled: self.disconnect()
            default: break
            }
        }
        socket.start(queue: queue)
    }

    private func read(_ socket: NWConnection) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self, weak socket] data, _, ended, error in
            guard let self, let socket, self.connection === socket else { return }
            if let data {
                self.pending.append(data)
                guard self.consumeFrames() else { self.disconnect(); return }
            }
            if ended || error != nil { self.disconnect() } else { self.read(socket) }
        }
    }

    private func consumeFrames() -> Bool {
        while pending.count >= 4 {
            let size = pending.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
            guard size > 0, size <= maximumFrame else { return false }
            guard pending.count >= size + 4 else { return true }
            let bytes = Data(pending.dropFirst(4).prefix(size))
            pending.removeFirst(size + 4)
            guard let frame = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
            handle(frame)
        }
        return true
    }

    private func handle(_ frame: [String: Any]) {
        if frame["type"] as? String == "response", frame["method"] as? String == "initialize",
           frame["resultType"] as? String == "success",
           let id = (frame["result"] as? [String: Any])?["clientId"] as? String, UUID(uuidString: id) != nil {
            clientID = id; connectingAt = nil
            interactions.connected(clientID: id)
            subscribe()
            return
        }
        interactions.receive(frame)
        if frame["type"] as? String == "client-discovery-request", let requestID = frame["requestId"] as? String {
            send(["type": "client-discovery-response", "requestId": requestID, "response": ["canHandle": false]])
            return
        }
        guard frame["type"] as? String == "broadcast" else { return }
        if let targets = frame["targetClientIds"] as? [String], let clientID, !targets.contains(clientID) { return }
        if frame["method"] as? String == "thread-stream-state-changed", frame["version"] as? Int != 11,
           let params = frame["params"] as? [String: Any], let id = params["conversationId"] as? String,
           subscribed.contains(id) {
            interactions.remove(id)
            feed.remove(id)
            return
        }
        if frame["method"] as? String == "thread-read-state-changed", frame["version"] as? Int == 3,
           let params = frame["params"] as? [String: Any], params["hostId"] as? String == "local",
           let id = params["conversationId"] as? String, UUID(uuidString: id) != nil {
            // Read-state events identify a local thread but do not establish
            // that it is running. Ignore all context and request its snapshot.
            track([id], now: Date())
            subscribe()
            return
        }
        guard frame["method"] as? String == "thread-stream-state-changed",
              frame["version"] as? Int == 11, let params = frame["params"] as? [String: Any],
              let id = params["conversationId"] as? String, subscribed.contains(id),
              let host = params["hostId"] as? String, ["local", "durable"].contains(host),
              let change = params["change"] as? [String: Any] else { return }
        let update = feed.consume(id: id, host: host, change: change)
        if update.needsSnapshot { interactions.remove(id) }
        if !update.needsSnapshot, feed.acceptsHost(host, for: id), let owner = frame["sourceClientId"] as? String {
            interactions.consume(sessionID: id, host: host, owner: owner, change: change)
        }
        if update.needsSnapshot {
            if Date().timeIntervalSince(resnapshotAt[id] ?? .distantPast) >= 5 {
                resnapshotAt[id] = Date()
                follow(id, following: true) // Request a fresh snapshot after a lost revision.
            }
            return
        }
        if let event = update.event {
            // Discovery and metadata updates cannot enroll a completed turn.
            // A terminal snapshot closes only the turn we actually observed.
            guard activity.accept(event) else { return }
            tracked[id] = Date()
            onEvent(event, update.bootstrap)
        }
    }

    private func follow(_ id: String, following: Bool) {
        guard let clientID else { return }
        for host in ["local", "durable"] {
            send(["type": "broadcast", "sourceClientId": clientID, "version": 1,
                  "method": "thread-stream-following-changed",
                  "params": ["conversationId": id, "hostId": host, "following": following]])
        }
    }

    private func send(_ object: [String: Any]) {
        guard let connection, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var size = UInt32(data.count).littleEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }
        frame.append(data)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func disconnect() {
        let old = connection
        connection = nil; clientID = nil; connectingAt = nil
        old?.cancel()
        interactions.disconnect()
        pending.removeAll(); subscribed.removeAll(); feed = CodexDesktopFeed(); resnapshotAt.removeAll()
        retryAfter = Date().addingTimeInterval(5)
    }
}

/// Admission to the live task pool is scoped to an observed turn, independently
/// of subscription/discovery and the feed's metadata/heartbeat deduplication.
struct CodexDesktopActivity {
    private struct Turn {
        let id: String?
        let observedAt: Date
    }
    private var active: [String: Turn] = [:]
    private var ended: [String: String] = [:]

    mutating func observe(_ event: AgentEvent) {
        guard [.working, .toolStarted, .waiting, .approvalRequested].contains(event.kind),
              event.turnID == nil || ended[event.sessionID] != event.turnID else { return }
        if let current = active[event.sessionID] {
            guard event.turnID != nil, event.timestamp > current.observedAt ||
                (event.timestamp == current.observedAt && event.turnID == current.id) else { return }
        }
        active[event.sessionID] = Turn(id: event.turnID, observedAt: event.timestamp)
    }

    mutating func accept(_ event: AgentEvent) -> Bool {
        if [.working, .toolStarted, .waiting, .approvalRequested].contains(event.kind) {
            if let id = event.turnID, ended[event.sessionID] == id { return false }
            // The revision-checked stream is authoritative even if a file's
            // clock is ahead. File hints above must remain chronological.
            active[event.sessionID] = Turn(id: event.turnID, observedAt: event.timestamp)
        }
        let turn = active[event.sessionID]
        let matches = turn.map { $0.id == nil || event.turnID == nil || $0.id == event.turnID } ?? false
        // An unrelated late outcome cannot move the completed-turn fence back.
        if event.kind.historyTerminalStatus != nil, matches || ended[event.sessionID] == nil,
           let id = event.turnID ?? turn?.id {
            ended[event.sessionID] = id
        }
        guard matches else { return false }
        // An empty/loading snapshot cannot close a turn discovered in a log
        // before Desktop has hydrated its current turn.
        if event.kind == .sessionStarted, turn?.id == nil || event.turnID == nil { return false }
        if event.kind.historyTerminalStatus != nil || event.kind == .sessionStarted {
            active[event.sessionID] = nil
        }
        return true
    }

    mutating func remove(_ id: String) { active[id] = nil; ended[id] = nil }
}

/// Stream freshness is independent of socket connectivity. A connected but stale
/// stream must not suppress current lifecycle events from the Desktop log.
struct CodexDesktopFeed {
    private struct Entry {
        var state: CodexDesktopState
        var host: String
        var updatedAt: Date
        var emittedAt: Date
        var fingerprint: AgentEvent
    }
    private var entries: [String: Entry] = [:]

    func hasSnapshot(_ id: String) -> Bool { entries[id] != nil }
    func acceptsHost(_ host: String, for id: String) -> Bool { entries[id]?.host == host }

    func isFresh(_ id: String, now: Date = Date()) -> Bool {
        guard let entry = entries[id] else { return false }
        return (0...15).contains(now.timeIntervalSince(entry.updatedAt))
    }

    mutating func remove(_ id: String) { entries[id] = nil }

    mutating func consume(id: String, host: String, change: [String: Any], now: Date = Date())
        -> (event: AgentEvent?, bootstrap: Bool, needsSnapshot: Bool) {
        let previous = entries[id]
        // Local and cloud hosts have separate revision histories. Never apply
        // one host's delta to the other host's snapshot.
        if let previous, previous.host != host, isFresh(id, now: now) { return (nil, false, false) }
        var state = previous?.host == host ? previous!.state : CodexDesktopState()
        guard state.apply(change), var event = state.event(sessionID: id, now: now) else {
            if previous?.host == host { entries[id] = nil }
            return (nil, false, true)
        }
        var fingerprint = event
        fingerprint.id = nil; fingerprint.timestamp = .distantPast
        let heartbeat = previous.map { now.timeIntervalSince($0.emittedAt) >= 30 } ?? true
        let emit = previous?.fingerprint != fingerprint || heartbeat
        if heartbeat { event.id = "desktop-stream:\(id):heartbeat:\(Int(now.timeIntervalSince1970))" }
        entries[id] = Entry(state: state, host: host, updatedAt: now,
                            emittedAt: emit ? now : previous!.emittedAt, fingerprint: fingerprint)
        return (emit ? event : nil, previous == nil, false)
    }
}
