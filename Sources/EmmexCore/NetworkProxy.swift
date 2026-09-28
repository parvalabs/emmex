import Foundation
import Network

/// A localhost HTTP proxy that is the only network path out of the sandbox. Sandboxed commands
/// get HTTP_PROXY/HTTPS_PROXY pointing here; the Seatbelt profile allows egress only to this
/// port. The proxy enforces a domain allowlist and refuses connections that resolve to
/// loopback, link-local, or cloud-metadata addresses. Supports CONNECT (TLS tunnels) and plain
/// absolute-URI HTTP requests.
public final class NetworkProxy: @unchecked Sendable {
    public struct Policy: Sendable {
        public var allowedDomains: [String]      // "registry.npmjs.org", "*.github.com"
        public var allowAll: Bool
        public init(allowedDomains: [String], allowAll: Bool = false) { self.allowedDomains = allowedDomains; self.allowAll = allowAll }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "emmex.proxy")
    private let lock = NSLock()
    private var policies: [String: Policy] = [:]       // token -> policy (one per command)
    /// Used when a client sends no proxy credentials (git and some SDKs only send them after a
    /// 407 challenge, which we do not issue): the most recently registered policy.
    private var fallback: Policy?
    public private(set) var port: UInt16 = 0
    public private(set) var denials: [(token: String, host: String, reason: String)] = []

