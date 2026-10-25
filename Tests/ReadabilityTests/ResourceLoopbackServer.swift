import Foundation
import Network

/// Main-actor isolation owns counters and lifecycle; Network callbacks hop back
/// to that actor. No unchecked Sendable conformance is needed in the test server.
@MainActor
final class ResourceLoopbackServer {
    private let listener: NWListener
    private var ready: CheckedContinuation<Void, any Error>?
    private(set) var requests: [String: Int] = [:]
    var delay: TimeInterval = 0
    var unavailable = false
    var dynamicScript = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var origin: String { "http://127.0.0.1:\(listener.port!.rawValue)" }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.ready?.resume()
                        self.ready = nil
                    case .failed(let error):
                        self.ready?.resume(throwing: error)
                        self.ready = nil
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    connection.start(queue: .main)
                    self?.receive(connection, accumulated: Data())
                }
            }
            listener.start(queue: .main)
        }
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                let bytes = accumulated + (data ?? Data())
                guard let header = String(data: bytes, encoding: .utf8), header.contains("\r\n\r\n") else {
                    if complete || error != nil { connection.cancel() }
                    else { self.receive(connection, accumulated: bytes) }
                    return
                }
                let path = header.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                self.requests[path, default: 0] += 1
                let (type, body) = self.response(for: path)
                let status = self.unavailable ? "503 Service Unavailable" : "200 OK"
                let response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n".utf8) + body
                DispatchQueue.main.asyncAfter(deadline: .now() + self.delay) {
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
    }

    private func response(for path: String) -> (String, Data) {
        if path == "/main" {
            let paragraph = String(repeating: "The main document is downloaded by URLSession before WebKit extracts its editorial content. ", count: 15)
            let html = "<html><head><title>Main HTML download</title></head><body><article><h1>Main HTML download</h1><p>\(paragraph)</p><figure><img src='\(origin)/main-photo.png' width='800' height='600'><figcaption>Editorial caption.</figcaption></figure></article></body></html>"
            return ("text/html", Data(html.utf8))
        }
        if path.contains(".css") {
            return ("text/css", Data("p { color: rgb(10,20,30); }".utf8))
        }
        if path.contains(".js") {
            let script = dynamicScript
                ? "document.querySelector('article').insertAdjacentHTML('beforeend', '<p>EXTERNAL_EDITORIAL_SECTION \(String(repeating: "Additional verified editorial content. ", count: 20))</p>');"
                : "window.__externalProbeLoaded = true;"
            return ("application/javascript", Data(script.utf8))
        }
        if path.contains(".png") {
            return ("image/png", Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aY1sAAAAASUVORK5CYII=")!)
        }
        if path.contains(".woff2") { return ("font/woff2", Data([0, 1, 2, 3])) }
        if path.contains(".mp4") { return ("video/mp4", Data([0, 1, 2, 3])) }
        return ("text/html", Data("<html><body>Secondary document.</body></html>".utf8))
    }
}
