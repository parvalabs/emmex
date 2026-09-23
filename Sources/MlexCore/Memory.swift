import Foundation
import FoundationModels

/// Long-term memory: short facts extracted by the on-device model after each turn.
/// Project facts live at Application Support/mlex/memory/<workspace-key>.json; facts about the
/// user in general live in memory/global.json and apply to every workspace. Retrieval combines
/// on-device sentence embeddings with keyword overlap. Everything stays on the machine.
public struct MemoryFact: Codable, Identifiable, Sendable, Hashable {
    public var id: String
    public var text: String
    public var kind: String            // preference | project | decision | reference | other
    public var scope: String           // project | user
    public var createdAt: Date
    public var lastUsed: Date
    public var uses: Int
    public var source: String          // session id
    public var embedding: [Float]?

    enum CodingKeys: String, CodingKey { case id, text, kind, scope, createdAt, lastUsed, uses, source, embedding }
    public init(id: String, text: String, kind: String, scope: String, createdAt: Date, lastUsed: Date, uses: Int, source: String, embedding: [Float]?) {
        self.id = id; self.text = text; self.kind = kind; self.scope = scope; self.createdAt = createdAt; self.lastUsed = lastUsed; self.uses = uses; self.source = source; self.embedding = embedding
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); text = try c.decode(String.self, forKey: .text)
        kind = try c.decode(String.self, forKey: .kind); scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? "project"
        createdAt = try c.decode(Date.self, forKey: .createdAt); lastUsed = try c.decode(Date.self, forKey: .lastUsed)
        uses = try c.decode(Int.self, forKey: .uses); source = try c.decode(String.self, forKey: .source)
        embedding = try c.decodeIfPresent([Float].self, forKey: .embedding)
    }
}

