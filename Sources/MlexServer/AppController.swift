import Foundation
import AppKit
import FoundationModels
import MlexCore

/// All UI state and actions, independent of any view technology. Emits JSON snapshots and
/// streaming events that the web front-end renders.
@MainActor
public final class AppController {
    public struct Item: Sendable { var id: String; var kind: String; var title: String; var text: String; var userTurn: Int?
        var json: [String: Any] { var d: [String: Any] = ["id": id, "kind": kind, "title": title, "text": text]; if let userTurn { d["userTurn"] = userTurn }; return d } }

    public var emit: @MainActor (String, Any) -> Void = { _, _ in }
    public var canUseNativePanels = false

    // Workspace + sessions
    var workspace: URL?
    var recents: [WorkspaceStore.Entry] = []
    var sessions: [SessionSummary] = []
    var current: AgentSession?

    // Conversation
    var timeline: [Item] = []
    var busy = false
    var pending: String?
    var queue: [String] = []
    var runTask: Task<Void, Never>?
    var contextUsed = 0, contextSize = 0
    var lastUsage: LanguageModelSession.Usage?

    // Model + effort
    var selected: ModelSpec = .system
    var pendingSpec: ModelSpec?  // spec to apply after current load completes
    var effort: Effort = .default
    var backends: [Backends.Status] = []
    var loadingID: String?, residentID: String?
    var footprint: Int64 = 0

    // Models
    var pulls: [String: Double] = [:]
    var pullErrors: [String: String] = [:]
    var pullTasks: [String: Task<Void, Never>] = [:]

    // Workspace capabilities
    // Approvals: pending requests and the continuations that resume the waiting tool.
    var pendingApprovals: [ToolRequest] = []
    var waiters: [String: CheckedContinuation<(Bool, String?), Never>] = [:]
    var audit: [(id: String, allowed: Bool, layer: String)] = []
    var mode: SessionMode = .code
    var permission: PermissionLevel = PermissionLevel(rawValue: Settings.load().permission) ?? .smart
    var mcp = MCPHost()
    var mcpSummary: [(server: String, info: String, tools: [String])] = []
    var mcpFailures: [String: String] = [:]
    var commands = Commands(workspace: nil)
    var memory: [MemoryFact] = []
    var generation = 0

    public init() {}

    // MARK: snapshot

    public func snapshot() -> [String: Any] {
        func ms(_ d: Date) -> Double { d.timeIntervalSince1970 * 1000 }
        var d: [String: Any] = [
            "workspace": workspace.map { ["path": $0.path, "name": $0.lastPathComponent] } as Any,
            "recents": recents.map { ["path": $0.path, "name": $0.name] },
            "sessions": sessions.map { ["id": $0.id, "title": $0.title, "model": $0.model, "worktree": $0.worktree as Any, "updatedAt": ms($0.updatedAt), "turns": $0.turns] },
            "timeline": timeline.map(\.json),
            "busy": busy, "queue": queue,
            "selected": selected.description, "effort": effort.rawValue,
            "backends": backends.map { ["spec": $0.spec, "available": $0.available, "detail": $0.detail] },
            "loading": loadingID as Any, "resident": residentID as Any,
            "footprint": SystemMemory.format(footprint), "free": SystemMemory.format(SystemMemory.available()),
            "pulls": pulls, "pullErrors": pullErrors,
            "mcp": mcpSummary.map { ["server": $0.server, "info": $0.info, "tools": $0.tools] },
            "mcpFailures": mcpFailures,
            "skills": commands.skills.map { ["name": $0.name, "description": $0.description] },
            "templates": commands.templates.map { ["name": $0.name, "hint": $0.argumentHint as Any, "description": $0.description] },
            "memory": memory.filter { !$0.archived }.sorted { $0.score() > $1.score() }.map { ["id": $0.id, "kind": $0.kind, "scope": $0.scope, "text": $0.text, "uses": $0.uses, "score": $0.score()] },
            "archived": memory.filter(\.archived).sorted { $0.lastUsed > $1.lastUsed }.map { ["id": $0.id, "kind": $0.kind, "scope": $0.scope, "text": $0.text, "superseded": $0.supersededBy != nil] },
            "tools": current?.toolNames ?? [],
            "nativePanels": canUseNativePanels,
            "pending": pendingApprovals.map { ["id": $0.id, "tool": $0.tool, "summary": $0.summary, "reason": $0.reason, "command": $0.command as Any] },
            "mode": mode.rawValue, "permission": permission.rawValue,
            "trusted": workspace.map { WorkspaceTrust.isTrusted($0) } ?? false,
        ]
        if let cur = current {
            d["current"] = ["id": cur.record.id, "title": cur.record.title, "worktree": cur.record.worktree as Any, "model": cur.spec.description,
                            "effectiveModel": cur.effectiveSpec.description, "contextUsed": contextUsed, "contextSize": contextSize, "cwd": cur.cwd]
            d["routes"] = cur.record.routes.map { ["turn": $0.turn, "tier": $0.tier as Any, "model": $0.model, "confidence": $0.confidence as Any, "reason": $0.reason as Any,
                                                   "toolCalls": $0.toolCalls, "errors": $0.errors, "tokensOut": $0.tokensOut, "durationMs": $0.durationMs, "review": $0.review as Any] }
        } else { d["current"] = NSNull() }
        if let u = lastUsage { d["usage"] = ["input": u.input.totalTokenCount, "cached": u.input.cachedTokenCount, "output": u.output.totalTokenCount] }
        return d
    }

