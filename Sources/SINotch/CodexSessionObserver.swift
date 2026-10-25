import Foundation
import SINotchCore

/// A local, read-only rollout observation. Bootstrap events are historical state
/// snapshots and should not trigger notification sounds or automatic reveal.
struct CodexSessionObservation {
    let event: AgentEvent
    let isBootstrap: Bool
    let isHistoryOnly: Bool

    init(event: AgentEvent, isBootstrap: Bool, isHistoryOnly: Bool = false) {
        self.event = event; self.isBootstrap = isBootstrap; self.isHistoryOnly = isHistoryOnly
    }
}

/// Polls recent local rollouts. Optional public snippets exclude reasoning,
/// tool arguments and command output.
struct CodexRolloutScanner {
    private struct FileState {
        let inode: UInt64
        var offset: UInt64
        var partial = Data()
        var discardingLongLine = false
        let sessionID: String
        let cwd: String?
        let isInternalSession: Bool?
        let isWorkSession: Bool?
        var activeTurnID: String?
        var activeTurnStartedAt: Date?
        var activityAt: Date?
        var visible = false
        var idleAfterSilence = false
        var prompt: String?
        var message: String?
        var model: String?
        var effort: String?
        var tools: [String: String] = [:]
    }

    private struct Candidate {
        let url: URL
        let inode: UInt64
        let size: UInt64
        let modified: Date
    }

    let sessionsRoot: URL
    let includeContent: Bool
    private let historySessionKeys: Set<String>
    var silenceInterval: TimeInterval = 15 * 60
    private var files: [String: FileState] = [:]
    private var directories = SessionDirectoryCache()

    private let maximumLineBytes = 256 * 1_024
    private let maximumBootstrapBytes = 4 * 1_024 * 1_024
    private let maximumIncrementBytes = 512 * 1_024

