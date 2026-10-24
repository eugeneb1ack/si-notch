import Foundation
import Darwin

struct RemoteHermesProfile: Identifiable, Codable, Equatable {
    let id: String
    let home: String
    var displayName: String
    var enabled: Bool
    var showSessionText: Bool
    let pluginInstalled: Bool
    let connectionId: String?
}

struct RemoteHermesSnapshot: Decodable {
    let snapshot: String
    let home: String
    let relayPath: String
    let socketPath: String
    let socketReady: Bool
    let profiles: [RemoteHermesProfile]
}

struct RemoteHermesPlan: Decodable {
    struct Change: Decodable, Identifiable {
        let id: String
        let displayName: String
        let action: String
    }
    let planId: String
    let snapshot: String
    let changes: [Change]
    let fileCount: Int
    let configCount: Int
    let paths: [String]
    var hasChanges: Bool { fileCount > 0 || configCount > 0 }
}

struct RemoteHermesReceipt: Decodable {
    struct Activation: Decodable {
        let id: String
        let enabled: Bool?
        let loaded: Bool
    }
    let planId: String
    let backup: String
    let profiles: [Activation]
    let changed: Bool
}

enum RemoteSetupError: LocalizedError {
    case invalidPath, missingResources, invalidResponse, outputTooLarge, timedOut, changedSincePreview
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath: L10n.tr("remote.setup.invalidPath")
        case .missingResources: L10n.tr("remote.setup.missingResources")
        case .invalidResponse: L10n.tr("remote.setup.invalidResponse")
        case .outputTooLarge: L10n.tr("remote.setup.outputTooLarge")
        case .timedOut: L10n.tr("remote.setup.timedOut")
        case .changedSincePreview: L10n.tr("remote.setup.changedSincePreview")
        case .remote(let detail): String(detail.prefix(1500))
        }
    }
}

/// A finite SSH operation, separate from the long-lived event tunnel.
struct RemoteHermesSetupClient {
    private struct Response<T: Decodable>: Decodable {
        let ok: Bool
        let data: T?
        let error: String?
    }

    let resources: URL?
    let sshExecutable: URL
    let timeout: TimeInterval

    init(resources: URL? = Bundle.main.resourceURL?.appendingPathComponent("adapters"),
         sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh"), timeout: TimeInterval = 120) {
        self.resources = resources
        self.sshExecutable = sshExecutable
        self.timeout = timeout
    }

    /// Authentication/reachability only. Does not create sockets or install files.
    func checkConnection(_ connection: RemoteSSHConnection) async throws {
        try RemoteSSHCommand.validateHost(connection.host.trimmingCharacters(in: .whitespacesAndNewlines))
        let marker = "si-notch-ssh-" + UUID().uuidString
        var args = try Self.arguments(host: connection.host, pythonPath: "/usr/bin/true", source: "")
        args[args.count - 1] = "printf '%s' " + Self.quote(marker)
        let output = try await execute(arguments: args, input: Data(), deadline: min(timeout, 15))
        guard String(decoding: output, as: UTF8.self) == marker else { throw RemoteSetupError.invalidResponse }
    }

    func inspect(_ connection: RemoteSSHConnection) async throws -> RemoteHermesSnapshot {
        try await request(connection, operation: "inspect")
    }

    func recoverSocket(_ command: RemoteSSHCommand, pythonPath: String) async throws {
        guard let resources,
              let source = try? String(contentsOf: resources.appendingPathComponent("remote-socket-recovery.py"), encoding: .utf8) else {
            throw RemoteSetupError.missingResources
        }
        let arguments = try Self.arguments(host: command.host, pythonPath: pythonPath, source: source)
        let input = try JSONSerialization.data(withJSONObject: ["socket_path": command.remoteSocketPath])
        let output = try await execute(arguments: arguments, input: input, deadline: min(timeout, 15))
        guard let response = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              response["ok"] as? Bool == true else { throw RemoteSetupError.invalidResponse }
    }

    func preview(_ connection: RemoteSSHConnection, snapshot: String,
                 profiles: [RemoteHermesProfile]) async throws -> RemoteHermesPlan {
        try await request(connection, operation: "preview", snapshot: snapshot, profiles: profiles)
    }

    func apply(_ connection: RemoteSSHConnection, snapshot: String,
               profiles: [RemoteHermesProfile], planID: String) async throws -> RemoteHermesReceipt {
        try await request(connection, operation: "apply", snapshot: snapshot, profiles: profiles, planID: planID)
    }

