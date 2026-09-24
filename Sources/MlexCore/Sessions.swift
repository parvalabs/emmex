import Foundation
import FoundationModels

/// A saved conversation. The transcript is the framework's own type, so resuming is exact.
public struct SessionRecord: Codable, Identifiable, Sendable {
    public var id: String
    public var workspace: String          // project root the session belongs to
    public var cwd: String                // where tools run: the workspace or a worktree
    public var worktree: String?          // worktree branch name, if any
    public var title: String
    public var model: String              // ModelSpec description
    public var effort: Effort
    public var createdAt: Date
    public var updatedAt: Date
    public var turns: Int
    public var transcript: Transcript
    public var mode: SessionMode = .code
    public var permission: PermissionLevel = .smart

    enum CodingKeys: String, CodingKey { case id, workspace, cwd, worktree, title, model, effort, createdAt, updatedAt, turns, transcript, mode, permission }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); workspace = try c.decode(String.self, forKey: .workspace); cwd = try c.decode(String.self, forKey: .cwd)
        worktree = try c.decodeIfPresent(String.self, forKey: .worktree); title = try c.decode(String.self, forKey: .title); model = try c.decode(String.self, forKey: .model)
        effort = try c.decodeIfPresent(Effort.self, forKey: .effort) ?? .default; createdAt = try c.decode(Date.self, forKey: .createdAt); updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        turns = try c.decode(Int.self, forKey: .turns); transcript = try c.decode(Transcript.self, forKey: .transcript)
        mode = try c.decodeIfPresent(SessionMode.self, forKey: .mode) ?? .code; permission = try c.decodeIfPresent(PermissionLevel.self, forKey: .permission) ?? .smart
    }

    public init(workspace: URL, cwd: URL, worktree: String? = nil, model: ModelSpec, effort: Effort = .default, mode: SessionMode = .code, permission: PermissionLevel = .smart) {
        id = UUID().uuidString.lowercased()
        self.workspace = workspace.standardizedFileURL.path
        self.cwd = cwd.standardizedFileURL.path
        self.worktree = worktree
        title = "New session"
        self.model = model.description
        self.effort = effort
        createdAt = Date(); updatedAt = createdAt
        turns = 0
        transcript = Transcript()
        self.mode = mode; self.permission = permission
    }

    public var workspaceURL: URL { URL(fileURLWithPath: workspace) }
    public var cwdURL: URL { URL(fileURLWithPath: cwd) }
    public var spec: ModelSpec { (try? ModelSpec(parsing: model)) ?? .system }
}

/// Session metadata without the transcript, for lists.
public struct SessionSummary: Identifiable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var model: String
    public var worktree: String?
    public var updatedAt: Date
    public var turns: Int
}

/// Sessions live at Application Support/mlex/sessions/<workspace-key>/<id>.json.
public enum SessionStore {
    /// Titles saved from a memory-prefixed prompt (an earlier bug) are re-derived from the
    /// transcript's first user prompt on read, and the file is repaired.
    static func cleanTitle(_ r: SessionRecord) -> String {
        guard r.title.hasPrefix("Relevant memory:") else { return r.title }
        for e in r.transcript {
            if case .prompt(let p) = e {
                var text = p.segments.compactMap { if case .text(let t) = $0 { t.content } else { nil } }.joined()
                if text.hasPrefix("Relevant memory:"), let cut = text.range(of: "\n\n") { text = String(text[cut.upperBound...]) }
                let one = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                let title = one.count > 60 ? String(one.prefix(57)) + "…" : one
                var fixed = r; fixed.title = title; try? save(fixed)
                return title
            }
        }
        return r.title
    }
    public static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    public static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    public static func directory(for workspace: URL) -> URL {
        Paths.sessions.appending(path: Paths.key(for: workspace))
    }

    public static func url(for id: String, workspace: URL) -> URL {
        directory(for: workspace).appending(path: "\(id).json")
    }

    public static func save(_ record: SessionRecord) throws {
        let dir = directory(for: record.workspaceURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encoder.encode(record).write(to: dir.appending(path: "\(record.id).json"), options: .atomic)
    }

    public static func load(_ id: String, workspace: URL) throws -> SessionRecord {
        try decoder.decode(SessionRecord.self, from: Data(contentsOf: url(for: id, workspace: workspace)))
    }

    /// Find a session by id (or unique id prefix) across all workspaces.
    public static func find(_ idOrPrefix: String) throws -> SessionRecord? {
        let fm = FileManager.default
        guard let keys = try? fm.contentsOfDirectory(atPath: Paths.sessions.path) else { return nil }
        for key in keys {
            let dir = Paths.sessions.appending(path: key)
            for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".json") {
                if f.hasPrefix(idOrPrefix) {
                    return try decoder.decode(SessionRecord.self, from: Data(contentsOf: dir.appending(path: f)))
                }
            }
        }
        return nil
    }

    public static func delete(_ id: String, workspace: URL) throws {
        try FileManager.default.removeItem(at: url(for: id, workspace: workspace))
    }

    /// Newest first. Reads each file but drops the transcript from the result.
    public static func list(workspace: URL) -> [SessionSummary] {
        let dir = directory(for: workspace)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return files.filter { $0.hasSuffix(".json") }.compactMap { f -> SessionSummary? in
            guard let data = try? Data(contentsOf: dir.appending(path: f)),
                  let r = try? decoder.decode(SessionRecord.self, from: data) else { return nil }
            return SessionSummary(id: r.id, title: Self.cleanTitle(r), model: r.model, worktree: r.worktree, updatedAt: r.updatedAt, turns: r.turns)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
}

/// Recently opened project folders, most recent first.
public enum WorkspaceStore {
    public struct Entry: Codable, Identifiable, Sendable, Hashable {
        public var path: String
        public var lastOpened: Date
        public var id: String { path }
        public var url: URL { URL(fileURLWithPath: path) }
        public var name: String { url.lastPathComponent }
    }

    public static func recents() -> [Entry] {
        guard let data = try? Data(contentsOf: Paths.workspacesFile),
              let list = try? SessionStore.decoder.decode([Entry].self, from: data) else { return [] }
        return list.filter { FileManager.default.fileExists(atPath: $0.path) }.sorted { $0.lastOpened > $1.lastOpened }
    }

    @discardableResult
    public static func touch(_ workspace: URL) -> [Entry] {
        var list = recents().filter { $0.path != workspace.standardizedFileURL.path }
        list.insert(.init(path: workspace.standardizedFileURL.path, lastOpened: Date()), at: 0)
        list = Array(list.prefix(30))
        try? FileManager.default.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
        try? SessionStore.encoder.encode(list).write(to: Paths.workspacesFile, options: .atomic)
        return list
    }

    public static func forget(_ workspace: URL) {
        let list = recents().filter { $0.path != workspace.standardizedFileURL.path }
        try? SessionStore.encoder.encode(list).write(to: Paths.workspacesFile, options: .atomic)
    }
}