    func push() { emit("state", snapshot()) }

    /// Sendable forms for the HTTP layer.
    public func snapshotData() -> Data { (try? JSONSerialization.data(withJSONObject: snapshot())) ?? Data("{}".utf8) }
    public func handleData(_ a: [String: Any]) async -> Data { (try? JSONSerialization.data(withJSONObject: await handle(a))) ?? Data("{}".utf8) }

    // MARK: lifecycle

    public func start(autoOpen: Bool = true) async {
        recents = WorkspaceStore.recents()
        await refreshModels()
        if autoOpen, let first = recents.first { openWorkspace(first.url) } else { push() }
    }

    func refreshModels() async {
        backends = await Backends.status()
        residentID = await ModelStore.shared.residentID
        footprint = SystemMemory.footprint()
    }

    // MARK: actions

    public func handle(_ a: [String: Any]) async -> [String: Any] {
        let type = a["type"] as? String ?? ""
        func str(_ k: String) -> String? { a[k] as? String }
        switch type {
        case "refresh": await refreshModels(); await refreshMemory(); push()
        case "open_workspace": if let p = str("path") { openWorkspace(URL(fileURLWithPath: p)) }
        case "choose_workspace": chooseWorkspace()
        case "new_session": newSession(worktree: str("worktree"))
        case "resume": if let id = str("id") { resume(id) }
        case "rename": if let id = str("id"), let t = str("title") { rename(id, to: t) }
        case "delete_session": if let id = str("id") { deleteSession(id) }
        case "fork": if let id = str("id") { fork(id, beforeUserTurn: a["before"] as? Int) }
        case "reveal": if let id = str("id") { revealWorktree(id) }
        case "send": if let t = str("text") { send(t) }
        case "stop": stop()
        case "clear_queue": queue.removeAll(); push()
        case "select_model": if let s = str("spec"), let spec = try? ModelSpec(parsing: s) { select(spec) }
        case "set_effort": if let e = str("effort"), let ef = Effort(rawValue: e) { effort = ef; push() }
        case "compact": compact()
        case "pull": if let id = str("id") { pull(id) }
        case "cancel_pull": if let id = str("id") { pullTasks[id]?.cancel() }
        case "remove_model": if let id = str("id") { Task { try? await ModelStore.shared.remove(id); await refreshModels(); push() } }
        case "unload": Task { await ModelStore.shared.unloadResident(); await refreshModels(); push() }
        case "forget": if let id = str("id"), let ws = workspace { Task { try? await MemoryStore.shared.remove(id, workspace: ws); await refreshMemory(); push() } }
        case "clear_memory": if let ws = workspace { Task { try? await MemoryStore.shared.clear(workspace: ws); await refreshMemory(); push() } }
        case "restore_fact": if let id = str("id"), let ws = workspace { Task { try? await MemoryStore.shared.restore(id, workspace: ws); await refreshMemory(); push() } }
        case "consolidate_memory":
            guard let ws = workspace else { return ["error": "no workspace"] }
            let merges = (try? await MemoryStore.shared.consolidate(workspace: ws)) ?? []
            await refreshMemory(); push()
            if merges.isEmpty { info("memory: nothing to merge") } else { for m in merges { info("memory: merged \(m.from.count) facts → \(m.merged)") } }
        case "approve":
            guard let id = str("id"), let w = waiters.removeValue(forKey: id) else { return ["error": "no such request"] }
            pendingApprovals.removeAll { $0.id == id }
            let allow = (a["allow"] as? Bool) ?? false
            var always: String? = nil
            if allow, (a["always"] as? Bool) == true, let cmd = str("command"), !cmd.isEmpty {
                always = cmd.split(separator: " ").prefix(2).joined(separator: " ") + " *"
            }
            w.resume(returning: (allow, always)); push()
        case "set_mode":
            if let m = str("mode"), let sm = SessionMode(rawValue: m), sm != mode { mode = sm; newSession() }
        case "set_permission":
            if let p = str("permission"), let pl = PermissionLevel(rawValue: p) { permission = pl; if let cur = current { await cur.setPermission(pl) }; push() }
        case "set_trust":
            if let ws = workspace { WorkspaceTrust.set(ws, trusted: (a["trusted"] as? Bool) ?? false); push() }
        case "workspace_diff":
            guard let ws = workspace else { return ["error": "no workspace"] }
            let cwd = current?.cwd ?? ws.path
            func git(_ args: [String]) -> String {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args; p.currentDirectoryURL = URL(fileURLWithPath: cwd)
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                (try? p.run()) ?? (); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                return String(decoding: d, as: UTF8.self)
            }
            return ["stat": git(["diff", "--stat"]), "diff": String(git(["diff"]).prefix(200_000)), "untracked": git(["ls-files", "--others", "--exclude-standard"])]
        case "export":
            guard let cur = current else { return ["error": "no session"] }
            try? cur.save()
            return ["html": SessionExport.html(cur.record), "title": cur.record.title]
        default: return ["error": "unknown action \(type)"]
        }
        return ["ok": true]
    }

