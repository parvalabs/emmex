import Foundation
import EmlexCore

/// Serves the web UI and wires HTTP actions and SSE to an AppController.
public final class WebApp: @unchecked Sendable {
    public let http: MiniHTTP
    public let controller: AppController
    public let webRoot: URL
    public var url: URL { URL(string: "http://127.0.0.1:\(http.port)/")! }

    /// Web assets shipped with the package (Resources/web). Falls back to the source tree
    /// during development if the resource bundle is missing.
    public static var bundledWebRoot: URL {
        if let u = Bundle.module.url(forResource: "web", withExtension: nil) { return u }
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Resources/web")
        FileHandle.standardError.write(Data("[emlex] web resources not in bundle, using \(src.path)\n".utf8))
        return src
    }

    @MainActor
    public init(port: UInt16 = 0, webRoot: URL? = nil, controller: AppController = AppController()) throws {
        self.http = try MiniHTTP(port: port)
        self.controller = controller
        self.webRoot = webRoot ?? Self.bundledWebRoot
        let root = self.webRoot
        let http = self.http
        controller.emit = { [http] event, json in http.broadcast(event: event, json: json) }

        http.route("GET", "/") { _ in Self.file(root.appending(path: "index.html")) }
        http.route("GET", "/static/") { req in Self.file(root.appending(path: String(req.path.dropFirst("/static/".count)))) }
        http.route("GET", "/debug") { [http] _ in .json(["sseClients": http.clientCount, "port": Int(http.port)]) }
        http.route("GET", "/state") { [controller] _ in .init(headers: ["Content-Type": "application/json"], body: await controller.snapshotData()) }
        http.route("POST", "/action") { [controller] req in
            let body = req.body
            let data = await controller.handleData((try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:])
            return .init(headers: ["Content-Type": "application/json"], body: data)
        }
    }

    public func start() async throws { try await http.start() }

    static func file(_ url: URL) -> MiniHTTP.Response {
        guard let data = try? Data(contentsOf: url) else { return .text("not found", status: 404) }
        return .init(headers: ["Content-Type": MiniHTTP.mime(url.path), "Cache-Control": "no-cache"], body: data)
    }
}
