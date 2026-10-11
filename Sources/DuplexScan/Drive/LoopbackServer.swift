import Foundation
import Network

/// A value delivered once from a callback, awaited with timeout and task cancellation.
final class OneShot<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?

    func resolve(_ value: Result<T, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: value)
    }

    func value(timeout: TimeInterval, timeoutMessage: String) async throws -> T {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.resolve(.failure(AppError(timeoutMessage)))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            self.resolve(.failure(CancellationError()))
        }
    }
}

/// Minimal HTTP/1.1 server bound to 127.0.0.1 for the OAuth redirect and the Google Picker page.
final class LoopbackServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data
    }

    struct Response {
        var status: Int
        var contentType = "text/plain; charset=utf-8"
        var body = Data()

        static func html(_ html: String, status: Int = 200) -> Response {
            Response(status: status, contentType: "text/html; charset=utf-8", body: Data(html.utf8))
        }

        static func message(_ text: String, status: Int = 200) -> Response {
            let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            return html("<!doctype html><meta charset=\"utf-8\"><title>Duplex Scan</title><p style=\"font:16px -apple-system,sans-serif;margin:40px\">\(escaped)</p>", status: status)
        }

        static func status(_ code: Int) -> Response { Response(status: code) }
    }

    private enum ParseResult {
        case incomplete, invalid, request(Request)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackServer")
    private let handler: (Request) -> Response
    private static let maxRequestSize = 1_000_000

    init(port: UInt16, handler: @escaping (Request) -> Response) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    func start() async throws {
        let ready = OneShot<Void>()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.resolve(.success(()))
            case .failed(let error), .waiting(let error):
                ready.resolve(.failure(AppError("Could not listen on 127.0.0.1 (\(error.localizedDescription)). Is the port in use?")))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        try await ready.value(timeout: 10, timeoutMessage: "Timed out starting the local sign-in server.")
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch Self.parse(buffer) {
            case .request(let request):
                self.send(self.handler(request), on: connection)
            case .invalid:
                self.send(.status(400), on: connection)
            case .incomplete:
                if isComplete || error != nil || buffer.count > Self.maxRequestSize {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func send(_ response: Response, on connection: NWConnection) {
        let reason = HTTPURLResponse.localizedString(forStatusCode: response.status).capitalized
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func parse(_ data: Data) -> ParseResult {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data.subdata(in: data.startIndex..<headerEnd.lowerBound), encoding: .utf8) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2, let components = URLComponents(string: "http://127.0.0.1" + requestLine[1]) else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxRequestSize else { return .invalid }
        let bodyStart = headerEnd.upperBound
        guard data.endIndex - bodyStart >= length else { return .incomplete }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .request(Request(method: String(requestLine[0]), path: components.path, query: query, headers: headers,
                                body: data.subdata(in: bodyStart..<(bodyStart + length))))
    }
}