    // MARK: workspace

    func chooseWorkspace() {
        guard canUseNativePanels else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = workspace
        if panel.runModal() == .OK, let url = panel.url { openWorkspace(url) }
    }

    public func openWorkspace(_ url: URL) {
        generation += 1; let gen = generation
        workspace = url
        recents = WorkspaceStore.touch(url)
        sessions = SessionStore.list(workspace: url)
        commands = Commands(workspace: url)
        current = nil; timeline = []; lastUsage = nil; contextUsed = 0; busy = false; queue = []
        push()
        Task {
            await mcp.disconnectAll()
            guard gen == generation else { return }
            mcp = MCPHost()
            await mcp.connect(workspace: url) { [weak self] line in Task { @MainActor in self?.info(line) } }
            guard gen == generation else { return }
            mcpSummary = await mcp.summary(); mcpFailures = await mcp.failures
            await refreshMemory()
            if let first = sessions.first { resume(first.id) } else { newSession() }
        }
    }

    func refreshMemory() async { if let ws = workspace { memory = await MemoryStore.shared.allFacts(workspace: ws) } }

    // MARK: sessions

    func newSession(worktree: String? = nil) {
        guard let ws = workspace else { return }
        timeline = []; lastUsage = nil; current = nil; push()
        Task {
            var cwd = ws
            if let worktree, !worktree.isEmpty {
                do { let w = try Worktrees.add(repo: ws, branch: worktree); cwd = URL(fileURLWithPath: w.path); info("worktree \(worktree) at \(w.path)") }
                catch { self.error("\(error)"); return }
            }
            await load { try await AgentSession(spec: self.selected, workspace: ws, cwd: cwd, worktree: worktree, mode: self.mode, permission: self.permission, mcp: self.mcp, approver: self.approver, sink: self.sink) }
        }
    }

    func resume(_ id: String) {
        guard let ws = workspace, current?.record.id != id, let record = try? SessionStore.load(id, workspace: ws) else { return }
        timeline = []; lastUsage = nil; current = nil
        selected = record.spec; effort = record.effort; mode = record.mode; permission = record.permission
        replay(Compactor.sanitized(record.transcript)); push()
        Task { await load { try await AgentSession(record: record, spec: nil, mcp: self.mcp, approver: self.approver, sink: self.sink) } }
    }