    public init() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params, on: .any)
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { [weak self] st in
                guard let self, !once.done else { return }
                switch st {
                case .ready: once.done = true; self.port = self.listener.port?.rawValue ?? 0; c.resume()
                case .failed(let e): once.done = true; c.resume(throwing: e)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.start(queue: queue)
        }
    }
    private final class Once: @unchecked Sendable { var done = false }

    /// Register a per-command policy; the token goes into the proxy URL as a username so
    /// denials can be attributed to the command that caused them.
    public func register(_ policy: Policy) -> String {
        let token = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        lock.lock(); policies[token] = policy; fallback = policy; lock.unlock()
        return token
    }
    public func unregister(_ token: String) { lock.lock(); policies[token] = nil; lock.unlock() }
    public func denials(for token: String) -> [(host: String, reason: String)] {
        lock.lock(); defer { lock.unlock() }
        return denials.filter { $0.token == token }.map { ($0.host, $0.reason) }
    }

    public func url(token: String) -> String { "http://\(token):x@127.0.0.1:\(port)" }

    // MARK: connection handling

    private func accept(_ client: NWConnection) {
        client.start(queue: queue)
        readHead(client, buffer: Data())
    }

    private func readHead(_ client: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer; if let data { buf.append(data) }
            guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if done || err != nil || buf.count > 65536 { client.cancel() } else { self.readHead(client, buffer: buf) }
                return
            }
            let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
            let rest = buf[end.upperBound...]
            self.handle(head: head, rest: Data(rest), client: client)
        }
    }

    private func handle(head: String, rest: Data, client: NWConnection) {
        let lines = head.split(separator: "\r\n").map(String.init)
        guard let req = lines.first?.split(separator: " ").map(String.init), req.count >= 2 else { client.cancel(); return }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        let token = Self.token(from: headers["proxy-authorization"])
        let method = req[0], target = req[1]
        let host: String, port: UInt16, forward: Data
        if method == "CONNECT" {
            let hp = target.split(separator: ":"); host = String(hp[0]); port = UInt16(hp.count > 1 ? String(hp[1]) : "443") ?? 443
            forward = Data()
        } else {
            guard let u = URL(string: target), let h = u.host else { reply(client, "400 Bad Request"); return }
            host = h; port = UInt16(u.port ?? 80)
            // Rewrite the absolute-URI request line into an origin-form request for the upstream.
            let path = (u.path.isEmpty ? "/" : u.path) + (u.query.map { "?" + $0 } ?? "")
            var out = "\(method) \(path) \(req.count > 2 ? req[2] : "HTTP/1.1")\r\n"
            for l in lines.dropFirst() where !l.lowercased().hasPrefix("proxy-") { out += l + "\r\n" }
            out += "\r\n"
            forward = Data(out.utf8) + rest
        }
        guard let policy = policy(for: token) else { deny(client, token: token, host: host, reason: "unknown proxy token"); return }
        if !policy.allowAll, !Self.matches(host: host, allowed: policy.allowedDomains) { deny(client, token: token, host: host, reason: "domain not allowed"); return }
        // Resolve first so a permitted name cannot point at a private or metadata address.
        Self.resolve(host) { [weak self] addrs in
            guard let self else { return }
            if addrs.isEmpty { self.deny(client, token: token, host: host, reason: "could not resolve"); return }
            if let bad = addrs.first(where: Self.isForbiddenAddress) { self.deny(client, token: token, host: host, reason: "resolves to \(bad) (private or metadata address)"); return }
            let upstream = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            upstream.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    if method == "CONNECT" {
                        client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in
                            if !rest.isEmpty { upstream.send(content: rest, completion: .contentProcessed { _ in }) }
                            Self.pipe(client, upstream); Self.pipe(upstream, client)
                        })
                    } else {
                        upstream.send(content: forward, completion: .contentProcessed { _ in Self.pipe(client, upstream); Self.pipe(upstream, client) })
                    }
                case .failed, .cancelled: client.cancel()
                default: break
                }
            }
            upstream.start(queue: self.queue)
        }
    }

    private static func pipe(_ from: NWConnection, _ to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, err in
            if let data, !data.isEmpty { to.send(content: data, completion: .contentProcessed { _ in }) }
            if done || err != nil { to.cancel(); from.cancel(); return }
            pipe(from, to)
        }
    }

    private func reply(_ client: NWConnection, _ status: String, body: String = "") {
        let s = "HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        client.send(content: Data(s.utf8), completion: .contentProcessed { _ in client.cancel() })
    }

    private func deny(_ client: NWConnection, token: String, host: String, reason: String) {
        lock.lock(); denials.append((token, host, reason)); if denials.count > 500 { denials.removeFirst(100) }; lock.unlock()
        reply(client, "403 Forbidden", body: "emmex sandbox: \(host) blocked (\(reason))")
    }

    private func policy(for token: String) -> Policy? { lock.lock(); defer { lock.unlock() }; return policies[token] ?? (token.isEmpty ? fallback : nil) }

    static func token(from auth: String?) -> String {
        guard let auth, auth.lowercased().hasPrefix("basic "), let d = Data(base64Encoded: String(auth.dropFirst(6)).trimmingCharacters(in: .whitespaces)) else { return "" }
        return String(decoding: d, as: UTF8.self).split(separator: ":").first.map(String.init) ?? ""
    }

    /// `*.github.com` matches subdomains and the apex; plain names match exactly.
    public static func matches(host: String, allowed: [String]) -> Bool {
        let h = host.lowercased()
        return allowed.contains { p in
            let p = p.lowercased()
            if p == "*" { return true }
            if p.hasPrefix("*.") { let base = String(p.dropFirst(2)); return h == base || h.hasSuffix("." + base) }
            return h == p
        }
    }

    static func resolve(_ host: String, _ done: @escaping ([String]) -> Void) {
        DispatchQueue.global().async {
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var res: UnsafeMutablePointer<addrinfo>? = nil
            guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { done([]); return }
            defer { freeaddrinfo(first) }
            var out: [String] = []
            var p: UnsafeMutablePointer<addrinfo>? = first
            while let a = p {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(a.pointee.ai_addr, a.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 { out.append(String(cString: buf)) }
                p = a.pointee.ai_next
            }
            done(out)
        }
    }

    /// Loopback, link-local (incl. 169.254.169.254 metadata), RFC1918, ULA, and IPv6 loopback.
    static func isForbiddenAddress(_ ip: String) -> Bool {
        if ip == "::1" || ip.hasPrefix("fe80:") || ip.hasPrefix("fc") || ip.hasPrefix("fd") { return true }
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 127 || parts[0] == 10 || parts[0] == 0 { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 100 && (64...127).contains(parts[1]) { return true }
        return false
    }
}

/// Domains package managers and VCS need; the base allowlist for commands granted network.
public enum NetworkDefaults {
    public static let domains: [String] = [
        "github.com", "*.github.com", "*.githubusercontent.com", "ghcr.io", "*.ghcr.io", "gitlab.com", "*.gitlab.com", "bitbucket.org",
        "registry.npmjs.org", "*.npmjs.org", "registry.yarnpkg.com", "*.yarnpkg.com",
        "pypi.org", "*.pypi.org", "files.pythonhosted.org", "*.pythonhosted.org",
        "crates.io", "*.crates.io", "static.crates.io", "index.crates.io",
        "proxy.golang.org", "sum.golang.org", "storage.googleapis.com", "go.dev", "*.golang.org",
        "rubygems.org", "*.rubygems.org", "packagist.org", "*.packagist.org", "repo.maven.apache.org", "*.maven.org", "plugins.gradle.org", "*.gradle.org",
        "formulae.brew.sh", "*.brew.sh", "*.homebrew.org", "cdn.jsdelivr.net", "unpkg.com",
        "huggingface.co", "*.huggingface.co", "*.hf.co",
        "swift.org", "*.swift.org", "developer.apple.com", "*.apple.com",
        "api.anthropic.com", "api.openai.com", "*.amazonaws.com",
    ]
}
