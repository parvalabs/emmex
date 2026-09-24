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
    private var counters: CounterBox?
    final class CounterBox: @unchecked Sendable {
        var toolCalls = 0, errors = 0
        let lock = NSLock()
        func note(_ ev: AgentEvent) {
            lock.lock(); defer { lock.unlock() }
            switch ev {
            case .toolCall: toolCalls += 1
            case .toolResult(_, let out): if (out.hasPrefix("exit=") && !out.hasPrefix("exit=0")) || out.hasPrefix("error") || out.hasPrefix("denied") { errors += 1 }
            default: break
            }
        }
        func reset() { lock.lock(); toolCalls = 0; errors = 0; lock.unlock() }
        var snapshot: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (toolCalls, errors) }
    }
    /// Permission engine for this session (nil in chat mode, which has no tools).
    public private(set) var policy: PolicyEngine?
    private var approver: Approver?
    public var mode: SessionMode { record.mode }

    public static let chatInstructions = """
    You are mlex, a helpful assistant for a software developer. You have no tools in this mode: \
    answer from knowledge, the conversation, and your memory. Be concise and concrete.
    """

    public static let defaultInstructions = """
    You are mlex, a coding agent working in the user's project directory. Tools let you inspect \
    and change files and run commands. Use a tool only when the request needs information from \
    the project or asks for a change or a command; for conversation, questions you can answer \
    directly, or instructions like "say X", reply in text without tools. When asked about the \
    project or its code, look before answering: list the directory and read the relevant files. \
    Reading is free of side effects, so never ask permission to explore; just do it and report \
    what you found. Run one command per tool call and read its output before deciding the next \
    step. Never use interactive commands. Be terse and concrete.
    """

    /// Start a new session in `workspace` (tools run in `cwd`, which defaults to the workspace).
    public convenience init(spec: ModelSpec, workspace: URL, cwd: URL? = nil, worktree: String? = nil,
                            mode: SessionMode = .code, permission: PermissionLevel? = nil,
                            instructions: String? = nil, mcp: MCPHost? = nil, approver: Approver? = nil, sink: @escaping EventSink) async throws {
        let level = permission ?? PermissionLevel(rawValue: Settings.load().permission) ?? .smart
        let record = SessionRecord(workspace: workspace, cwd: cwd ?? workspace, worktree: worktree, model: spec, mode: mode, permission: level)
        try await self.init(record: record, spec: spec, instructions: instructions, mcp: mcp, approver: approver, sink: sink)
    }

    /// Names of every tool available to this session, built-in and MCP.
    public private(set) var toolNames: [String] = []

    /// Resume a saved session, optionally on a different model (the transcript carries over).
    /// `mcp` adds the tools of every connected MCP server.
    public init(record: SessionRecord, spec: ModelSpec? = nil, instructions: String? = nil,
                mcp: MCPHost? = nil, approver: Approver? = nil, sink: @escaping EventSink) async throws {
        var record = record
        let spec = spec ?? record.spec
        record.model = spec.description
        self.spec = spec; self.cwd = record.cwd; self.record = record
        self.mcpHost = mcp
        self.approver = approver
        // Count tool calls and errors per turn for the routing log before forwarding events.
        let box = CounterBox()
        self.counters = box
        self.sink = { ev in box.note(ev); sink(ev) }
        self.activeSpec = spec == .auto ? await TierResolver.current().spec(for: .local) : spec
        let policy = record.mode == .code ? PolicyEngine(workspace: record.workspaceURL, cwd: record.cwdURL, level: record.permission) : nil
        self.policy = policy
        let ctx = ToolContext(cwd: record.cwd, report: sink, policy: policy, approver: approver, sessionID: record.id)
        var tools: [any Tool] = record.mode == .chat ? [] : Tools.standard(ctx)
        if let mcp, record.mode == .code { tools += await mcp.tools(ctx: ctx) }
        self.toolNames = tools.map(\.name)
        let base = instructions ?? (record.mode == .chat ? Self.chatInstructions : Self.defaultInstructions)
        self.baseInstructions = base
        let composed = await Self.compose(base, workspace: record.workspaceURL, cwd: record.cwdURL, spec: spec)
        var transcript: Transcript? = nil
        if !record.transcript.isEmpty {
            // A saved transcript carries the instructions it was created with; refresh them so
            // memory, skills, and context files reflect what exists now.
            transcript = Self.refreshInstructions(Compactor.sanitized(record.transcript), with: composed)
        }
        self.session = try await Backends.makeSession(
            spec, tools: tools, instructions: composed, transcript: transcript,
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

    public func setPermission(_ level: PermissionLevel) async {
        record.permission = level
        await policy?.setLevel(level)
        if autosave { try? save() }
    }

    public func rename(_ title: String) {
        record.title = title
        if autosave { try? save() }
    }

    /// Automatic compaction when the transcript nears the context window.
    public var autoCompact = true
    /// Input tokens reported by the last response, the best context estimate for cloud/MLX models.
    public private(set) var lastInputTokens: Int?
    private var lastTurnUsage: LanguageModelSession.Usage?
    /// For `auto` sessions: the concrete model currently running and the last routing decision.
    public private(set) var activeSpec: ModelSpec
    public private(set) var lastRoute: RouteDecision?
    private lazy var router: any Router = TierResolver.makeRouter()

    /// The model actually answering: the routed spec for auto sessions, else the session's spec.
    public var effectiveSpec: ModelSpec { spec == .auto ? activeSpec : spec }

    /// Route the prompt and switch the live session to the chosen tier if needed.
    func routeIfAuto(_ prompt: String) async {
        guard spec == .auto else { return }
        let recent = session.transcript.suffix(4).map(Compactor.render).joined(separator: "\n").suffix(600)
        do {
            let previous = lastRoute?.tier ?? record.routes.last?.tier.flatMap(Tier.init(rawValue:))
            let decision: RouteDecision
            if let (tier, why) = RoutingFloor.continuation(prompt: prompt, previous: previous) {
                decision = RouteDecision(tier: tier, reason: why, confidence: 0.9, router: "floor")
            } else {
                decision = try await router.route(.init(prompt: prompt, recent: String(recent), tools: toolNames))
            }
            lastRoute = decision
            let resolver = await TierResolver.current()
            let target = resolver.spec(for: decision.tier)
            if target != activeSpec {
                try await rebuild(with: session.transcript, spec: target)
                activeSpec = target
            }
            sink(.info("auto → \(target) (\(decision.tier.rawValue), \(decision.router), \(Int(decision.confidence * 100))%)\(decision.reason.isEmpty ? "" : ": \(decision.reason)")"))
        } catch {
            sink(.warning("router failed (\(error)); staying on \(activeSpec)"))
        }
    }

    /// (tokens used, context window) for the current session.
    public func contextUsage() async -> (used: Int, size: Int) {
        let (_, used, size) = await Compactor.shouldCompact(session: session, spec: effectiveSpec, lastInputTokens: lastInputTokens)
        return (used, size)
    }
    private var mcpHost: MCPHost?
    private var baseInstructions: String

    /// Replace the live session with one built from `transcript` (same tools and instructions),
    /// on `spec` if given, else the current effective model.
    func rebuild(with transcript: Transcript, spec: ModelSpec? = nil) async throws {
        let ctx = ToolContext(cwd: record.cwd, report: sink, policy: policy, approver: approver, sessionID: record.id)
        var tools: [any Tool] = record.mode == .chat ? [] : Tools.standard(ctx)
        if let mcpHost, record.mode == .code { tools += await mcpHost.tools(ctx: ctx) }
        session = try await Backends.makeSession(spec ?? effectiveSpec, tools: tools, instructions: nil, transcript: transcript,
                                                 onWarning: { [sink] in sink(.warning($0)) })
    }

    /// Fold older turns into a summary. Returns the summary, or nil if there was nothing to fold.
    @discardableResult
    public func compact() async throws -> String? {
        let before = await Compactor.tokensUsed(session: session, spec: effectiveSpec, lastInputTokens: lastInputTokens)
        let (t, summary, dropped) = try await Compactor.compact(transcript: session.transcript)
        guard dropped > 0 else { return nil }
        try await rebuild(with: t)
        lastInputTokens = nil
        let after = await Compactor.tokensUsed(session: session, spec: effectiveSpec, lastInputTokens: nil)
        sink(.info("compacted \(dropped) entries: ~\(before) → ~\(after) tokens"))
        if autosave { try? save() }
        return summary
    }

    static let correctionCues = ["no,", "no.", "not that", "that's wrong", "that is wrong", "wrong", "actually", "instead", "undo", "revert", "i meant", "i said", "again", "didn't ask", "did not ask", "try again", "not what"]
    static func looksLikeCorrection(_ prompt: String) -> Bool {
        let l = prompt.lowercased().trimmingCharacters(in: .whitespaces)
        return correctionCues.contains { l.hasPrefix($0) || l.contains(" " + $0) }
    }

    /// Run one user turn, streaming text deltas and tool events to the sink. Returns the final text.
    @discardableResult
    public func run(_ prompt: String, effort: Effort = .default) async throws -> String {
        // Outcome signal for the previous turn: does this prompt read like a correction?
        if let last = record.routes.indices.last, record.routes[last].followedByCorrection == nil {
            record.routes[last].followedByCorrection = Self.looksLikeCorrection(prompt)
        }
        let started = Date()
        counters?.reset()
        if autoCompact {
            let (needed, used, size) = await Compactor.shouldCompact(session: session, spec: effectiveSpec, lastInputTokens: lastInputTokens)
            if needed, try await compact() == nil { sink(.info("context \(used)/\(size) tokens; nothing old enough to compact yet")) }
        }
        await routeIfAuto(prompt)
        let sent = await withMemory(prompt)
        let text: String
        do {
            text = try await runOnce(sent, effort: effort)
        } catch let error as LanguageModelSession.GenerationError {
            guard case .exceededContextWindowSize = error, autoCompact else { throw error }
            sink(.info("context window exceeded, compacting and retrying…"))
            try await compact()
            text = try await runOnce(sent, effort: effort)
        } catch let error as LanguageModelError {
            guard case .contextSizeExceeded = error, autoCompact else { throw error }
            sink(.info("context window exceeded, compacting and retrying…"))
            try await compact()
            text = try await runOnce(sent, effort: effort)
        }
        if record.turns == 1, record.title == "New session" { record.title = Self.title(from: prompt); if autosave { try? save() } }
        var log = RouteLog(turn: record.turns, prompt: String(prompt.prefix(200)), tier: spec == .auto ? lastRoute?.tier.rawValue : nil,
                           model: effectiveSpec.description, router: spec == .auto ? lastRoute?.router : nil,
                           confidence: spec == .auto ? lastRoute?.confidence : nil, reason: spec == .auto ? lastRoute?.reason : nil)
        let (tc, te) = counters?.snapshot ?? (0, 0)
        log.toolCalls = tc; log.errors = te
        log.tokensIn = lastTurnUsage?.input.totalTokenCount ?? 0; log.tokensOut = lastTurnUsage?.output.totalTokenCount ?? 0
        log.durationMs = Int(Date().timeIntervalSince(started) * 1000)
        record.routes.append(log)
        if autosave { try? save() }
        await remember(prompt: prompt, response: text)
        return text
    }

    /// Prepend facts relevant to this prompt (beyond the ones already in the instructions).
    private func withMemory(_ prompt: String) async -> String {
        guard Settings.load().memory else { return prompt }
        let lower = prompt.lowercased()
        let asksAboutMemory = ["remember", "memory", "memories", "recall", "previous session", "earlier session", "last time"].contains { lower.contains($0) }
        let facts = asksAboutMemory
            ? Array(await MemoryStore.shared.facts(workspace: record.workspaceURL).sorted { $0.createdAt > $1.createdAt }.prefix(12))
            : await MemoryStore.shared.relevant(to: prompt, workspace: record.workspaceURL, limit: 5)
        guard !facts.isEmpty else { return prompt }
        await MemoryStore.shared.markUsed(facts.map(\.id), workspace: record.workspaceURL)
        return "Relevant memory:\n" + facts.map { "- \($0.text)" }.joined(separator: "\n") + "\n\n" + prompt
    }

    /// Extract durable facts from the turn with the on-device model and store them.
    private func remember(prompt: String, response: String) async {
        guard Settings.load().memory, prompt.count + response.count > 40, !prompt.hasPrefix("Summary of the conversation") else { return }
        let tools = session.transcript.suffix(8).compactMap { e -> String? in
            if case .toolCalls(let c) = e { return c.map(\.toolName).joined(separator: ",") } else { return nil }
        }.joined(separator: " ")
        do {
            let facts = try await MemoryExtractor.extract(prompt: prompt, response: response, toolSummary: tools)
            if ProcessInfo.processInfo.environment["MLEX_DEBUG"] != nil { FileHandle.standardError.write(Data("[mlex] extracted: \(facts)\n".utf8)) }
            let added = try await MemoryStore.shared.add(facts, workspace: record.workspaceURL, source: record.id)
            if !added.isEmpty { sink(.info("remembered: " + added.map { ($0.scope == "user" ? "[you] " : "") + $0.text }.joined(separator: " · "))) }
            if await MemoryStore.shared.shouldAutoConsolidate(workspace: record.workspaceURL) {
                let merges = try await MemoryStore.shared.consolidate(workspace: record.workspaceURL)
                if !merges.isEmpty { sink(.info("memory: merged \(merges.reduce(0) { $0 + $1.from.count }) facts into \(merges.count)")) }
            }
        } catch {
            // Memory is best effort; never fail the turn over it.
        }
    }

    private func runOnce(_ prompt: String, effort: Effort) async throws -> String {
        var last = ""
        let stream = session.streamResponse(to: prompt, contextOptions: effort.contextOptions(for: effectiveSpec))
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
        if let u = usage, u.input.totalTokenCount > 0 { lastInputTokens = u.input.totalTokenCount + u.output.totalTokenCount }
        lastTurnUsage = usage
        sink(.finished(usage: usage, text: last))
        record.turns += 1
        record.effort = effort
        if autosave { try? save() }
        return last
    }

    static func refreshInstructions(_ t: Transcript, with text: String) -> Transcript {
        var entries = Array(t)
        if let i = entries.firstIndex(where: { if case .instructions = $0 { true } else { false } }), case .instructions(let old) = entries[i] {
            entries[i] = .instructions(.init(id: old.id, segments: [.text(.init(content: text))], toolDefinitions: old.toolDefinitions))
        }
        return Transcript(entries: entries)
    }

    /// Base instructions plus skills listing, project context files, and remembered facts.
    /// Apple's on-device model has a small window, so those extras are trimmed harder for it.
    static func compose(_ base: String, workspace: URL, cwd: URL, spec: ModelSpec) async -> String {
        let small = spec == .system || spec == .auto
        var parts = [base, "Working directory: \(cwd.path)"]
        if let skills = Skills.promptSection(Skills.discover(workspace: workspace), limit: small ? 8 : 30) { parts.append(skills) }
        if let ctx = ContextFiles.load(workspace: workspace, cwd: cwd) {
            parts.append(small ? String(ctx.prefix(1500)) : ctx)
        }
        if Settings.load().memory {
            let facts = await MemoryStore.shared.facts(workspace: workspace)
            let prefs = facts.filter { $0.kind == "preference" }.sorted { $0.score() > $1.score() }
            let others = facts.filter { $0.kind != "preference" }.sorted { $0.score() > $1.score() }
            let picked = Array((prefs + others).prefix(small ? 6 : 15))
            if let mem = MemoryStore.promptSection(picked) { parts.append(mem); await MemoryStore.shared.markUsed(picked.map(\.id), workspace: workspace) }
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