    static func arguments(host: String, pythonPath: String, source: String) throws -> [String] {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        try RemoteSSHCommand.validateHost(host)
        guard pythonPath.hasPrefix("/") || pythonPath.hasPrefix("~/"), pythonPath.utf8.count <= 1024,
              !pythonPath.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !pythonPath.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            throw RemoteSetupError.invalidPath
        }
        let executable = pythonPath.hasPrefix("~/") ? "\"$HOME\"/" + quote(String(pythonPath.dropFirst(2))) : quote(pythonPath)
        return ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ForwardAgent=no",
                "-o", "ForwardX11=no", "-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1",
                "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2",
                "-o", "ControlPath=none", "-o", "ControlMaster=no", "-o", "ControlPersist=no",
                "--", host, "exec " + executable + " -c " + quote(source)]
    }

    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func request<T: Decodable>(_ connection: RemoteSSHConnection, operation: String,
                                       snapshot: String? = nil, profiles: [RemoteHermesProfile] = [],
                                       planID: String? = nil) async throws -> T {
        guard let resources,
              let source = try? String(contentsOf: resources.appendingPathComponent("remote-hermes-setup.py"), encoding: .utf8) else {
            throw RemoteSetupError.missingResources
        }
        var object: [String: Any] = ["op": operation, "hermes_home": connection.hermesHome,
            "hermes_cli": connection.hermesCLI, "socket_path": connection.remoteSocketPath,
            "connector_id": connection.id.uuidString]
        if let snapshot { object["snapshot"] = snapshot }
        if let planID { object["plan_id"] = planID }
        if operation != "inspect" {
            object["profiles"] = profiles.map { ["id": $0.id, "display_name": $0.displayName,
                "enabled": $0.enabled, "show_session_text": $0.showSessionText] as [String: Any] }
            var sources: [String: String] = [:]
            for (key, path) in [("plugin_python", "hermes-si-notch/__init__.py"), ("manifest", "hermes-si-notch/plugin.yaml"), ("relay", "remote-relay.py"), ("configure", "hermes-si-notch/configure.py")] {
                guard let data = try? Data(contentsOf: resources.appendingPathComponent(path)) else { throw RemoteSetupError.missingResources }
                sources[key] = data.base64EncodedString()
            }
            object["sources"] = sources
        }
        let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let arguments = try Self.arguments(host: connection.host, pythonPath: connection.pythonPath, source: source)
        let deadline = operation == "apply" ? max(timeout, min(900, Double(profiles.count) * 45 + 30)) : timeout
        let output = try await execute(arguments: arguments, input: payload, deadline: deadline)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? decoder.decode(Response<T>.self, from: output) else { throw RemoteSetupError.invalidResponse }
        guard response.ok, let data = response.data else { throw RemoteSetupError.remote(response.error ?? L10n.tr("remote.setup.invalidResponse")) }
        return data
    }

    private func execute(arguments: [String], input: Data, deadline: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try run(arguments: arguments, input: input, timeout: deadline)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func run(arguments: [String], input: Data, timeout: TimeInterval) throws -> Data {
        guard input.count <= 512 * 1024 else { throw RemoteSetupError.outputTooLarge }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("si-notch-remote-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = directory.appendingPathComponent("request.json")
        try input.write(to: request)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: request.path)
        let handle = try FileHandle(forReadingFrom: request)
        defer { try? handle.close() }
        let process = Process(), output = Pipe(), errors = Pipe()
        let diagnostics = RemoteSetupDiagnostics()
        errors.fileHandleForReading.readabilityHandler = { file in
            let chunk = file.availableData
            if chunk.isEmpty { file.readabilityHandler = nil } else { diagnostics.append(chunk) }
        }
        defer {
            errors.fileHandleForReading.readabilityHandler = nil
            try? errors.fileHandleForReading.close()
            try? output.fileHandleForReading.close()
        }
        process.executableURL = sshExecutable
        process.arguments = arguments
        process.standardInput = handle
        process.standardOutput = output
        process.standardError = errors
        let started = ProcessInfo.processInfo.systemUptime
        try process.run()
        let deadline = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer {
            deadline.cancel()
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= 512 * 1024 else { throw RemoteSetupError.outputTooLarge }
        }
        process.waitUntilExit()
        if ProcessInfo.processInfo.systemUptime - started >= timeout { throw RemoteSetupError.timedOut }
        if data.isEmpty, process.terminationStatus != 0 { throw RemoteSetupError.remote(diagnostics.text) }
        return data
    }
}

private final class RemoteSetupDiagnostics {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk.prefix(max(0, 8192 - data.count)))
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
