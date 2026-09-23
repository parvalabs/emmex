import Foundation
import FoundationModels

/// Long-term memory per workspace: short facts extracted by the on-device model after each turn,
/// stored at Application Support/mlex/memory/<workspace-key>.json, and injected at session start
/// plus retrieved per message by keyword overlap. Everything stays on the machine.
public struct MemoryFact: Codable, Identifiable, Sendable, Hashable {
    public var id: String
    public var text: String
    public var kind: String            // preference | project | decision | reference | other
    public var createdAt: Date
    public var lastUsed: Date
    public var uses: Int
    public var source: String          // session id
}

public actor MemoryStore {
    public static let shared = MemoryStore()
    static let maxFacts = 400

    public func url(for workspace: URL) -> URL {
        Paths.appSupport.appending(path: "memory").appending(path: "\(Paths.key(for: workspace)).json")
    }

    public func facts(workspace: URL) -> [MemoryFact] {
        guard let data = try? Data(contentsOf: url(for: workspace)),
              let f = try? SessionStore.decoder.decode([MemoryFact].self, from: data) else { return [] }
        return f
    }

    func save(_ facts: [MemoryFact], workspace: URL) throws {
        let u = url(for: workspace)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SessionStore.encoder.encode(facts).write(to: u, options: .atomic)
    }

    /// Add facts, skipping near-duplicates (same normalized text). Oldest, least-used facts are
    /// pruned past the cap.
    @discardableResult
    public func add(_ new: [(text: String, kind: String)], workspace: URL, source: String) throws -> Int {
        var facts = facts(workspace: workspace)
        var existing = Set(facts.map { Self.normalize($0.text) })
        var keywordSets = facts.map { Set(Self.keywords($0.text)) }
        var added = 0
        for n in new {
            let t = n.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 8, t.count <= 300, existing.insert(Self.normalize(t)).inserted else { continue }
            // Near-duplicate by keyword overlap (a restated fact with different wording).
            let kw = Set(Self.keywords(t))
            if !kw.isEmpty, keywordSets.contains(where: { other in
                guard !other.isEmpty else { return false }
                let inter = kw.intersection(other).count
                return Double(inter) / Double(kw.union(other).count) >= 0.45 || inter == min(kw.count, other.count)   // overlap, or one subsumes the other
            }) { continue }
            keywordSets.append(kw)
            facts.append(.init(id: UUID().uuidString.lowercased(), text: t, kind: n.kind, createdAt: Date(), lastUsed: Date(), uses: 0, source: source))
            added += 1
        }
        if facts.count > Self.maxFacts {
            facts.sort { ($0.uses, $0.lastUsed) > ($1.uses, $1.lastUsed) }
            facts = Array(facts.prefix(Self.maxFacts))
        }
        try save(facts, workspace: workspace)
        return added
    }

    public func remove(_ id: String, workspace: URL) throws {
        try save(facts(workspace: workspace).filter { $0.id != id }, workspace: workspace)
    }

    public func clear(workspace: URL) throws {
        try? FileManager.default.removeItem(at: url(for: workspace))
    }

    /// Facts relevant to a prompt: keyword overlap, preferences always included, newest first.
    public func relevant(to prompt: String, workspace: URL, limit: Int = 8) -> [MemoryFact] {
        let facts = facts(workspace: workspace)
        guard !facts.isEmpty else { return [] }
        let words = Set(Self.keywords(prompt))
        var scored: [(MemoryFact, Int)] = facts.map { f in
            var score = Set(Self.keywords(f.text)).intersection(words).count * 3
            if f.kind == "preference" { score += 2 }
            if f.kind == "decision" { score += 1 }
            return (f, score)
        }
        scored.sort { ($0.1, $0.0.createdAt) > ($1.1, $1.0.createdAt) }
        return scored.prefix(limit).filter { $0.1 > 0 }.map(\.0)
    }

    /// Prompt section for injection.
    public static func promptSection(_ facts: [MemoryFact]) -> String? {
        guard !facts.isEmpty else { return nil }
        return "Memory. These are facts you remembered from earlier sessions with this user and project; treat them as your own memories and, when asked what you remember, list them:\n" + facts.map { "- \($0.text)" }.joined(separator: "\n")
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.split(separator: " ").joined(separator: " ")
    }

    static let stop: Set<String> = ["the","a","an","and","or","of","to","in","on","for","is","are","it","this","that","with","as","by","at","be","was","from","we","i","you","my","our","use","using","file","files"]
    static func keywords(_ s: String) -> [String] {
        normalize(s).split(separator: " ").map(String.init).filter { $0.count > 2 && !stop.contains($0) }.map(stem)
    }
    /// Just enough stemming to make "deploys"/"deploy" and "messages"/"message" match.
    static func stem(_ w: String) -> String {
        var w = w
        for suffix in ["ing", "ed", "es", "s"] where w.count > 4 && w.hasSuffix(suffix) { w.removeLast(suffix.count); break }
        return w
    }
}

/// Fact extraction with the on-device model: guided generation to a list of typed facts.
public enum MemoryExtractor {
    static let instructions = """
    You extract durable facts from one exchange between a user and a coding agent, for use in \
    future sessions on the same project. Keep only what will still matter later: user preferences \
    and conventions, decisions made, project facts (stack, structure, names, commands), and \
    references (URLs, tickets). Skip transient details, tool output, and anything already obvious \
    from the code. Each fact is one short self-contained sentence. Return an empty list if nothing \
    is worth remembering.
    """

    public static func extract(prompt: String, response: String, toolSummary: String) async throws -> [(text: String, kind: String)] {
        let fact = DynamicGenerationSchema(name: "Fact", properties: [
            .init(name: "text", description: "One short self-contained sentence", schema: SchemaBuilder.string),
            .init(name: "kind", description: "Category", schema: SchemaBuilder.choice("Kind", ["preference", "project", "decision", "reference", "other"])),
        ])
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Facts", properties: [
            .init(name: "facts", description: "Zero to four facts", schema: DynamicGenerationSchema(arrayOf: fact, minimumElements: 0, maximumElements: 4)),
        ]), dependencies: [])
        let session = LanguageModelSession(model: .default, instructions: instructions)
        let input = "User: \(prompt.prefix(1500))\n\nAgent: \(response.prefix(1500))\n\nTools used: \(toolSummary.prefix(400))"
        let r = try await session.respond(to: input, schema: schema, options: GenerationOptions(maximumResponseTokens: 300))
        let items = try r.content.value([GeneratedContent].self, forProperty: "facts")
        return items.compactMap { item in
            guard let t = try? item.value(String.self, forProperty: "text") else { return nil }
            let k = (try? item.value(String.self, forProperty: "kind")) ?? "other"
            return (t, k)
        }
    }
}
