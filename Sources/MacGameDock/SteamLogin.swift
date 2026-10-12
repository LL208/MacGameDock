import AppKit
import Foundation
import Network

/// One-shot browser login. The HTTP listener binds only to loopback, uses an
/// unpredictable callback path, and accepts an identity only after Steam verifies it.
@MainActor
final class SteamLogin {
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var timeout: Task<Void, Never>?
    private var verification: Task<Void, Never>?
    private var completion: ((Result<String, Error>) -> Void)?
    private var returnTo: URL?
    private var startedAt = Date()
    private var receivedCallback = false
    private let queue = DispatchQueue(label: "MacGameDock.SteamCallback")

    func start(completion: @escaping (Result<String, Error>) -> Void) {
        cancel()
        self.completion = completion
        startedAt = Date()
        receivedCallback = false
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port else {
                            self.finish(.failure(DockError.message("Porta locale non disponibile."))); return
                        }
                        let callback = URL(string: "http://127.0.0.1:\(port.rawValue)/steam/\(UUID().uuidString)/callback")!
                        self.returnTo = callback
                        guard NSWorkspace.shared.open(SteamOpenID.loginURL(returnTo: callback)) else {
                            self.finish(.failure(DockError.message("Impossibile aprire il browser per Steam."))); return
                        }
                    case .failed:
                        self.finish(.failure(DockError.message("Impossibile avviare il callback locale del login Steam.")))
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: queue)
            timeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 180_000_000_000) } catch { return }
                self?.finish(.failure(DockError.message("Tempo di accesso scaduto. Premi Accedi con Steam per riprovare.")))
            }
        } catch { finish(.failure(DockError.message("Impossibile preparare l'accesso Steam."))) }
    }

    func cancel() {
        let callback = completion
        completion = nil
        stop()
        callback?(.failure(CancellationError()))
    }

    private func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        timeout?.cancel(); timeout = nil
        verification?.cancel(); verification = nil
        returnTo = nil
    }

    private func finish(_ result: Result<String, Error>) {
        let callback = completion
        completion = nil
        stop()
        callback?(result)
    }

    private func accept(_ connection: NWConnection) {
        guard completion != nil, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        receive(connection, id: id, accumulated: Data())
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if self?.connections.removeValue(forKey: id) != nil { connection.cancel() }
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { connection.cancel(); return }
                var data = accumulated
                if let chunk { data.append(chunk) }
                guard error == nil, data.count <= 65_536 else {
                    self.connections.removeValue(forKey: id); connection.cancel(); return
                }
                if data.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.handle(data, connection: connection, id: id)
                } else if isComplete {
                    self.connections.removeValue(forKey: id); connection.cancel()
                } else { self.receive(connection, id: id, accumulated: data) }
            }
        }
    }

    private func handle(_ data: Data, connection: NWConnection, id: UUID) {
        guard let returnTo, let text = String(data: data, encoding: .utf8),
              let first = text.components(separatedBy: "\r\n").first else {
            reply(connection, id: id, status: "400 Bad Request", message: "Richiesta non valida."); return
        }
        let fields = first.split(separator: " ")
        guard fields.count == 3, fields[0] == "GET", fields[1].hasPrefix("/"),
              let callback = URL(string: "http://127.0.0.1:\(returnTo.port!)\(fields[1])"),
              callback.path == returnTo.path else {
            reply(connection, id: id, status: "404 Not Found", message: "Pagina non disponibile."); return
        }
        guard !receivedCallback else {
            reply(connection, id: id, status: "409 Conflict", message: "Accesso gia in verifica."); return
        }
        do {
            let (steamID, parameters) = try SteamOpenID.validate(callback: callback, expectedReturnTo: returnTo, startedAt: startedAt)
            receivedCallback = true
            reply(connection, id: id, status: "200 OK", message: "Risposta ricevuta. Torna in MacGameDock: l'app sta verificando l'accesso con Steam.")
            verification = Task { [weak self] in
                do {
                    try await SteamAPI().verifyOpenID(parameters)
                    try Task.checkCancellation()
                    self?.finish(.success(steamID))
                } catch {
                    if !Task.isCancelled { self?.finish(.failure(DockError.message("Accesso Steam non verificato. Riprova."))) }
                }
            }
        } catch {
            reply(connection, id: id, status: "400 Bad Request", message: "Accesso non valido o annullato. Torna in MacGameDock per riprovare.")
            // Keep listening after unrelated malformed requests. A legitimate cancelled
            // flow can also be cancelled immediately from the app's account panel.
        }
    }

    private func reply(_ connection: NWConnection, id: UUID, status: String, message: String) {
        let body = Data(message.utf8)
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { @MainActor in self?.connections.removeValue(forKey: id) }
        })
    }
}