    init(sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true), includeContent: Bool = false,
         historySessionKeys: Set<String> = []) {
        self.sessionsRoot = sessionsRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.includeContent = includeContent
        self.historySessionKeys = historySessionKeys
    }

    mutating func poll(now: Date = Date(), changedPaths: [URL]? = nil) -> [CodexSessionObservation] {
        var observations: [CodexSessionObservation] = []
        let selected = candidates(now: now, changedPaths: changedPaths)
        for candidate in selected {
            let key = candidate.url.path
            if var state = files[key], state.inode == candidate.inode, candidate.size >= state.offset {
                if candidate.size > state.offset {
                    readIncrement(candidate, state: &state, now: now, into: &observations)
                    files[key] = state
                }
            } else if let state = bootstrap(candidate, now: now, into: &observations) {
                files[key] = state
            }
        }
        for key in files.keys.sorted() {
            guard var state = files[key], let activity = state.activityAt,
                  state.activeTurnID != nil, state.visible, !state.idleAfterSilence,
                  now.timeIntervalSince(activity) >= silenceInterval else { continue }
            state.idleAfterSilence = true
            observations.append(CodexSessionObservation(event: event(.sessionStarted, state: state, now: now,
                id: "rollout:\(state.activeTurnID ?? "unknown"):silent"), isBootstrap: false))
            files[key] = state
        }
        let live = Set(selected.map { $0.url.path })
        files = files.filter { live.contains($0.key) }
        return observations
    }

    private mutating func candidates(now: Date, changedPaths: [URL]?) -> [Candidate] {
        var urls = Set(files.keys.map { URL(fileURLWithPath: $0) })
        if let changedPaths {
            urls.formUnion(changedPaths)
        } else {
            var folders = [sessionsRoot]
            for width in [4, 2, 2] {
                folders = folders.flatMap { folder in
                    directories.contents(of: folder).filter { url in
                        let name = url.lastPathComponent
                        return name.count == width && name.utf8.allSatisfy { (48...57).contains($0) } &&
                            SessionFileMetadata(url)?.isDirectory == true
                    }
                }
            }
            for directory in folders { urls.formUnion(directories.contents(of: directory)) }
        }
        var found: [Candidate] = []
        var parents: [URL: Bool] = [:]
        for candidateURL in urls where candidateURL.lastPathComponent.hasPrefix("rollout-") && candidateURL.pathExtension == "jsonl" {
            if !historySessionKeys.isEmpty {
                let id = String(candidateURL.deletingPathExtension().lastPathComponent.suffix(36))
                guard UUID(uuidString: id) != nil,
                      let key = try? HistoryStore.sessionKey(AgentEvent(sessionID: id, provider: "codex", kind: .completed)),
                      historySessionKeys.contains(key) else { continue }
            }
            // Directory listings may use /private/var while the same root URL
            // uses /var. Normalize aliases before validating path components.
            let url = candidateURL.standardizedFileURL
            // Recheck parents even for tracked files: replacing a dated
            // directory with a symlink must never redirect subsequent reads.
            let prefix = sessionsRoot.path + "/"
            guard url.path.hasPrefix(prefix) else { continue }
            let parts = url.path.dropFirst(prefix.count).split(separator: "/")
            guard parts.count == 4, zip(parts.prefix(3), [4, 2, 2]).allSatisfy({ part, width in
                part.count == width && part.utf8.allSatisfy { (48...57).contains($0) }
            }) else { continue }
            var parent = sessionsRoot
            let safe = parts.prefix(3).allSatisfy { part in
                parent.appendPathComponent(String(part))
                let directory = parents[parent] ?? (SessionFileMetadata(parent)?.isDirectory == true)
                parents[parent] = directory
                return directory
            }
            guard safe else { continue }
            guard let metadata = SessionFileMetadata(url), metadata.isRegularFile,
                  metadata.owner == getuid(),
                  now.timeIntervalSince(metadata.modified) >= -60,
                  !historySessionKeys.isEmpty || now.timeIntervalSince(metadata.modified) <= 30 * 60 else { continue }
            found.append(Candidate(url: url, inode: metadata.inode,
                                   size: metadata.size, modified: metadata.modified))
        }
        return found.sorted { $0.modified > $1.modified }
    }

    private func bootstrap(_ candidate: Candidate, now: Date,
                           into observations: inout [CodexSessionObservation]) -> FileState? {
        guard let handle = try? FileHandle(forReadingFrom: candidate.url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: maximumLineBytes),
              let newline = header.firstIndex(of: 10),
              let meta = json(Data(header[..<newline])),
              meta["type"] as? String == "session_meta",
              let payload = meta["payload"] as? [String: Any],
              payload["parent_thread_id"] == nil || payload["parent_thread_id"] is NSNull,
              CodexServiceSessionFilter.nativeClassification(source: payload["source"]) != true,
              let id = payload["id"] as? String, UUID(uuidString: id) != nil else { return nil }
        let cwd = (payload["cwd"] as? String).flatMap { $0.hasPrefix("/") && $0.utf8.count <= 4096 ? $0 : nil }
        var state = FileState(inode: candidate.inode, offset: 0, sessionID: id, cwd: cwd,
            isInternalSession: CodexServiceSessionFilter.nativeClassification(source: payload["source"]),
            isWorkSession: CodexSessionOrigin.isWork(originator: payload["originator"], serviceName: payload["service_name"]))
        let firstLineEnd = UInt64(newline + 1)
        let bootstrapBytes = historySessionKeys.isEmpty ? maximumBootstrapBytes : 16 * 1024 * 1024
        let start = max(firstLineEnd, candidate.size > UInt64(bootstrapBytes)
                        ? candidate.size - UInt64(bootstrapBytes) : firstLineEnd)
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        let bytes: Data
        do { bytes = try handle.read(upToCount: bootstrapBytes) ?? Data() }
        catch { return nil }
        state.offset = start + UInt64(bytes.count)
        var data = bytes
        if start > firstLineEnd {
            guard let boundary = data.firstIndex(of: 10) else { return state }
            data.removeSubrange(...boundary)
        }
        consume(data, state: &state, now: now, bootstrap: true, into: &observations)
        if state.activeTurnID != nil, let activity = state.activityAt,
           now.timeIntervalSince(activity) >= -60, now.timeIntervalSince(activity) <= 3 * 60 {
            state.visible = true
            observations.append(CodexSessionObservation(event: event(.working, state: state, now: activity,
                id: "rollout:\(state.activeTurnID ?? "unknown"):bootstrap"), isBootstrap: true))
        }
        return state
    }

    private func readIncrement(_ candidate: Candidate, state: inout FileState, now: Date,
                               into observations: inout [CodexSessionObservation]) {
        // A very large append is bounded: its final tail is treated as a fresh
        // snapshot, never replayed as a sequence of actions.
        if candidate.size - state.offset > UInt64(maximumBootstrapBytes) {
            if let replacement = bootstrap(candidate, now: now, into: &observations) { state = replacement }
            return
        }
        guard let handle = try? FileHandle(forReadingFrom: candidate.url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: state.offset)) != nil,
              let bytes = try? handle.read(upToCount: min(maximumIncrementBytes,
                Int(candidate.size - state.offset))) else { return }
        state.offset += UInt64(bytes.count)
        consume(bytes, state: &state, now: now, bootstrap: false, into: &observations)
    }

    private func consume(_ bytes: Data, state: inout FileState, now: Date, bootstrap: Bool,
                         into observations: inout [CodexSessionObservation]) {
        var buffer = state.partial + bytes
        state.partial.removeAll(keepingCapacity: true)
        if state.discardingLongLine {
            guard let boundary = buffer.firstIndex(of: 10) else { return }
            buffer.removeSubrange(...boundary)
            state.discardingLongLine = false
        }
        while let boundary = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<boundary])
            buffer.removeSubrange(...boundary)
            if line.count <= maximumLineBytes, let record = json(line) {
                consumeRecord(record, state: &state, now: now, bootstrap: bootstrap, into: &observations)
            }
        }
        if buffer.count > maximumLineBytes { state.discardingLongLine = true }
        else { state.partial = buffer }
    }

    private func consumeRecord(_ record: [String: Any], state: inout FileState, now: Date,
                               bootstrap: Bool, into observations: inout [CodexSessionObservation]) {
        guard let kind = record["type"] as? String,
              let payload = record["payload"] as? [String: Any] else { return }
        if kind == "turn_context" {
            state.model = Self.safeText(payload["model"], maximum: 256) ?? state.model
            state.effort = Self.safeText(payload["effort"], maximum: 128) ?? state.effort
            if state.visible && !bootstrap {
                observations.append(CodexSessionObservation(event: event(.usageUpdated, state: state,
                    now: Self.recordDate(record) ?? now, id: "rollout:\(state.activeTurnID ?? "unknown"):model:\(state.offset)"), isBootstrap: false))
            }
            return
        }
        guard let stamp = Self.recordDate(record) else { return }
        if includeContent, kind == "response_item", payload["type"] as? String == "message" {
            let role = payload["role"] as? String
            if role == "user", let prompt = SessionSnippet.message(payload["content"]) { state.prompt = prompt; state.message = nil }
            if role == "assistant", payload["phase"] as? String != "analysis" {
                state.message = SessionSnippet.message(payload["content"]) ?? state.message
            }
            if state.visible && !bootstrap && (role == "user" || (role == "assistant" && payload["phase"] as? String != "analysis")) {
                observations.append(CodexSessionObservation(event: event(.usageUpdated, state: state,
                    now: stamp, id: "rollout:message:\(state.offset)", historyItems:
                        HistoryContent.message(id: payload["id"] as? String ?? "message-\(state.offset)",
                            role: role == "user" ? .user : .assistant, content: payload["content"]).map { [$0] }), isBootstrap: false))
            }
        }
        if kind == "event_msg" {
            switch payload["type"] as? String {
            case "user_message" where includeContent:
                if let prompt = SessionSnippet.text(payload["message"]) { state.prompt = prompt; state.message = nil }
                if state.visible && !bootstrap,
                   let item = HistoryContent.message(id: "user-\(state.offset)", role: .user, content: payload["message"]) {
                    observations.append(CodexSessionObservation(event: event(.usageUpdated, state: state,
                        now: stamp, id: "rollout:user:\(state.offset)", historyItems: [item]), isBootstrap: false))
                }
            case "task_started":
                guard let turn = payload["turn_id"] as? String, UUID(uuidString: turn) != nil else { return }
                state.activeTurnID = turn
                state.activeTurnStartedAt = stamp
                state.activityAt = stamp
                state.idleAfterSilence = false
                state.tools.removeAll()
                if !bootstrap, now.timeIntervalSince(stamp) >= -60,
                   now.timeIntervalSince(stamp) <= 5 * 60 {
                    state.visible = true
                    observations.append(CodexSessionObservation(event: event(.working, state: state,
                        now: stamp, id: "rollout:\(turn):start"), isBootstrap: false))
                }
            case "task_complete":
                if bootstrap, includeContent, let turn = payload["turn_id"] as? String, UUID(uuidString: turn) != nil {
                    // The bounded tail already read at startup contains reliable
                    // completion markers for archived turns. Reconcile status
                    // without replaying text, notifications or live lifecycle.
                    let completed = AgentEvent(sessionID: state.sessionID, provider: "codex", kind: .completed,
                        timestamp: stamp, id: "rollout:\(turn):archived-complete", turnID: turn)
                    observations.append(CodexSessionObservation(event: completed, isBootstrap: true, isHistoryOnly: true))
                }
                guard let turn = state.activeTurnID,
                      payload["turn_id"] as? String == turn else { return }
                state.message = includeContent ? SessionSnippet.text(payload["last_agent_message"]) ?? state.message : nil
                state.activeTurnID = nil
                state.activeTurnStartedAt = nil
                state.activityAt = stamp
                state.idleAfterSilence = false
                state.tools.removeAll()
                if state.visible && !bootstrap {
                    observations.append(CodexSessionObservation(event: event(.completed, state: state,
                        now: stamp, id: "rollout:\(turn):complete", turnID: turn, historyItems: includeContent ?
                            HistoryContent.message(id: "final-\(turn)", role: .assistant, content: payload["last_agent_message"]).map { [$0] } : nil), isBootstrap: false))
                }
                state.visible = false
            case "turn_aborted", "turn_cancelled":
                if bootstrap, includeContent, let turn = payload["turn_id"] as? String, UUID(uuidString: turn) != nil {
                    let ended = AgentEvent(sessionID: state.sessionID, provider: "codex", kind: .sessionEnded,
                        timestamp: stamp, id: "rollout:\(turn):archived-end", turnID: turn)
                    observations.append(CodexSessionObservation(event: ended, isBootstrap: true, isHistoryOnly: true))
                }
                guard let turn = state.activeTurnID,
                      let startedAt = state.activeTurnStartedAt,
                      stamp >= startedAt else { return }
                if let value = payload["turn_id"], !(value is NSNull) {
                    guard let reportedTurn = value as? String, reportedTurn == turn else { return }
                }
                if !bootstrap, includeContent {
                    let ended = AgentEvent(sessionID: state.sessionID, provider: "codex", kind: .sessionEnded,
                        timestamp: stamp, id: "rollout:\(turn):archived-end", turnID: turn)
                    observations.append(CodexSessionObservation(event: ended, isBootstrap: false, isHistoryOnly: true))
                }
                state.activeTurnID = nil
                state.activeTurnStartedAt = nil
                state.activityAt = stamp
                state.idleAfterSilence = false
                state.tools.removeAll()
                if state.visible && !bootstrap {
                    observations.append(CodexSessionObservation(event: event(.sessionStarted,
                        state: state, now: stamp, id: "rollout:\(turn):aborted"), isBootstrap: false))
                }
                state.visible = false
            case "item_completed", "token_count", "agent_message":
                if includeContent, payload["type"] as? String == "agent_message" {
                    state.message = SessionSnippet.text(payload["message"]) ?? state.message
                }
                guard state.activeTurnID != nil else { return }
                state.activityAt = stamp
                if (state.idleAfterSilence || !state.visible) && !bootstrap,
                   now.timeIntervalSince(stamp) >= -60,
                   now.timeIntervalSince(stamp) <= 5 * 60 {
                    state.idleAfterSilence = false
                    state.visible = true
                    observations.append(CodexSessionObservation(event: event(.working, state: state,
                        now: stamp, id: "rollout:\(state.activeTurnID ?? "unknown"):resume:\(state.offset)"), isBootstrap: false))
                }
            default: break
            }
        } else if kind == "response_item", !bootstrap, state.activeTurnID != nil,
                  let itemType = payload["type"] as? String,
                  let callID = Self.safeText(payload["call_id"], maximum: 160),
                  callID.range(of: "^[A-Za-z0-9_.:-]+$", options: .regularExpression) != nil,
                  now.timeIntervalSince(stamp) >= -60,
                  now.timeIntervalSince(stamp) <= 5 * 60 {
            switch itemType {
            case "function_call", "custom_tool_call":
                guard let name = Self.safeText(payload["name"], maximum: 80),
                      name.range(of: "^[A-Za-z0-9_.:-]+$", options: .regularExpression) != nil else { return }
                if state.tools.count < 32 { state.tools[callID] = name }
                state.activityAt = stamp
                state.visible = true
                state.idleAfterSilence = false
                observations.append(CodexSessionObservation(event: event(.toolStarted, state: state,
                    now: stamp, id: "rollout:\(callID):tool-start", toolName: name, historyItems: includeContent ?
                        HistoryContent.command(id: callID, name: name, arguments: payload["arguments"] ?? payload["input"]).map { [$0] } : nil), isBootstrap: false))
            case "function_call_output", "custom_tool_call_output":
                guard let name = state.tools.removeValue(forKey: callID) else { return }
                state.activityAt = stamp
                state.visible = true
                state.idleAfterSilence = false
                observations.append(CodexSessionObservation(event: event(.toolFinished, state: state,
                    now: stamp, id: "rollout:\(callID):tool-finish", toolName: name), isBootstrap: false))
            default: break
            }
        }
    }

    private func event(_ kind: AgentEventKind, state: FileState, now: Date,
                       id: String, toolName: String? = nil, turnID: String? = nil, historyItems: [AgentHistoryItem]? = nil) -> AgentEvent {
        AgentEvent(sessionID: state.sessionID, provider: "codex", kind: kind,
                   timestamp: now, id: id, title: state.prompt.map { String($0.prefix(100)) }, projectPath: state.cwd,
                   message: state.message, toolName: toolName, modelName: state.model, reasoningEffort: state.effort, firstPrompt: state.prompt,
                   turnID: turnID ?? state.activeTurnID, isInternalSession: state.isInternalSession,
                   isWorkSession: state.isWorkSession, historyItems: historyItems)
    }

    private static func safeText(_ value: Any?, maximum: Int) -> String? {
        guard let string = value as? String, !string.isEmpty, string.utf8.count <= maximum,
              !string.unicodeScalars.contains(where: { $0.value < 32 }) else { return nil }
        return string
    }

    private static func recordDate(_ record: [String: Any]) -> Date? {
        guard let value = record["timestamp"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func json(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty, data.count <= maximumLineBytes else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Runs file polling away from the UI thread and delivers observations on main.
final class CodexSessionObserver {
    private let queue = DispatchQueue(label: "si-notch.codex-rollout-observer", qos: .utility)
    private let lifecycleLock = NSLock()
    private var started = false
    private var generation: UInt64 = 0
    private let interval: TimeInterval
    private let onEvent: (AgentEvent, Bool) -> Void
    private let onHistory: (AgentEvent) -> Void
    private let onInteractions: (String, [CodexInteraction]) -> Void
    private var scanner: CodexRolloutScanner
    private var desktopScanner = CodexDesktopScanner()
    private var desktopStream: CodexDesktopStream?
    private var rolloutWatcher: CodexRolloutWatcher?
    private var timer: DispatchSourceTimer?

    init(sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
         pollInterval: TimeInterval = 1,
         onHistory: @escaping (AgentEvent) -> Void = { _ in },
         onInteractions: @escaping (String, [CodexInteraction]) -> Void = { _, _ in },
         onEvent: @escaping (AgentEvent, Bool) -> Void) {
        scanner = CodexRolloutScanner(sessionsRoot: sessionsRoot, includeContent: true)
        interval = max(0.25, pollInterval)
        self.onEvent = onEvent
        self.onHistory = onHistory
        self.onInteractions = onInteractions
    }

    func start() {
        lifecycleLock.lock()
        guard !started else { lifecycleLock.unlock(); return }
        started = true
        generation &+= 1
        let currentGeneration = generation
        lifecycleLock.unlock()
        queue.async { [weak self] in
            guard let self, self.isCurrent(currentGeneration), self.timer == nil else { return }
            let watcher = CodexRolloutWatcher(root: self.scanner.sessionsRoot, queue: self.queue)
            watcher.start()
            self.rolloutWatcher = watcher
            self.desktopStream = CodexDesktopStream(queue: self.queue, onInteractions: { [weak self] id, requests in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrent(currentGeneration) else { return }
                    self.onInteractions(id, requests)
                }
            }) { [weak self] event, bootstrap in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrent(currentGeneration) else { return }
                    self.onEvent(event, bootstrap)
                }
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: self.interval, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                guard let self, self.isCurrent(currentGeneration) else { return }
                let desktop = self.desktopScanner.poll()
                let rollouts = self.scanner.poll(changedPaths: self.rolloutWatcher?.takeChanges())
                self.desktopStream?.observe(rollouts + desktop)
                // A fresh Desktop stream owns the lifecycle. File snapshots and
                // log lines must not replay older states over its current turn.
                let observations = (rollouts + desktop).filter {
                    !$0.isHistoryOnly && self.desktopStream?.contains($0.event.sessionID) != true
                }
                for observation in rollouts + desktop where observation.isHistoryOnly ||
                    (!observation.isBootstrap && self.desktopStream?.contains(observation.event.sessionID) == true &&
                     (observation.event.historyItems?.isEmpty == false || observation.event.kind.historyTerminalStatus != nil)) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isCurrent(currentGeneration) else { return }
                        self.onHistory(observation.event)
                    }
                }
                for observation in observations.sorted(by: { $0.event.timestamp < $1.event.timestamp }) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isCurrent(currentGeneration) else { return }
                        self.onEvent(observation.event, observation.isBootstrap)
                    }
                }
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        lifecycleLock.lock()
        started = false
        generation &+= 1
        lifecycleLock.unlock()
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.desktopStream?.stop()
            self?.desktopStream = nil
            self?.rolloutWatcher?.stop()
            self?.rolloutWatcher = nil
        }
    }

    func respond(_ request: CodexInteraction, action: String?, answers: [String: String], completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let stream = self?.desktopStream else { DispatchQueue.main.async { completion(false) }; return }
            stream.respond(request, action: action, answers: answers) { success in
                DispatchQueue.main.async { completion(success) }
            }
        }
    }

    private func isCurrent(_ value: UInt64) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return started && generation == value
    }
}
