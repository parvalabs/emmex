import Foundation
import FoundationModels
import MCP
import System

/// MCP server configuration, read from `~/.emmex/mcp.json` and `<workspace>/.emmex/mcp.json`
/// (Claude Desktop / Cursor format: {"mcpServers": {name: {command, args, env} | {url, headers}}}).
public struct MCPServerConfig: Codable, Sendable, Hashable, Identifiable {
    public var name: String = ""
    public var command: String?
    public var args: [String]?
    public var env: [String: String]?
    public var url: String?
    public var headers: [String: String]?
    public var disabled: Bool?
    /// Network for a sandboxed stdio server: "none", "all", or a list of domains (default: the
    /// package-manager defaults through the filtering proxy).
    public var network: NetworkSetting?
    public enum NetworkSetting: Codable, Sendable, Hashable {
        case mode(String), domains([String])
        public init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .mode(s) } else { self = .domains(try c.decode([String].self)) }
        }
        public func encode(to e: Encoder) throws {
            var c = e.singleValueContainer()
            switch self { case .mode(let s): try c.encode(s); case .domains(let l): try c.encode(l) }
        }
    }
    /// Set to false to run this server outside the sandbox (default true when sandboxing is on).
    public var sandbox: Bool?
    public var id: String { name }
    public var isRemote: Bool { url != nil }

    enum CodingKeys: String, CodingKey { case command, args, env, url, headers, disabled, network, sandbox }

    struct File: Codable { var mcpServers: [String: MCPServerConfig] }

    public static func load(workspace: URL?) -> [MCPServerConfig] {
        var files = [Paths.userConfig.appending(path: "mcp.json")]
        if let ws = workspace { files.append(Paths.projectConfig(ws).appending(path: "mcp.json")) }
        var out: [String: MCPServerConfig] = [:]
        for f in files {
            guard let data = try? Data(contentsOf: f), let parsed = try? JSONDecoder().decode(File.self, from: data) else { continue }
            for (name, var cfg) in parsed.mcpServers { cfg.name = name; out[name] = cfg }   // project overrides user
        }
        return out.values.filter { $0.disabled != true }.sorted { $0.name < $1.name }
    }
}