public actor MemoryStore {
    public static let shared = MemoryStore()
    static let maxFacts = 400
    static let duplicateCosine: Float = 0.90
    static let relevantCosine: Float = 0.25

    public func url(for workspace: URL) -> URL { Paths.appSupport.appending(path: "memory").appending(path: "\(Paths.key(for: workspace)).json") }
    public var globalURL: URL { Paths.appSupport.appending(path: "memory/global.json") }

    func read(_ u: URL) -> [MemoryFact] {
        guard let data = try? Data(contentsOf: u), let f = try? SessionStore.decoder.decode([MemoryFact].self, from: data) else { return [] }
        return f
    }
    func write(_ facts: [MemoryFact], to u: URL) throws {
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SessionStore.encoder.encode(facts).write(to: u, options: .atomic)
    }

    /// Project facts plus user-level facts. Facts saved before embeddings existed get one now.
    public func facts(workspace: URL) async -> [MemoryFact] {
        var project = read(url(for: workspace)), global = read(globalURL)
        if await backfill(&project) { try? write(project, to: url(for: workspace)) }
        if await backfill(&global) { try? write(global, to: globalURL) }
        return project + global
    }

    private func backfill(_ facts: inout [MemoryFact]) async -> Bool {
        var changed = false
        for i in facts.indices where facts[i].embedding == nil {
            facts[i].embedding = await Embedder.shared.vector(for: facts[i].text); changed = true
        }
        return changed
    }

    /// Add facts, skipping duplicates by normalized text, keyword overlap, or embedding similarity.
    @discardableResult
    public func add(_ new: [(text: String, kind: String, scope: String)], workspace: URL, source: String) async throws -> [MemoryFact] {
        var project = read(url(for: workspace)), global = read(globalURL)
        let existing = project + global
        var normalized = Set(existing.map { Self.normalize($0.text) })
        var keywordSets = existing.map { Set(Self.keywords($0.text)) }
        var vectors = existing.compactMap(\.embedding)
        var added: [MemoryFact] = []
        for n in new {
            let t = n.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 8, t.count <= 300, normalized.insert(Self.normalize(t)).inserted else { continue }
            let kw = Set(Self.keywords(t))
            if !kw.isEmpty, keywordSets.contains(where: { other in
                guard !other.isEmpty else { return false }
                let inter = kw.intersection(other).count
                return Double(inter) / Double(kw.union(other).count) >= 0.45 || inter == min(kw.count, other.count)
            }) { continue }
            let vec = await Embedder.shared.vector(for: t)
            if let vec, vectors.contains(where: { Embedder.cosine($0, vec) >= Self.duplicateCosine }) { continue }
            keywordSets.append(kw); if let vec { vectors.append(vec) }
            let fact = MemoryFact(id: UUID().uuidString.lowercased(), text: t, kind: n.kind, scope: n.scope == "user" ? "user" : "project",
                                  createdAt: Date(), lastUsed: Date(), uses: 0, source: source, embedding: vec)
            if fact.scope == "user" { global.append(fact) } else { project.append(fact) }
            added.append(fact)
        }
        for list in [project, global] where list.count > Self.maxFacts {
            // Prune least-used, oldest first.
        }
        project = Self.prune(project); global = Self.prune(global)
        try write(project, to: url(for: workspace)); try write(global, to: globalURL)
        return added
    }

    static func prune(_ facts: [MemoryFact]) -> [MemoryFact] {
        guard facts.count > maxFacts else { return facts }
        return Array(facts.sorted { ($0.uses, $0.lastUsed) > ($1.uses, $1.lastUsed) }.prefix(maxFacts))
    }

    public func remove(_ id: String, workspace: URL) throws {
        try write(read(url(for: workspace)).filter { $0.id != id }, to: url(for: workspace))
        try write(read(globalURL).filter { $0.id != id }, to: globalURL)
    }

    public func clear(workspace: URL, includingGlobal: Bool = false) throws {
        try? FileManager.default.removeItem(at: url(for: workspace))
        if includingGlobal { try? FileManager.default.removeItem(at: globalURL) }
    }

    /// Record that facts were shown to the model, so pruning keeps what gets used.
    public func markUsed(_ ids: [String], workspace: URL) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        for u in [url(for: workspace), globalURL] {
            var facts = read(u); var changed = false
            for i in facts.indices where set.contains(facts[i].id) { facts[i].uses += 1; facts[i].lastUsed = Date(); changed = true }
            if changed { try? write(facts, to: u) }
        }
    }

    /// Facts relevant to a prompt: embedding similarity plus keyword overlap, preferences boosted.
    public func relevant(to prompt: String, workspace: URL, limit: Int = 8) async -> [MemoryFact] {
        let facts = await facts(workspace: workspace)
        guard !facts.isEmpty else { return [] }
        let words = Set(Self.keywords(prompt))
        let qv = await Embedder.shared.vector(for: prompt)
        var scored: [(MemoryFact, Float)] = facts.map { f in
            let kw = Float(Set(Self.keywords(f.text)).intersection(words).count)
            let sim: Float = (qv != nil && f.embedding != nil) ? Embedder.cosine(qv!, f.embedding!) : 0
            var score = sim + 0.15 * kw
            if f.kind == "preference" { score += 0.05 }
            if sim < Self.relevantCosine, kw == 0 { score = 0 }
            return (f, score)
        }
        scored.sort { ($0.1, $0.0.createdAt) > ($1.1, $1.0.createdAt) }
        return scored.prefix(limit).filter { $0.1 > 0 }.map(\.0)
    }

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
    static func stem(_ w: String) -> String {
        var w = w
        for suffix in ["ing", "ed", "es", "s"] where w.count > 4 && w.hasSuffix(suffix) { w.removeLast(suffix.count); break }
        return w
    }
}

/// Fact extraction with the on-device model: guided generation to a list of typed, scoped facts.
public enum MemoryExtractor {
    static let instructions = """
    You extract durable facts from one exchange between a user and a coding agent, for use in \
    future sessions. Keep only what will still matter later: user preferences and conventions, \
    decisions made, project facts (stack, structure, names, commands), and references (URLs, \
    tickets). Skip transient details, tool output, and anything already obvious from the code. \
    Each fact is one short self-contained sentence. Scope is "user" when the fact is about the \
    person in general and would apply in any project (how they like answers, tools they use, \
    habits); "project" when it is specific to this codebase. Return an empty list if nothing is \
    worth remembering.
    """

    public static func extract(prompt: String, response: String, toolSummary: String) async throws -> [(text: String, kind: String, scope: String)] {
        let fact = DynamicGenerationSchema(name: "Fact", properties: [
            .init(name: "text", description: "One short self-contained sentence", schema: SchemaBuilder.string),
            .init(name: "kind", description: "Category", schema: SchemaBuilder.choice("Kind", ["preference", "project", "decision", "reference", "other"])),
            .init(name: "scope", description: "user = about the person in general; project = specific to this codebase", schema: SchemaBuilder.choice("Scope", ["project", "user"])),
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
            return (t, (try? item.value(String.self, forProperty: "kind")) ?? "other", (try? item.value(String.self, forProperty: "scope")) ?? "project")
        }
    }
}
