import Foundation
import FoundationModels

/// Macro-free schema helpers so tools can be defined at runtime and the package builds
/// without the FoundationModels macro plugin.
public enum SchemaBuilder {
    public static func object(_ name: String, _ props: [(String, String, DynamicGenerationSchema)]) throws -> GenerationSchema {
        try GenerationSchema(
            root: DynamicGenerationSchema(name: name, properties: props.map { .init(name: $0.0, description: $0.1, schema: $0.2) }),
            dependencies: [])
    }
    public static var string: DynamicGenerationSchema { DynamicGenerationSchema(type: String.self) }
    public static var int: DynamicGenerationSchema { DynamicGenerationSchema(type: Int.self) }
    public static func choice(_ name: String, _ options: [String]) -> DynamicGenerationSchema {
        DynamicGenerationSchema(name: name, anyOf: options)
    }
}

/// Pi's default tool set: bash, read, write, edit.
public enum Tools {
    public static func standard(_ ctx: ToolContext) -> [any Tool] {
        [BashTool(ctx), ReadFileTool(ctx), WriteFileTool(ctx), EditFileTool(ctx)]
    }
}

public struct BashTool: Tool {
    public let name = "bash"
    public let description = "Run a shell command in the working directory and return exit code, stdout and stderr."
    let ctx: ToolContext
    public init(_ ctx: ToolContext) { self.ctx = ctx }
    public var parameters: GenerationSchema {
        try! SchemaBuilder.object("BashArgs", [("command", "The shell command to run", SchemaBuilder.string)])
    }
    public func call(arguments: GeneratedContent) async throws -> String {
        let command = try arguments.value(String.self, forProperty: "command")
        ctx.report(.toolCall(name: name, arguments: command))
        if let refusal = await ctx.gate(.init(id: UUID().uuidString, tool: name, summary: command, command: command, paths: [])) {
            ctx.report(.toolResult(name: name, output: refusal)); return refusal
        }
        var (status, out, sandboxed, denials) = try await Self.execute(command, ctx: ctx, sandboxed: true)
        if !denials.isEmpty { out += "\n[sandbox] network blocked: " + denials.joined(separator: ", ") }
        if sandboxed, status != 0, out.contains("Operation not permitted") {
            out += "\n[sandbox] an operation was denied by the sandbox (writes are limited to the workspace and temp; credentials are unreadable)."
            // Escape hatch: rerun unsandboxed, gated by approval (automatic with an audit line in full mode).
            if Settings.load().unsandboxedRetry, let policy = ctx.policy {
                let full = await policy.level == .full
                let req = ToolRequest(id: UUID().uuidString, tool: name, summary: "retry unsandboxed: \(command)", command: nil, paths: [],
                                      reason: "the sandbox denied this command; rerun it without the sandbox?")
                var allowed = full
                if full { ctx.report(.approvalResolved(id: req.id, allowed: true, layer: "full: unsandboxed retry")) }
                else if let approver = ctx.approver {
                    ctx.report(.approvalNeeded(req))
                    let (ok, _) = await approver(req)
                    ctx.report(.approvalResolved(id: req.id, allowed: ok, layer: ok ? "user: unsandboxed retry" : "user denied unsandboxed retry"))
                    allowed = ok
                }
                if allowed {
                    let (s2, o2, _, _) = try await Self.execute(command, ctx: ctx, sandboxed: false)
                    status = s2; out = o2 + "\n[ran unsandboxed after approval]"
                }
            }
        }
        let result = "exit=\(status)\n\(out)"
        ctx.report(.toolResult(name: name, output: result))
        return result
    }

    /// Run a command, sandboxed or not. Returns (exit status, clipped output, was sandboxed, proxy denials).
    static func execute(_ command: String, ctx: ToolContext, sandboxed: Bool) async throws -> (Int32, String, Bool, [String]) {
        let p = Process()
        var proxyToken: String? = nil
        var proxy: NetworkProxy? = nil
        var didSandbox = false
        if sandboxed, let policy = ctx.policy, Settings.load().sandbox, Sandbox.isAvailable {
            let full = await policy.level == .full
            let wantsNetwork = full || NetworkPolicy.needsNetwork(command)
            var proxyURL: String? = nil
            if wantsNetwork, let px = await SandboxRuntime.shared.proxyInstance() {
                let domains = NetworkDefaults.domains + Settings.load().network.allowedDomains + (await policy.allowedDomains)
                let token = px.register(.init(allowedDomains: domains, allowAll: full))
                proxyToken = token; proxy = px; proxyURL = px.url(token: token)
            }
            let sb = Sandbox(workspace: await policy.workspace, cwd: URL(fileURLWithPath: ctx.cwd),
                             tempDir: await SandboxRuntime.shared.tempDir(session: ctx.sessionID), proxyPort: proxyURL == nil ? nil : proxy?.port)
            let (exe, args, env) = sb.arguments(for: command, proxyURL: proxyURL)
            p.executableURL = URL(fileURLWithPath: exe); p.arguments = args; p.environment = env
            didSandbox = true
        } else {
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
        }
        p.currentDirectoryURL = URL(fileURLWithPath: ctx.cwd)
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = ctx.clip(String(decoding: data, as: UTF8.self))
        var denials: [String] = []
        if let proxyToken, let proxy { denials = proxy.denials(for: proxyToken).map { "\($0.host) (\($0.reason))" }; proxy.unregister(proxyToken) }
        return (p.terminationStatus, out, didSandbox, denials)
    }
}

