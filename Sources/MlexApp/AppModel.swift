import Foundation
import AppKit
import Observation
import FoundationModels
import MlexCore

struct TimelineItem: Identifiable {
    enum Kind { case user, assistant, toolCall, toolResult, info, warning, error }
    let id = UUID()
    var kind: Kind
    var title: String = ""
    var text: String
    var userTurn: Int? = nil     // 1-based prompt index, for "fork from here"
}

@MainActor @Observable
final class AppModel {
    // Workspace + sessions
    var workspace: URL?
    var recents: [WorkspaceStore.Entry] = []
    var sessions: [SessionSummary] = []
    var current: AgentSession?
    var renaming: SessionSummary?

    // Conversation
    var timeline: [TimelineItem] = []
    var input: String = ""
    var busy = false
    /// A prompt sent before the session finished loading; delivered once it is ready.
    private var pending: String?
    /// Follow-ups typed while a turn is running, sent in order when it finishes.
    var queue: [String] = []
    private var runTask: Task<Void, Never>?
    var lastUsage: LanguageModelSession.Usage?
    var contextUsed = 0
    var contextSize = 0

    // Model + effort
    var selected: ModelSpec = .system
    var effort: Effort = .default
    var backends: [Backends.Status] = []

    // Models management
    var installed: [ModelStore.Installed] = []
    var pullID: String = "mlx-community/Qwen3-4B-4bit"
    var pulls: [String: Double] = [:]
    var pullErrors: [String: String] = [:]
    private var pullTasks: [String: Task<Void, Never>] = [:]
    var residentID: String?
    var loadingID: String?
    var footprint: Int64 = 0

    // Workspace capabilities
    var mcp = MCPHost()
    var mcpSummary: [(server: String, info: String, tools: [String])] = []
    var mcpFailures: [String: String] = [:]
    var commands = Commands(workspace: nil)

    // Sheets
    var showModels = false
    var showWorkspaceInfo = false

    /// Incremented on every workspace open or session switch; stale async loads check it and bail.
    private var generation = 0

    func debug(_ msg: @autoclosure () -> String) {
        if ProcessInfo.processInfo.environment["MLEX_DEBUG"] != nil { FileHandle.standardError.write(Data("[mlex] \(msg())\n".utf8)) }
    }

    var specs: [ModelSpec] { backends.filter(\.available).compactMap { try? ModelSpec(parsing: $0.spec) } }

    // MARK: lifecycle

    func start(autoOpen: Bool = true) async {
        recents = WorkspaceStore.recents()
        await refreshModels()
        if autoOpen, let first = recents.first { openWorkspace(first.url) }
    }

    func refreshModels() async {
        backends = await Backends.status()
        installed = await ModelStore.shared.installed()
        residentID = await ModelStore.shared.residentID
        footprint = SystemMemory.footprint()
    }

