import Foundation
import Network

/// A deliberately small HTTP/1.1 server for localhost: static files, JSON POST actions, and
/// server-sent events. No TLS, no keep-alive tricks, no external dependencies.
public final class MiniHTTP: @unchecked Sendable {
    public struct Request: Sendable { public var method: String; public var path: String; public var query: [String: String]; public var headers: [String: String]; public var body: Data }
    public struct Response: Sendable { public var status = 200; public var headers: [String: String] = [:]; public var body = Data()
        public static func json(_ obj: Any) -> Response { .init(headers: ["Content-Type": "application/json"], body: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)) }
        public static func text(_ s: String, status: Int = 200) -> Response { .init(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(s.utf8)) }
    }
    public typealias Handler = @Sendable (Request) async -> Response

    private let listener: NWListener
    private let queue = DispatchQueue(label: "emlex.http")
    private var routes: [(String, String, Handler)] = []        // method, path prefix, handler
    private var sseClients: [UUID: NWConnection] = [:]
    private let lock = NSLock()
    public private(set) var port: UInt16 = 0

    public init(port: UInt16) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
    }

    public func route(_ method: String, _ path: String, _ handler: @escaping Handler) { routes.append((method, path, handler)) }

    private final class Once: @unchecked Sendable { var done = false }

    public func start() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !once.done else { return }
                switch state {
                case .ready: once.done = true; self.port = self.listener.port?.rawValue ?? 0; c.resume()
                case .failed(let e): once.done = true; c.resume(throwing: e)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.start(queue: queue)
        }
    }

    public func stop() { listener.cancel() }

    // MARK: server-sent events

    /// Register `conn` as an SSE client; returns the id. The response headers are sent immediately.
    func beginSSE(_ conn: NWConnection) -> UUID {
        let id = UUID()
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        lock.lock(); sseClients[id] = conn; lock.unlock()
        return id
    }

    public func broadcast(event: String, json: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: json), let s = String(data: data, encoding: .utf8) else { return }
        let frame = Data("event: \(event)\ndata: \(s)\n\n".utf8)
        lock.lock(); let clients = sseClients; lock.unlock()
        for (id, conn) in clients {
            conn.send(content: frame, completion: .contentProcessed { [weak self] err in
                if err != nil { self?.lock.lock(); self?.sseClients[id] = nil; self?.lock.unlock() }
            })
        }
    }

    public var clientCount: Int { lock.lock(); defer { lock.unlock() }; return sseClients.count }

    // MARK: connection handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headText = String(decoding: buf[..<range.lowerBound], as: UTF8.self)
                var lines = headText.split(separator: "\r\n").map(String.init)
                let reqLine = lines.removeFirst().split(separator: " ").map(String.init)
                guard reqLine.count >= 2 else { conn.cancel(); return }
                var headers: [String: String] = [:]
                for l in lines { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                let bodyStart = range.upperBound
                if buf.count - bodyStart < length, !done, err == nil { self.readRequest(conn, buffer: buf); return }
                let body = buf[bodyStart..<min(buf.count, bodyStart + length)]
                let (path, query) = Self.split(reqLine[1])
                let req = Request(method: reqLine[0], path: path, query: query, headers: headers, body: Data(body))
                self.dispatch(req, conn)
            } else if done || err != nil { conn.cancel() } else { self.readRequest(conn, buffer: buf) }
        }
    }

    private func dispatch(_ req: Request, _ conn: NWConnection) {
        if req.method == "GET", req.path == "/events" { _ = beginSSE(conn); return }
        if req.method == "OPTIONS" { send(conn, .init(status: 204, headers: ["Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "Content-Type"])); return }
        guard let handler = routes.first(where: { $0.0 == req.method && (req.path == $0.1 || ($0.1.count > 1 && $0.1.hasSuffix("/") && req.path.hasPrefix($0.1))) })?.2 else {
            send(conn, .text("not found", status: 404)); return
        }
        Task { [req, conn] in let res = await handler(req); self.send(conn, res) }
    }

    private func send(_ conn: NWConnection, _ res: Response) {
        var head = "HTTP/1.1 \(res.status) \(res.status == 200 ? "OK" : res.status == 204 ? "No Content" : "Error")\r\n"
        var headers = res.headers
        headers["Content-Length"] = "\(res.body.count)"
        headers["Access-Control-Allow-Origin"] = "*"
        headers["Connection"] = "close"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        conn.send(content: Data(head.utf8) + res.body, completion: .contentProcessed { _ in conn.cancel() })
    }

    static func split(_ target: String) -> (String, [String: String]) {
        let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
        var q: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                q[kv[0]] = kv.count > 1 ? kv[1] : ""
            }
        }
        return (parts[0], q)
    }

    public static func mime(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js": "application/javascript"
        case "css": "text/css"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "woff2": "font/woff2"
        default: "application/octet-stream"
        }
    }
}