    func select(_ spec: ModelSpec) {
        guard spec != selected else { return }
        selected = spec
        guard let cur = current else { pendingSpec = spec; push(); return }
        try? cur.save(); current = nil; push()
        Task { await load { try await AgentSession(record: cur.record, spec: spec, mcp: self.mcp, approver: self.approver, sink: self.sink) } }
    }

    func rename(_ id: String, to title: String) {
        guard let ws = workspace else { return }
        if current?.record.id == id { current?.rename(title) }
        else if var r = try? SessionStore.load(id, workspace: ws) { r.title = title; try? SessionStore.save(r) }
        sessions = SessionStore.list(workspace: ws); push()
    }

    func deleteSession(_ id: String) {
        guard let ws = workspace else { return }
        try? SessionStore.delete(id, workspace: ws)
        if current?.record.id == id { current = nil; timeline = [] }
        sessions = SessionStore.list(workspace: ws); push()
        if current == nil { if let first = sessions.first { resume(first.id) } else { newSession() } }
    }

    func fork(_ id: String, beforeUserTurn turn: Int?) {
        guard let ws = workspace else { return }
        if current?.record.id == id { try? current?.save() }
        guard let r = try? SessionStore.load(id, workspace: ws) else { return }
        let f = r.forked(beforeUserTurn: turn); try? SessionStore.save(f)
        sessions = SessionStore.list(workspace: ws); resume(f.id)
    }

    func revealWorktree(_ id: String) {
        guard let ws = workspace, let r = try? SessionStore.load(id, workspace: ws) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([r.cwdURL])
    }

    func compact() {
        guard let cur = current, !busy else { return }
        busy = true; push()
        Task { do { _ = try await cur.compact() } catch { self.error("\(error)") }; await updateContext(); busy = false; push() }
    }

    func stop() {
        for (id, w) in waiters { w.resume(returning: (false, nil)); pendingApprovals.removeAll { $0.id == id } }
        waiters.removeAll()
        runTask?.cancel(); queue.removeAll(); push()
    }

    private func load(_ make: @escaping () async throws -> AgentSession) async {
        generation += 1; let gen = generation
        if case .mlx(let id) = selected { loadingID = id; push() }
        do {
            let agent = try await make()
            guard gen == generation else { return }
            current = agent
            await updateContext()
        } catch { self.error("\(error)") }
        loadingID = nil
        await refreshModels()
        if let ws = workspace { sessions = SessionStore.list(workspace: ws) }
        // Apply pending spec if one was selected during loading
        if let pending = pendingSpec, current != nil {
            pendingSpec = nil
            let record = current!.record
            try? current?.save(); current = nil; push()
            Task { await load { try await AgentSession(record: record, spec: pending, mcp: self.mcp, approver: self.approver, sink: self.sink) } }
        } else {
            if let p = pending, current != nil { pending = nil; busy = false; send(p) } else { busy = false; push() }
        }
    }

    private func updateContext() async {
        guard let cur = current else { return }
        let (u, s) = await cur.contextUsage(); contextUsed = u; contextSize = s
    }

    private func replay(_ t: Transcript) {
        func text(_ segs: [Transcript.Segment]) -> String { segs.compactMap { if case .text(let s) = $0 { s.content } else { nil } }.joined() }
        var turn = 0
        for e in t {
            switch e {
            case .prompt(let p):
                let raw = text(p.segments)
                if raw.hasPrefix("Summary of the conversation so far") { timeline.append(.init(id: UUID().uuidString, kind: "info", title: "", text: "Earlier turns were compacted into a summary.", userTurn: nil)); continue }
                turn += 1
                timeline.append(.init(id: UUID().uuidString, kind: "user", title: "", text: Self.stripMemory(raw), userTurn: turn))
            case .response(let r):
                let s = text(r.segments)
                if s == "Understood. I will continue from this summary." { continue }
                timeline.append(.init(id: UUID().uuidString, kind: "assistant", title: "", text: s, userTurn: nil))
            case .toolCalls(let c): for call in c { timeline.append(.init(id: UUID().uuidString, kind: "toolCall", title: call.toolName, text: call.arguments.jsonString, userTurn: nil)) }
            case .toolOutput(let o): timeline.append(.init(id: UUID().uuidString, kind: "toolResult", title: o.toolName, text: text(o.segments), userTurn: nil))
            default: break
            }
        }
    }