    // MARK: workspace

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = workspace
        if panel.runModal() == .OK, let url = panel.url { openWorkspace(url) }
    }

    func openWorkspace(_ url: URL) {
        generation += 1
        let gen = generation
        debug("openWorkspace \(url.lastPathComponent) gen=\(gen)")
        workspace = url
        recents = WorkspaceStore.touch(url)
        sessions = SessionStore.list(workspace: url)
        commands = Commands(workspace: url)
        current = nil; timeline = []; lastUsage = nil; contextUsed = 0; busy = false
        Task {
            await mcp.disconnectAll()
            guard gen == generation else { return }
            mcp = MCPHost()
            await mcp.connect(workspace: url) { [weak self] line in Task { @MainActor in self?.timeline.append(.init(kind: .info, text: line)) } }
            guard gen == generation else { return }
            mcpSummary = await mcp.summary()
            mcpFailures = await mcp.failures
            if let first = sessions.first { resume(first.id) } else { newSession() }
        }
    }

    // MARK: sessions

    func newSession(worktree: String? = nil) {
        guard let ws = workspace else { return }
        timeline = []; lastUsage = nil; current = nil
        Task {
            var cwd = ws
            if let worktree {
                do {
                    let w = try Worktrees.add(repo: ws, branch: worktree)
                    cwd = URL(fileURLWithPath: w.path)
                    timeline.append(.init(kind: .info, text: "worktree \(worktree) at \(w.path)"))
                } catch { timeline.append(.init(kind: .error, text: "\(error)")); return }
            }
            await load { try await AgentSession(spec: self.selected, workspace: ws, cwd: cwd, worktree: worktree, mcp: self.mcp, sink: self.sink) }
        }
    }

    func resume(_ id: String) {
        guard let ws = workspace, current?.record.id != id else { return }
        guard let record = try? SessionStore.load(id, workspace: ws) else { return }
        timeline = []; lastUsage = nil; current = nil
        selected = record.spec; effort = record.effort
        replay(record.transcript)
        Task { await load { try await AgentSession(record: record, spec: nil, mcp: self.mcp, sink: self.sink) } }
    }

    /// Change model or effort for the current session; the transcript carries over.
    func select(_ spec: ModelSpec) {
        guard spec != selected else { return }
        selected = spec
        guard let cur = current else { return }
        try? cur.save()
        current = nil
        Task { await load { try await AgentSession(record: cur.record, spec: spec, mcp: self.mcp, sink: self.sink) } }
    }

    func rename(_ id: String, to title: String) {
        if current?.record.id == id { current?.rename(title) }
        else if let ws = workspace, var r = try? SessionStore.load(id, workspace: ws) { r.title = title; try? SessionStore.save(r) }
        sessions = SessionStore.list(workspace: workspace!)
    }

    func deleteSession(_ id: String) {
        guard let ws = workspace else { return }
        try? SessionStore.delete(id, workspace: ws)
        if current?.record.id == id { current = nil; timeline = [] }
        sessions = SessionStore.list(workspace: ws)
    }

    func fork(_ id: String, beforeUserTurn turn: Int? = nil) {
        guard let ws = workspace else { return }
        if current?.record.id == id { try? current?.save() }
        guard let r = try? SessionStore.load(id, workspace: ws) else { return }
        let f = r.forked(beforeUserTurn: turn)
        try? SessionStore.save(f)
        sessions = SessionStore.list(workspace: ws)
        resume(f.id)
    }

    func exportSession() {
        guard let cur = current else { return }
        try? cur.save()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = cur.record.title.prefix(40).replacingOccurrences(of: "/", with: "-") + ".html"
        panel.allowedContentTypes = [.html, .json]
        if panel.runModal() == .OK, let url = panel.url {
            do { try SessionExport.write(cur.record, to: url) } catch { timeline.append(.init(kind: .error, text: "\(error)")) }
        }
    }

    func stop() {
        runTask?.cancel()
        queue.removeAll()
    }

    func revealWorktree(_ id: String) {
        guard let ws = workspace, let r = try? SessionStore.load(id, workspace: ws) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([r.cwdURL])
    }

    func compact() {
        guard let cur = current, !busy else { return }
        busy = true
        Task { do { _ = try await cur.compact() } catch { timeline.append(.init(kind: .error, text: "\(error)")) }; await updateContext(); busy = false }
    }

    private func load(_ make: @escaping () async throws -> AgentSession) async {
        generation += 1
        let gen = generation
        if case .mlx(let id) = selected { loadingID = id }
        do {
            let agent = try await make()
            guard gen == generation else { debug("stale load gen=\(gen) discarded"); return }
            current = agent
            debug("session ready \(agent.record.id.prefix(8)) on \(agent.spec)")
            await updateContext()
        } catch { timeline.append(.init(kind: .error, text: "\(error)")) }
        loadingID = nil
        await refreshModels()
        if let ws = workspace { sessions = SessionStore.list(workspace: ws) }
        if let p = pending, current != nil { pending = nil; busy = false; input = p; debug("delivering queued prompt"); send() } else { busy = false }
    }

    private func updateContext() async {
        guard let cur = current else { return }
        let (used, size) = await cur.contextUsage()
        contextUsed = used; contextSize = size
    }

    /// Rebuild the timeline from a saved transcript.
    private func replay(_ t: Transcript) {
        func text(_ segs: [Transcript.Segment]) -> String { segs.compactMap { if case .text(let s) = $0 { s.content } else { nil } }.joined() }
        var turn = 0
        for e in t {
            switch e {
            case .prompt(let p): turn += 1; timeline.append(.init(kind: .user, text: text(p.segments), userTurn: turn))
            case .response(let r): timeline.append(.init(kind: .assistant, text: text(r.segments)))
            case .toolCalls(let c): for call in c { timeline.append(.init(kind: .toolCall, title: call.toolName, text: call.arguments.jsonString)) }
            case .toolOutput(let o): timeline.append(.init(kind: .toolResult, title: o.toolName, text: text(o.segments)))
            default: break
            }
        }
    }

    // MARK: sending

    var slashSuggestions: [(command: String, hint: String)] {
        guard input.hasPrefix("/"), !input.contains(" ") else { return [] }
        let q = input.dropFirst().lowercased()
        var all: [(String, String)] = commands.skills.map { ("/skill:\($0.name)", $0.description) }
        all += commands.templates.map { ("/\($0.name)", $0.argumentHint.map { "\($0) · " } ?? "" + $0.description) }
        all += [("/compact", "Fold older turns into a summary"), ("/new", "New session")]
        return all.filter { q.isEmpty || $0.0.lowercased().contains(q) }.prefix(8).map { (command: $0.0, hint: $0.1) }
    }

    func send() {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if busy, current != nil { queue.append(raw); input = ""; return }
        guard let cur = current else {
            // Session still loading (or no workspace yet): keep the prompt and deliver it on load.
            if workspace != nil { pending = raw; input = ""; busy = true; debug("queued prompt until session ready") }
            return
        }
        input = ""
        if raw == "/compact" { compact(); return }
        if raw == "/new" { newSession(); return }
        let prompt = commands.expand(raw) ?? raw
        let turn = (timeline.compactMap(\.userTurn).max() ?? 0) + 1
        timeline.append(.init(kind: .user, text: raw, userTurn: turn))
        busy = true
        debug("run start: \(prompt.prefix(60))")
        runTask = Task {
            do { try await cur.run(prompt, effort: effort); debug("run done") }
            catch is CancellationError { timeline.append(.init(kind: .info, text: "stopped")) }
            catch { debug("run error: \(error)"); timeline.append(.init(kind: .error, text: "\(error)")) }
            await updateContext()
            busy = false
            runTask = nil
            if let ws = workspace { sessions = SessionStore.list(workspace: ws) }
            if !queue.isEmpty { input = queue.removeFirst(); send() }
        }
    }

    private var sink: EventSink {
        { [weak self] ev in Task { @MainActor in self?.handle(ev) } }
    }

    private func handle(_ ev: AgentEvent) {
        if ProcessInfo.processInfo.environment["MLEX_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[mlex] \(ev)\n".utf8))
        }
        switch ev {
        case .textDelta(let t):
            if let last = timeline.indices.last, timeline[last].kind == .assistant { timeline[last].text += t }
            else { timeline.append(.init(kind: .assistant, text: t)) }
        case .toolCall(let name, let args): timeline.append(.init(kind: .toolCall, title: name, text: args))
        case .toolResult(let name, let output): timeline.append(.init(kind: .toolResult, title: name, text: output))
        case .finished(let usage, _): lastUsage = usage; footprint = SystemMemory.footprint()
        case .warning(let w): timeline.append(.init(kind: .warning, text: w))
        case .info(let i): timeline.append(.init(kind: .info, text: i))
        }
    }

    // MARK: models

    func pull() {
        let id = pullID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, pulls[id] == nil else { return }
        pulls[id] = 0; pullErrors[id] = nil
        pullTasks[id] = Task {
            do {
                _ = try await ModelStore.shared.pull(id) { fraction, _ in Task { @MainActor in self.pulls[id] = fraction } }
                await refreshModels()
            } catch is CancellationError {
            } catch { pullErrors[id] = "\(error)" }
            pulls[id] = nil; pullTasks[id] = nil
        }
    }
    func cancelPull(_ id: String) { pullTasks[id]?.cancel() }
    func remove(_ id: String) { Task { try? await ModelStore.shared.remove(id); await refreshModels() } }
    func unloadResident() { Task { await ModelStore.shared.unloadResident(); await refreshModels() } }
}
