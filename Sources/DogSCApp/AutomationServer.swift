import AppKit
import Foundation
@preconcurrency import Network

/// Local bridge for the stdio MCP process. No web server, remote listener,
/// arbitrary code execution, or permanent token. Enabled by --automation.
@MainActor
final class AutomationServer {
    static let shared = AutomationServer()
    static let endpointURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DogSC-Automation/endpoint.json")
    private var listener: NWListener?
    private let token = UUID().uuidString + UUID().uuidString
    private var peers: [UUID: AutomationPeer] = [:]
    private var commands: AutomationCommands?

    func start(model: AppModel) throws {
        guard listener == nil else { return }
        commands = AutomationCommands(model: model)
        let directory = Self.endpointURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .ready = state, let port = self.listener?.port {
                    do {
                        let data = try JSONSerialization.data(withJSONObject: ["port": Int(port.rawValue), "token": self.token, "pid": ProcessInfo.processInfo.processIdentifier])
                        try data.write(to: Self.endpointURL, options: [.atomic])
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.endpointURL.path)
                    } catch { model.errorMessage = "MCP: \(error.localizedDescription)" }
                }
                if case let .failed(error) = state { model.errorMessage = "MCP: \(error.localizedDescription)" }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self, self.peers.count < 16 else { connection.cancel(); return }
                let id = UUID()
                let peer = AutomationPeer(connection: connection) { [weak self] data in
                    await self?.reply(data) ?? Data("{\"error\":\"Application unavailable\"}".utf8)
                } onClose: { [weak self] in
                    Task { @MainActor [weak self] in self?.peers[id] = nil }
                }
                self.peers[id] = peer
                peer.start()
            }
        }
        listener.start(queue: DispatchQueue(label: "dogsc.automation.listener"))
    }

    private func reply(_ data: Data) async -> Data {
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  request["token"] as? String == token,
                  let name = request["name"] as? String,
                  let arguments = request["arguments"] as? [String: Any], let commands else {
                throw AutomationError.message("Unauthorized or invalid request")
            }
            let result = try await commands.call(name, arguments)
            return try JSONSerialization.data(withJSONObject: ["result": result], options: [.sortedKeys])
        } catch {
            return (try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription])) ?? Data()
        }
    }
}

/// One bounded JSON line per connection; a partial client cannot retain an
/// unbounded receive buffer or hold a slot indefinitely.
private final class AutomationPeer: @unchecked Sendable {
    let connection: NWConnection
    let handler: @Sendable (Data) async -> Data
    let onClose: @Sendable () -> Void
    private let queue = DispatchQueue(label: "dogsc.automation.peer")
    private var buffer = Data()
    private var closed = false

    init(connection: NWConnection, handler: @escaping @Sendable (Data) async -> Data,
         onClose: @escaping @Sendable () -> Void) {
        self.connection = connection; self.handler = handler; self.onClose = onClose
    }
    func start() {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 30) { self.close() }
        receive()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, error in
            if let data { buffer.append(data) }
            guard buffer.count <= 16 * 1_024 * 1_024 else { close(); return }
            if let newline = buffer.firstIndex(of: 10) {
                let request = Data(buffer[..<newline])
                Task {
                    var response = await handler(request)
                    response.append(10)
                    connection.send(content: response, completion: .contentProcessed { _ in
                        self.queue.async { self.close() }
                    })
                }
            } else if complete || error != nil { close() }
            else { receive() }
        }
    }
    private func close() {
        guard !closed else { return }
        closed = true; connection.cancel(); onClose()
    }
}