/// A connected MCP server: its process (for stdio), client, and the tools it exposes.
public actor MCPConnection {
    public let config: MCPServerConfig
    private var process: Process?
    private var pipes: (Pipe, Pipe)?
    private let client: Client
    public private(set) var tools: [MCP.Tool] = []
    public private(set) var serverInfo: String = ""
    public private(set) var sandboxed = false
    /// Workspace the server runs for; used for the sandbox's writable root.
    public var workspace: URL?
    public func setWorkspace(_ ws: URL?) { workspace = ws }

    public init(config: MCPServerConfig) {
        self.config = config
        client = Client(name: "emmex", version: "0.1.0", capabilities: .init(elicitation: nil))
    }

    public func connect() async throws {
        let transport: any Transport
        if let url = config.url {
            guard let endpoint = URL(string: url) else { throw EmmexError.badModelSpec("mcp url \(url)") }
            let headers = config.headers ?? [:]
            transport = HTTPClientTransport(endpoint: endpoint, requestModifier: { req in
                var r = req
                for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
                return r
            })
        } else {
            guard let command = config.command else { throw EmmexError.badModelSpec("mcp server \(config.name) has neither command nor url") }
            let p = Process()
            var env = ProcessInfo.processInfo.environment
            // Login-shell PATH so npx/uvx installed by Homebrew or nvm are found from a GUI app.
            if let path = Self.loginPath() { env["PATH"] = path }
            for (k, v) in config.env ?? [:] { env[k] = v }
            if config.sandbox != false, Settings.load().sandbox, Sandbox.isAvailable, let ws = workspace {
                // Same confinement as shell commands: writes only in the workspace and temp, no
                // credential reads, network only through the filtering proxy.
                var proxyURL: String? = nil; var port: UInt16? = nil
                var wants = true; var allowAll = false; var domains = NetworkDefaults.domains + Settings.load().network.allowedDomains
                switch config.network ?? .domains([]) {
                case .mode("none"): wants = false
                case .mode("all"): allowAll = true
                case .domains(let d): domains += d
                default: break
                }
                if wants, let px = await SandboxRuntime.shared.proxyInstance() {
                    let token = px.register(.init(allowedDomains: domains, allowAll: allowAll)); proxyURL = px.url(token: token); port = px.port
                }
                let sb = Sandbox(workspace: ws, cwd: ws, tempDir: await SandboxRuntime.shared.tempDir(session: "mcp-\(config.name)"), proxyPort: port)
                let (exe, args, sbEnv) = sb.arguments(for: "true", proxyURL: proxyURL)
                // Run the server binary directly under the profile: sandbox-exec -p <profile> env <command> <args>.
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = [args[0], args[1], "/usr/bin/env", command] + (config.args ?? [])
                for k in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy", "NO_PROXY", "no_proxy", "TMPDIR", "EMMEX_SANDBOX"] { if let v = sbEnv[k] { env[k] = v } }
                sandboxed = true
            } else {
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = [command] + (config.args ?? [])
            }
            p.environment = env
            let toServer = Pipe(), fromServer = Pipe()
            p.standardInput = toServer; p.standardOutput = fromServer
            p.standardError = FileHandle.standardError
            try p.run()
            process = p; pipes = (toServer, fromServer)
            transport = StdioTransport(
                input: FileDescriptor(rawValue: fromServer.fileHandleForReading.fileDescriptor),
                output: FileDescriptor(rawValue: toServer.fileHandleForWriting.fileDescriptor))
        }
        let result = try await client.connect(transport: transport)
        serverInfo = "\(result.serverInfo.name) \(result.serverInfo.version)"
        tools = try await client.listTools().tools
    }

    public func call(_ name: String, arguments: [String: Value]) async throws -> String {
        let (content, isError) = try await client.callTool(name: name, arguments: arguments)
        var parts: [String] = []
        for item in content {
            switch item {
            case .text(let text, _, _): parts.append(text)
            case .image(_, let mime, _, _): parts.append("[image \(mime)]")
            case .audio(_, let mime, _, _): parts.append("[audio \(mime)]")
            case .resource(let res, _, _): parts.append(res.text ?? "[resource \(res.uri)]")
            case .resourceLink(let uri, let name, _, _, _, _): parts.append("[resource link \(name): \(uri)]")
            }
        }
        let text = parts.joined(separator: "\n")
        return isError == true ? "error: \(text)" : text
    }

    public func disconnect() async {
        await client.disconnect()
        process?.terminate()
        process = nil
    }

    static func loginPath() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-lc", "echo $PATH"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}

/// A FoundationModels tool backed by an MCP server tool. Name is `<server>__<tool>`.
public struct MCPTool: FoundationModels.Tool {
    public let name: String
    public let description: String
    public let parameters: GenerationSchema
    let connection: MCPConnection
    let remoteName: String
    let ctx: ToolContext

    init(connection: MCPConnection, tool: MCP.Tool, ctx: ToolContext) throws {
        self.connection = connection
        remoteName = tool.name
        let server = connection.config.name
        name = Self.sanitize("\(server)__\(tool.name)")
        description = tool.description ?? tool.title ?? tool.name
        parameters = try JSONSchema.generationSchema(name: Self.sanitize("\(server)_\(tool.name)_args"), from: tool.inputSchema)
        self.ctx = ctx
    }

    static func looksMutating(_ tool: String) -> Bool {
        let t = tool.lowercased()
        return ["write", "delete", "remove", "move", "create", "edit", "update", "run", "execute", "send", "post", "put", "patch", "push", "deploy", "install"].contains { t.contains($0) }
    }

    static func sanitize(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
    }

    public func call(arguments: GeneratedContent) async throws -> String {
        let value = try JSONSchema.value(from: arguments)
        ctx.report(.toolCall(name: name, arguments: String(arguments.jsonString.prefix(300))))
        if let policy = ctx.policy, await policy.level == .ask || Self.looksMutating(remoteName) {
            if await policy.level != .full, let refusal = await ctx.gate(.init(id: UUID().uuidString, tool: name, summary: "\(name) \(arguments.jsonString.prefix(120))", command: nil, paths: [])) {
                ctx.report(.toolResult(name: name, output: refusal)); return refusal
            }
        }
        let result = ctx.clip(try await connection.call(remoteName, arguments: value.objectValue ?? [:]))
        ctx.report(.toolResult(name: name, output: result))
        return result
    }
}

/// Connects every configured server for a workspace and exposes their tools.
public actor MCPHost {
    public private(set) var connections: [MCPConnection] = []
    public private(set) var failures: [String: String] = [:]

    public init() {}

    public func connect(workspace: URL?, log: (@Sendable (String) -> Void)? = nil) async {
        for cfg in MCPServerConfig.load(workspace: workspace) {
            let c = MCPConnection(config: cfg)
            await c.setWorkspace(workspace)
            do {
                try await c.connect()
                connections.append(c)
                log?("mcp: \(cfg.name) connected, \(await c.tools.count) tools\(await c.sandboxed ? " (sandboxed)" : "")")
            } catch {
                failures[cfg.name] = "\(error)"
                log?("mcp: \(cfg.name) failed: \(error)")
            }
        }
    }

    public func tools(ctx: ToolContext) async -> [any FoundationModels.Tool] {
        var out: [any FoundationModels.Tool] = []
        for c in connections {
            for t in await c.tools {
                if let tool = try? MCPTool(connection: c, tool: t, ctx: ctx) { out.append(tool) }
            }
        }
        return out
    }

    public func summary() async -> [(server: String, info: String, tools: [String])] {
        var out: [(String, String, [String])] = []
        for c in connections { out.append((c.config.name, await c.serverInfo, await c.tools.map(\.name))) }
        return out
    }

    public func disconnectAll() async {
        for c in connections { await c.disconnect() }
        connections = []
    }
}