public struct ReadFileTool: Tool {
    public let name = "read_file"
    public let description = "Read a text file. Path is relative to the working directory, or absolute."
    let ctx: ToolContext
    public init(_ ctx: ToolContext) { self.ctx = ctx }
    public var parameters: GenerationSchema {
        try! SchemaBuilder.object("ReadArgs", [("path", "Relative file path", SchemaBuilder.string)])
    }
    public func call(arguments: GeneratedContent) async throws -> String {
        let path = try arguments.value(String.self, forProperty: "path")
        ctx.report(.toolCall(name: name, arguments: path))
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: ctx.cwd).appendingPathComponent(path)
        let result: String
        do { result = ctx.clip(try String(contentsOf: url, encoding: .utf8)) }
        catch { result = "error: \(error.localizedDescription)" }
        ctx.report(.toolResult(name: name, output: result))
        return result
    }
}

public struct WriteFileTool: Tool {
    public let name = "write_file"
    public let description = "Create or overwrite a text file with the given content. Path is relative to the working directory."
    let ctx: ToolContext
    public init(_ ctx: ToolContext) { self.ctx = ctx }
    public var parameters: GenerationSchema {
        try! SchemaBuilder.object("WriteArgs", [
            ("path", "Relative file path", SchemaBuilder.string),
            ("content", "Full file content", SchemaBuilder.string)])
    }
    public func call(arguments: GeneratedContent) async throws -> String {
        let path = try arguments.value(String.self, forProperty: "path")
        let content = try arguments.value(String.self, forProperty: "content")
        ctx.report(.toolCall(name: name, arguments: "\(path) (\(content.count) chars)"))
        let url = URL(fileURLWithPath: ctx.cwd).appendingPathComponent(path)
        if let refusal = await ctx.gate(.init(id: UUID().uuidString, tool: name, summary: "write \(path)", command: nil, paths: [url.path])) {
            ctx.report(.toolResult(name: name, output: refusal)); return refusal
        }
        let result: String
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            await ctx.policy?.recordCreated(url.path)
            result = "wrote \(content.count) chars to \(path)"
        } catch { result = "error: \(error.localizedDescription)" }
        ctx.report(.toolResult(name: name, output: result))
        return result
    }
}

public struct EditFileTool: Tool {
    public let name = "edit_file"
    public let description = "Replace an exact substring in a text file with new text. The old text must occur exactly once."
    let ctx: ToolContext
    public init(_ ctx: ToolContext) { self.ctx = ctx }
    public var parameters: GenerationSchema {
        try! SchemaBuilder.object("EditArgs", [
            ("path", "Relative file path", SchemaBuilder.string),
            ("old", "Exact text to replace", SchemaBuilder.string),
            ("new", "Replacement text", SchemaBuilder.string)])
    }
    public func call(arguments: GeneratedContent) async throws -> String {
        let path = try arguments.value(String.self, forProperty: "path")
        let old = try arguments.value(String.self, forProperty: "old")
        let new = try arguments.value(String.self, forProperty: "new")
        ctx.report(.toolCall(name: name, arguments: "\(path): \(old.prefix(40))… -> \(new.prefix(40))…"))
        let url = URL(fileURLWithPath: ctx.cwd).appendingPathComponent(path)
        if let refusal = await ctx.gate(.init(id: UUID().uuidString, tool: name, summary: "edit \(path)", command: nil, paths: [url.path])) {
            ctx.report(.toolResult(name: name, output: refusal)); return refusal
        }
        let result: String
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let n = text.components(separatedBy: old).count - 1
            if n != 1 { result = "error: old text occurs \(n) times, expected exactly 1" }
            else {
                try text.replacingOccurrences(of: old, with: new).write(to: url, atomically: true, encoding: .utf8)
                await ctx.policy?.recordCreated(url.path)
                result = "edited \(path)"
            }
        } catch { result = "error: \(error.localizedDescription)" }
        ctx.report(.toolResult(name: name, output: result))
        return result
    }
}
