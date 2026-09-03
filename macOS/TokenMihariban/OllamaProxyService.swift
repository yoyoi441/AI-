import Foundation
import Network
import ClaudeUsageCore

enum OllamaProxyState: Equatable {
    case stopped
    case starting
    case running
    case failed(String)

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Opt-in HTTP/1.1 proxy used because Ollama has per-response metrics but no cumulative
/// usage-history endpoint. It never persists request or response text; only the final
/// token counters parsed into `OllamaUsageEvent` leave the connection object.
final class OllamaProxyService: @unchecked Sendable {
    static let localPort: UInt16 = 11435
    static let cloudPort: UInt16 = 11436

    private let queue = DispatchQueue(label: "com.yoyoi441.TokenMihariban.ollama-proxy")
    private let eventHandler: @Sendable (OllamaUsageEvent) -> Void
    private let stateHandler: @Sendable (OllamaProxyState) -> Void
    private var listeners: [NWListener] = []
    private var readyCount = 0

    init(
        eventHandler: @escaping @Sendable (OllamaUsageEvent) -> Void,
        stateHandler: @escaping @Sendable (OllamaProxyState) -> Void
    ) {
        self.eventHandler = eventHandler
        self.stateHandler = stateHandler
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.listeners.isEmpty else { return }
            self.stateHandler(.starting)
            do {
                try self.startListener(
                    port: Self.localPort,
                    backend: URL(string: "http://127.0.0.1:11434")!,
                    forceCloud: false
                )
                try self.startListener(
                    port: Self.cloudPort,
                    backend: URL(string: "https://ollama.com")!,
                    forceCloud: true
                )
            } catch {
                self.stopLocked()
                self.stateHandler(.failed(error.localizedDescription))
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
            self?.stateHandler(.stopped)
        }
    }

    private func startListener(port: UInt16, backend: URL, forceCloud: Bool) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [eventHandler] connection in
            let handler = OllamaProxyConnection(
                connection: connection,
                backend: backend,
                forceCloud: forceCloud,
                eventHandler: eventHandler
            )
            handler.start()
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                switch state {
                case .ready:
                    self.readyCount += 1
                    if self.readyCount == 2 { self.stateHandler(.running) }
                case .failed(let error):
                    self.stateHandler(.failed(error.localizedDescription))
                default:
                    break
                }
            }
        }
        listeners.append(listener)
        listener.start(queue: queue)
    }

    private func stopLocked() {
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
        readyCount = 0
    }

    deinit { listeners.forEach { $0.cancel() } }
}

private final class OllamaProxyConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct ParsedRequest {
        let method: String
        let path: String
        let headers: [(String, String)]
        let body: Data
    }

    private let connection: NWConnection
    private let backend: URL
    private let forceCloud: Bool
    private let eventHandler: @Sendable (OllamaUsageEvent) -> Void
    private let requestId = UUID().uuidString
    private var incoming = Data()
    private var capturedResponse = Data()
    private var requestedModel: String?
    private var responseStarted = false
    private var session: URLSession?
    private var selfRetain: OllamaProxyConnection?

    init(
        connection: NWConnection,
        backend: URL,
        forceCloud: Bool,
        eventHandler: @escaping @Sendable (OllamaUsageEvent) -> Void
    ) {
        self.connection = connection
        self.backend = backend
        self.forceCloud = forceCloud
        self.eventHandler = eventHandler
    }

    func start() {
        selfRetain = self
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.receiveRequest()
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .utility))
    }

    private func receiveRequest() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.incoming.append(data) }
            if self.incoming.count > 16 * 1_048_576 {
                self.sendError(status: 413, message: "Request too large")
                return
            }
            if let parsed = self.parseRequest() {
                self.forward(parsed)
            } else if error != nil || isComplete {
                self.sendError(status: 400, message: "Invalid HTTP request")
            } else {
                self.receiveRequest()
            }
        }
    }

    private func parseRequest() -> ParsedRequest? {
        let delimiter = Data([13, 10, 13, 10])
        guard let headerRange = incoming.range(of: delimiter),
              let headerText = String(data: incoming[..<headerRange.lowerBound], encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let requestParts = first.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count == 3 else { return nil }

        var headers: [(String, String)] = []
        var contentLength = 0
        var chunked = false
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
            if name.caseInsensitiveCompare("Content-Length") == .orderedSame { contentLength = Int(value) ?? 0 }
            if name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame && value.lowercased().contains("chunked") { chunked = true }
        }
        if chunked {
            sendError(status: 411, message: "Chunked request bodies are not supported")
            return nil
        }
        let bodyStart = headerRange.upperBound
        guard incoming.count >= bodyStart + contentLength else { return nil }
        return ParsedRequest(
            method: requestParts[0],
            path: requestParts[1],
            headers: headers,
            body: incoming.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }

    private func forward(_ parsed: ParsedRequest) {
        guard var components = URLComponents(url: backend, resolvingAgainstBaseURL: false) else {
            sendError(status: 502, message: "Invalid Ollama backend")
            return
        }
        let pathAndQuery = parsed.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        components.path = String(pathAndQuery[0])
        components.percentEncodedQuery = pathAndQuery.count > 1 ? String(pathAndQuery[1]) : nil
        guard let url = components.url else {
            sendError(status: 400, message: "Invalid request path")
            return
        }

        if let object = try? JSONSerialization.jsonObject(with: parsed.body) as? [String: Any] {
            requestedModel = object["model"] as? String
        }

        var request = URLRequest(url: url)
        request.httpMethod = parsed.method
        request.httpBody = parsed.body.isEmpty ? nil : parsed.body
        for (name, value) in parsed.headers where !Self.hopByHopHeaders.contains(name.lowercased()) && name.caseInsensitiveCompare("Host") != .orderedSame {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60 * 60
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        session.dataTask(with: request).resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            sendError(status: 502, message: "Invalid Ollama response")
            return
        }
        var text = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\n"
        for (rawName, rawValue) in http.allHeaderFields {
            let name = String(describing: rawName)
            guard !Self.hopByHopHeaders.contains(name.lowercased()), name.caseInsensitiveCompare("Content-Length") != .orderedSame else { continue }
            text += "\(name): \(rawValue)\r\n"
        }
        text += "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        responseStarted = true
        send(Data(text.utf8))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if capturedResponse.count + data.count <= 128 * 1_048_576 { capturedResponse.append(data) }
        var chunk = Data(String(format: "%X\r\n", data.count).utf8)
        chunk.append(data)
        chunk.append(Data([13, 10]))
        send(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let event = OllamaUsageResponseParser.parse(
            capturedResponse,
            requestedModel: requestedModel,
            forceCloud: forceCloud,
            requestId: requestId
        ) {
            eventHandler(event)
        }
        if responseStarted {
            send(Data("0\r\n\r\n".utf8), final: true)
        } else if let error {
            sendError(status: 502, message: error.localizedDescription)
        } else {
            sendError(status: 502, message: "Ollama did not return a response")
        }
    }

    private func send(_ data: Data, final: Bool = false) {
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            if final { self?.finish() }
        })
    }

    private func sendError(status: Int, message: String) {
        let body = Data("{\"error\":\"\(message.replacingOccurrences(of: "\"", with: "'"))\"}".utf8)
        let response = "HTTP/1.1 \(status) Error\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(response.utf8)
        data.append(body)
        send(data, final: true)
    }

    private func finish() {
        session?.invalidateAndCancel()
        session = nil
        connection.cancel()
        selfRetain = nil
    }

    private static let hopByHopHeaders: Set<String> = [
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade"
    ]
}
