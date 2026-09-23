import Foundation
import FoundationModels

/// One agent conversation on one model, with tools, streaming events, and a persisted record.
public final class AgentSession: @unchecked Sendable {
    public let spec: ModelSpec
    public let cwd: String
    public private(set) var session: LanguageModelSession
    public private(set) var record: SessionRecord
    /// Whether turns are saved to the session store after each response.
    public var autosave = true
    private let sink: EventSink

    public static let defaultInstructions = """
    You are mlex, a coding agent working in the user's project directory. Tools let you inspect \
    and change files and run commands. Use a tool only when the request needs information from \
    the project or asks for a change or a command; for conversation, questions you can answer \
    directly, or instructions like "say X", reply in text without tools. Run one command per tool \
    call and read its output before deciding the next step. Never use interactive commands. Be \
    terse and concrete.
    """

    /// Start a new session in `workspace` (tools run in `cwd`, which defaults to the workspace).
    public convenience init(spec: ModelSpec, workspace: URL, cwd: URL? = nil, worktree: String? = nil,
                            instructions: String? = nil, mcp: MCPHost? = nil, sink: @escaping EventSink) async throws {
        let record = SessionRecord(workspace: workspace, cwd: cwd ?? workspace, worktree: worktree, model: spec)
        try await self.init(record: record, spec: spec, instructions: instructions, mcp: mcp, sink: sink)
    }

    /// Names of every tool available to this session, built-in and MCP.
    public private(set) var toolNames: [String] = []

    /// Resume a saved session, optionally on a different model (the transcript carries over).
    /// `mcp` adds the tools of every connected MCP server.
    public init(record: SessionRecord, spec: ModelSpec? = nil, instructions: String? = nil,
                mcp: MCPHost? = nil, sink: @escaping EventSink) async throws {
        var record = record
        let spec = spec ?? record.spec
        record.model = spec.description
        self.spec = spec; self.cwd = record.cwd; self.sink = sink; self.record = record
        let ctx = ToolContext(cwd: record.cwd, report: sink)
        var tools = Tools.standard(ctx)
        if let mcp { tools += await mcp.tools(ctx: ctx) }
        self.toolNames = tools.map(\.name)
        let base = instructions ?? Self.defaultInstructions
        self.session = try await Backends.makeSession(
            spec, tools: tools,
            instructions: Self.compose(base, workspace: record.workspaceURL, cwd: record.cwdURL, spec: spec),
            transcript: record.transcript.isEmpty ? nil : record.transcript,
            onWarning: { sink(.warning($0)) })
    }

    /// Legacy initializer used by the spikes: a throwaway session that is not saved.
    public convenience init(spec: ModelSpec, cwd: String, instructions: String? = nil,
                            transcript: Transcript? = nil, sink: @escaping EventSink) async throws {
        var record = SessionRecord(workspace: URL(fileURLWithPath: cwd), cwd: URL(fileURLWithPath: cwd), model: spec)
        if let t = transcript { record.transcript = t }
        try await self.init(record: record, spec: spec, instructions: instructions, sink: sink)
        autosave = false
    }

    public var transcript: Transcript { session.transcript }

    /// Persist the current transcript and metadata.
    public func save() throws {
        record.transcript = session.transcript
        record.updatedAt = Date()
        try SessionStore.save(record)
    }

    public func rename(_ title: String) {
        record.title = title
        if autosave { try? save() }
    }

    /// Run one user turn, streaming text deltas and tool events to the sink. Returns the final text.
    @discardableResult
    public func run(_ prompt: String, effort: Effort = .default) async throws -> String {
        var last = ""
        let stream = session.streamResponse(to: prompt, contextOptions: effort.contextOptions(for: spec))
        var usage: LanguageModelSession.Usage? = nil
        for try await snapshot in stream {
            let full = snapshot.content
            if full.count > last.count, full.hasPrefix(last) {
                sink(.textDelta(String(full.dropFirst(last.count))))
            } else if full != last {
                sink(.textDelta(full))
            }
            last = full
            usage = snapshot.usage
        }
        sink(.finished(usage: usage, text: last))
        record.turns += 1
        if record.turns == 1, record.title == "New session" {
            record.title = Self.title(from: prompt)
        }
        record.effort = effort
        if autosave { try? save() }
        return last
    }

    /// Base instructions plus skills listing and project context files. Apple's on-device
    /// model has a small window, so those extras are trimmed harder for it.
    static func compose(_ base: String, workspace: URL, cwd: URL, spec: ModelSpec) -> String {
        let small = spec == .system
        var parts = [base, "Working directory: \(cwd.path)"]
        if let skills = Skills.promptSection(Skills.discover(workspace: workspace), limit: small ? 8 : 30) { parts.append(skills) }
        if let ctx = ContextFiles.load(workspace: workspace, cwd: cwd) {
            parts.append(small ? String(ctx.prefix(1500)) : ctx)
        }
        return parts.joined(separator: "\n\n")
    }

    static func title(from prompt: String) -> String {
        let one = prompt.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return one.count > 60 ? String(one.prefix(57)) + "…" : one
    }

    // MARK: file export (transcript only)

    public func save(to url: URL) throws {
        let data = try JSONEncoder().encode(session.transcript)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public static func loadTranscript(from url: URL) throws -> Transcript {
        try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: url))
    }
}