    static func stripMemory(_ s: String) -> String {
        guard s.hasPrefix("Relevant memory:\n"), let r = s.range(of: "\n\n") else { return s }
        return String(s[r.upperBound...])
    }

    // MARK: sending

    public func send(_ raw: String) {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if busy, current != nil { queue.append(raw); push(); return }
        guard let cur = current else { if workspace != nil { pending = raw; busy = true; push() }; return }
        if raw == "/compact" { compact(); return }
        if raw == "/new" { newSession(); return }
        let prompt = commands.expand(raw) ?? raw
        let turn = (timeline.compactMap(\.userTurn).max() ?? 0) + 1
        timeline.append(.init(id: UUID().uuidString, kind: "user", title: "", text: raw, userTurn: turn))
        busy = true; push()
        runTask = Task {
            do { try await cur.run(prompt, effort: effort) }
            catch is CancellationError { info("stopped") }
            catch { self.error("\(error)") }
            await updateContext(); await refreshMemory()
            busy = false; runTask = nil
            if let ws = workspace { sessions = SessionStore.list(workspace: ws) }
            push()
            if !queue.isEmpty { send(queue.removeFirst()) }
        }
    }

    private var sink: EventSink { { [weak self] ev in Task { @MainActor in self?.handleEvent(ev) } } }

    /// Suspends the tool until the web UI answers.
    private var approver: Approver {
        { [weak self] r in
            await withCheckedContinuation { (c: CheckedContinuation<(Bool, String?), Never>) in
                Task { @MainActor in
                    guard let self else { c.resume(returning: (false, nil)); return }
                    self.waiters[r.id] = c
                }
            }
        }
    }

    private func handleEvent(_ ev: AgentEvent) {
        switch ev {
        case .textDelta(let t):
            if let last = timeline.indices.last, timeline[last].kind == "assistant" {
                timeline[last].text += t
                emit("delta", ["id": timeline[last].id, "text": t])
            } else {
                let item = Item(id: UUID().uuidString, kind: "assistant", title: "", text: t, userTurn: nil)
                timeline.append(item); emit("append", item.json)
            }
        case .toolCall(let name, let args): append(.init(id: UUID().uuidString, kind: "toolCall", title: name, text: args, userTurn: nil))
        case .toolResult(let name, let output): append(.init(id: UUID().uuidString, kind: "toolResult", title: name, text: output, userTurn: nil))
        case .finished(let usage, _): lastUsage = usage; footprint = SystemMemory.footprint()
        case .warning(let w): append(.init(id: UUID().uuidString, kind: "warning", title: "", text: w, userTurn: nil))
        case .info(let i): info(i)
        case .approvalNeeded(let r): pendingApprovals.append(r); push()
        case .approvalResolved(let id, let allowed, let layer):
            audit.append((id, allowed, layer))
            pendingApprovals.removeAll { $0.id == id }
            if !allowed || layer.hasPrefix("classifier") || layer.hasPrefix("provenance") || layer == "user" {
                append(.init(id: UUID().uuidString, kind: "audit", title: allowed ? "allowed" : "denied", text: layer, userTurn: nil))
            }
        }
    }

    private func append(_ item: Item) { timeline.append(item); emit("append", item.json) }
    private func info(_ s: String) { append(.init(id: UUID().uuidString, kind: "info", title: "", text: s, userTurn: nil)) }
    private func error(_ s: String) { append(.init(id: UUID().uuidString, kind: "error", title: "", text: s, userTurn: nil)) }

    // MARK: models

    func pull(_ id: String) {
        let id = id.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, pulls[id] == nil else { return }
        pulls[id] = 0; pullErrors[id] = nil; push()
        pullTasks[id] = Task {
            do {
                _ = try await ModelStore.shared.pull(id) { fraction, _ in Task { @MainActor in self.pulls[id] = fraction; self.emit("pull", ["id": id, "fraction": fraction]) } }
                await refreshModels()
            } catch is CancellationError {} catch { pullErrors[id] = "\(error)" }
            pulls[id] = nil; pullTasks[id] = nil; push()
        }
    }
}
