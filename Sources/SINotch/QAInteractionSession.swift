import AppKit

/// Opt-in interactive QA against a disposable private socket, never real Codex.
/// Uses the production parser, transport, response ledger and SwiftUI controls.
@MainActor enum QAInteractionSession {
    private static var stream: CodexDesktopStream?
    private static var timer: Timer?
    static func start(delegate: AppDelegate, socket: String, sessionID: String) {
        let path = URL(fileURLWithPath: socket).standardizedFileURL.resolvingSymlinksInPath().path
        guard ["/private/tmp/si-notch-interaction-qa-", "/tmp/si-notch-interaction-qa-"].contains(where: path.hasPrefix),
              UUID(uuidString: sessionID) != nil else {
            NSApplication.shared.terminate(nil); return
        }
        let model = delegate.model
        model.defaults.set(true, forKey: "codexAutoDetect")
        model.defaults.set(true, forKey: "keepOpen")
        model.defaults.set(false, forKey: "sound")
        let queue = DispatchQueue(label: "si-notch.interaction-qa")
        let stream = CodexDesktopStream(queue: queue, socketURL: URL(fileURLWithPath: path), onInteractions: { id, requests in
            DispatchQueue.main.async { model.receiveCodexInteractions(id, requests: requests) }
        }) { event, _ in
            DispatchQueue.main.async {
                if let data = try? JSONEncoder().encode(event) { model.receive(data, reply: { _ in }) }
            }
        }
        self.stream = stream
        model.codexResponder = { request, action, answers, completion in
            queue.async { stream.respond(request, action: action, answers: answers) { success in DispatchQueue.main.async { completion(success) } } }
        }
        model.setExpanded(true)
        delegate.panel.orderFrontRegardless()
        queue.async { stream.discover([sessionID]) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in queue.async { stream.discover([sessionID]) } }
    }
}
