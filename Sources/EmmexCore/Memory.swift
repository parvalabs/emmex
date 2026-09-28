import Foundation
import FoundationModels

/// Long-term memory: short facts extracted by the on-device model after each turn.
/// Project facts live at Application Support/emmex/memory/<workspace-key>.json; facts about the
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
    public var archived: Bool          // expired or superseded; kept for restore
    public var supersededBy: String?   // id of the fact that replaced this one

    enum CodingKeys: String, CodingKey { case id, text, kind, scope, createdAt, lastUsed, uses, source, embedding, archived, supersededBy }
    public init(id: String, text: String, kind: String, scope: String, createdAt: Date, lastUsed: Date, uses: Int, source: String, embedding: [Float]?, archived: Bool = false, supersededBy: String? = nil) {
        self.id = id; self.text = text; self.kind = kind; self.scope = scope; self.createdAt = createdAt; self.lastUsed = lastUsed; self.uses = uses; self.source = source; self.embedding = embedding; self.archived = archived; self.supersededBy = supersededBy
    }

    /// Importance: uses discounted by time since last use (half-life 30 days), plus a small
    /// freshness bonus so brand-new facts are not ranked below everything.
    public func score(now: Date = Date()) -> Double {
        let ageDays = max(0, now.timeIntervalSince(lastUsed) / 86_400)
        let fresh = max(0, 7 - now.timeIntervalSince(createdAt) / 86_400) / 7
        return (Double(uses) + 1) * pow(0.5, ageDays / 30) + 0.5 * fresh
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); text = try c.decode(String.self, forKey: .text)
        kind = try c.decode(String.self, forKey: .kind); scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? "project"
        createdAt = try c.decode(Date.self, forKey: .createdAt); lastUsed = try c.decode(Date.self, forKey: .lastUsed)
        uses = try c.decode(Int.self, forKey: .uses); source = try c.decode(String.self, forKey: .source)
        embedding = try c.decodeIfPresent([Float].self, forKey: .embedding)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        supersededBy = try c.decodeIfPresent(String.self, forKey: .supersededBy)
    }
}

public actor MemoryStore {
    public static let shared = MemoryStore()
    static let maxFacts = 400
    static let duplicateCosine: Float = 0.90
    static let supersedeCosine: Float = 0.55     // candidates for the relation classifier (changed values score ~0.7)
    static let clusterCosine: Float = 0.55       // consolidation groups (0.40 if a keyword is shared)
    static let relevantCosine: Float = 0.25
    static let expireUnusedDays = 30.0            // never used since creation
    static let expireIdleDays = 90.0              // not used for this long
    static let autoConsolidateAdds = 8            // new facts since the last run…
    static let autoConsolidateDays = 1.0          // …or this long since it, with at least 10 facts

    public func url(for workspace: URL) -> URL { Paths.appSupport.appending(path: "memory").appending(path: "\(Paths.key(for: workspace)).json") }
    func metaURL(for workspace: URL) -> URL { Paths.appSupport.appending(path: "memory").appending(path: "\(Paths.key(for: workspace)).meta.json") }

    struct Meta: Codable { var lastConsolidated: Date?; var addsSince: Int = 0 }
    func meta(for workspace: URL) -> Meta {
        (try? Data(contentsOf: metaURL(for: workspace))).flatMap { try? SessionStore.decoder.decode(Meta.self, from: $0) } ?? Meta()
    }
    func saveMeta(_ m: Meta, for workspace: URL) { try? SessionStore.encoder.encode(m).write(to: metaURL(for: workspace), options: .atomic) }

    /// Whether enough has changed to consolidate automatically.
    public func shouldAutoConsolidate(workspace: URL) async -> Bool {
        let m = meta(for: workspace)
        if m.addsSince >= Self.autoConsolidateAdds { return true }
        let active = (await facts(workspace: workspace)).count
        guard active >= 10 else { return false }
        guard let last = m.lastConsolidated else { return true }
        return Date().timeIntervalSince(last) > Self.autoConsolidateDays * 86_400
    }
    public var globalURL: URL { Paths.appSupport.appending(path: "memory/global.json") }

    func read(_ u: URL) -> [MemoryFact] {
        guard let data = try? Data(contentsOf: u), let f = try? SessionStore.decoder.decode([MemoryFact].self, from: data) else { return [] }
        return f
    }
    func write(_ facts: [MemoryFact], to u: URL) throws {
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SessionStore.encoder.encode(facts).write(to: u, options: .atomic)
    }

    /// Active project facts plus user-level facts. Facts saved before embeddings existed get one
    /// now, and facts that were never used within 30 days or not used for 90 days are archived.
    public func facts(workspace: URL) async -> [MemoryFact] {
        (await allFacts(workspace: workspace)).filter { !$0.archived }
    }

    /// Every fact including archived ones, after backfill and expiry.
    public func allFacts(workspace: URL) async -> [MemoryFact] {
        var project = read(url(for: workspace)), global = read(globalURL)
        var c1 = await backfill(&project), c2 = await backfill(&global)
        if Self.expire(&project) { c1 = true }
        if Self.expire(&global) { c2 = true }
        if c1 { try? write(project, to: url(for: workspace)) }
        if c2 { try? write(global, to: globalURL) }
        return project + global
    }

    static func expire(_ facts: inout [MemoryFact], now: Date = Date()) -> Bool {
        var changed = false
        for i in facts.indices where !facts[i].archived {
            let idle = now.timeIntervalSince(facts[i].lastUsed) / 86_400
            let age = now.timeIntervalSince(facts[i].createdAt) / 86_400
            if (facts[i].uses == 0 && age > expireUnusedDays) || idle > expireIdleDays { facts[i].archived = true; changed = true }
        }
        return changed
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
        var added: [MemoryFact] = []
        for n in new {
            let t = n.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 8, t.count <= 300 else { continue }
            let active = (project + global).filter { !$0.archived }
            if active.contains(where: { Self.normalize($0.text) == Self.normalize(t) }) { continue }
            let kw = Set(Self.keywords(t))
            let vec = await Embedder.shared.vector(for: t)
            // Relationship to each active fact. Cheap checks first: identical keywords are a
            // duplicate. For anything else on a similar subject, the on-device model decides
            // whether the new fact duplicates, conflicts with (supersedes), or complements it.
            // Facts extracted in this same turn are siblings and never compared.
            var isDuplicate = false
            var supersedes: [String] = []
            let batchIDs = Set(added.map(\.id))
            for f in active where !batchIDs.contains(f.id) {
                let other = Set(Self.keywords(f.text))
                let inter = kw.intersection(other).count
                let overlap = kw.isEmpty || other.isEmpty ? 0 : Double(inter) / Double(kw.union(other).count)
                let sim: Float = (vec != nil && f.embedding != nil) ? Embedder.cosine(vec!, f.embedding!) : 0
                if kw == other || (kw.isSubset(of: other) && !kw.isEmpty) { isDuplicate = true; break }
                guard sim >= Self.supersedeCosine || (sim >= 0.40 && inter > 0) || overlap >= 0.6 else { continue }
                switch (try? await MemoryConsolidator.relation([t, f.text])) ?? "complementary" {
                case "duplicate": isDuplicate = true
                case "conflict": supersedes.append(f.id)
                default: break
                }
                if isDuplicate { break }
            }
            if isDuplicate { continue }
            let fact = MemoryFact(id: UUID().uuidString.lowercased(), text: t, kind: n.kind, scope: n.scope == "user" ? "user" : "project",
                                  createdAt: Date(), lastUsed: Date(), uses: 0, source: source, embedding: vec)
            let ids = Set(supersedes)
            for i in project.indices where ids.contains(project[i].id) { project[i].archived = true; project[i].supersededBy = fact.id }
            for i in global.indices where ids.contains(global[i].id) { global[i].archived = true; global[i].supersededBy = fact.id }
            if fact.scope == "user" { global.append(fact) } else { project.append(fact) }
            added.append(fact)
        }
        project = Self.prune(project); global = Self.prune(global)
        try write(project, to: url(for: workspace)); try write(global, to: globalURL)
        if !added.isEmpty { var m = meta(for: workspace); m.addsSince += added.count; saveMeta(m, for: workspace) }
        return added
    }

    /// Keep the cap by importance score; archived facts are dropped first, then the lowest scores.
    static func prune(_ facts: [MemoryFact]) -> [MemoryFact] {
        guard facts.count > maxFacts else { return facts }
        let active = facts.filter { !$0.archived }.sorted { $0.score() > $1.score() }
        let archived = facts.filter(\.archived).sorted { $0.lastUsed > $1.lastUsed }
        return Array((active + archived).prefix(maxFacts))
    }

    public func restore(_ id: String, workspace: URL) throws {
        for u in [url(for: workspace), globalURL] {
            var facts = read(u)
            if let i = facts.firstIndex(where: { $0.id == id }) { facts[i].archived = false; facts[i].supersededBy = nil; facts[i].lastUsed = Date(); try write(facts, to: u) }
        }
    }

    /// Merge overlapping facts with the on-device model. Within a cluster the most recent fact
    /// wins on conflicts; the merged fact inherits the newest date, the summed uses, and the
    /// latest last-used time. Originals are archived as superseded. Returns merges made.
    public func consolidate(workspace: URL) async throws -> [(merged: String, from: [String])] {
        var result: [(String, [String])] = []
        for u in [url(for: workspace), globalURL] {
            var facts = read(u)
            let active = facts.indices.filter { !facts[$0].archived && facts[$0].embedding != nil }
            var seen = Set<Int>()
            for i in active where !seen.contains(i) {
                var cluster = [i]; seen.insert(i)
                let kwI = Set(Self.keywords(facts[i].text))
                for j in active where !seen.contains(j) {
                    let sim = Embedder.cosine(facts[i].embedding!, facts[j].embedding!)
                    let shared = !kwI.intersection(Self.keywords(facts[j].text)).isEmpty
                    if sim >= Self.clusterCosine || (sim >= 0.40 && shared) { cluster.append(j); seen.insert(j) }
                }
                guard cluster.count > 1 else { continue }
                let members = cluster.map { facts[$0] }.sorted { $0.createdAt > $1.createdAt }   // newest first
                // The model only classifies the cluster; on duplicate or conflict the newest fact is
                // kept verbatim, so "newest wins" is guaranteed rather than hoped for.
                let relation = (try? await MemoryConsolidator.relation(members.map(\.text))) ?? "complementary"
                if relation == "different" { continue }
                let text: String
                if relation == "complementary" {
                    guard let merged = try await MemoryConsolidator.merge(members.map(\.text)) else { continue }
                    text = merged
                } else { text = members[0].text }
                let vec = await Embedder.shared.vector(for: text)
                let merged = MemoryFact(id: UUID().uuidString.lowercased(), text: text, kind: members[0].kind, scope: members[0].scope,
                                        createdAt: members[0].createdAt, lastUsed: members.map(\.lastUsed).max() ?? Date(),
                                        uses: members.map(\.uses).reduce(0, +), source: members[0].source, embedding: vec)
                for k in cluster { facts[k].archived = true; facts[k].supersededBy = merged.id }
                facts.append(merged)
                result.append((text, members.map(\.text)))
            }
            if !result.isEmpty { try write(Self.prune(facts), to: u) }
        }
        saveMeta(Meta(lastConsolidated: Date(), addsSince: 0), for: workspace)
        return result
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
            var score = sim + 0.15 * kw + 0.02 * Float(min(f.score(), 5))
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
    Skip negative or dead-end findings: what could not be found, what is not documented, what \
    the agent did not do or could not answer; those are not facts about the project. \
    Each fact is one short self-contained sentence. Scope is "user" when the fact is about the \
    person in general and would apply in any project (how they like answers, tools they use, \
    habits); "project" when it is specific to this codebase. Return an empty list if nothing is \
    worth remembering.
    """

    /// `model` nil uses the on-device model; a Claude spec (the cheap tier) extracts far cleaner facts
    /// and is worth it when the turn already paid for Claude.
    public static func extract(prompt: String, response: String, toolSummary: String, model: ModelSpec? = nil) async throws -> [(text: String, kind: String, scope: String)] {
        let fact = DynamicGenerationSchema(name: "Fact", properties: [
            .init(name: "text", description: "One short self-contained sentence", schema: SchemaBuilder.string),
            .init(name: "kind", description: "Category", schema: SchemaBuilder.choice("Kind", ["preference", "project", "decision", "reference", "other"])),
            .init(name: "scope", description: "user = about the person in general; project = specific to this codebase", schema: SchemaBuilder.choice("Scope", ["project", "user"])),
        ])
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Facts", properties: [
            .init(name: "facts", description: "Zero to four facts", schema: DynamicGenerationSchema(arrayOf: fact, minimumElements: 0, maximumElements: 4)),
        ]), dependencies: [])
        let session: LanguageModelSession
        if let model { session = try await Backends.makeSession(model, tools: [], instructions: instructions) }
        else { session = LanguageModelSession(model: .default, instructions: instructions) }
        let input = "User: \(prompt.prefix(1500))\n\nAgent: \(response.prefix(1500))\n\nTools used: \(toolSummary.prefix(400))"
        let r = try await session.respond(to: input, schema: schema, options: GenerationOptions(maximumResponseTokens: 300))
        let items = try r.content.value([GeneratedContent].self, forProperty: "facts")
        return items.compactMap { item in
            guard let t = try? item.value(String.self, forProperty: "text") else { return nil }
            return (t, (try? item.value(String.self, forProperty: "kind")) ?? "other", (try? item.value(String.self, forProperty: "scope")) ?? "project")
        }
    }
}


/// Merges a cluster of overlapping facts into one sentence with the on-device model.
public enum MemoryConsolidator {
    /// duplicate: same information; conflict: different values for the same thing; complementary:
    /// different details about the same subject; different: about different things entirely.
    public static func relation(_ texts: [String]) async throws -> String {
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Relation", properties: [
            .init(name: "relation", description: "How the facts relate", schema: SchemaBuilder.choice("Rel", ["duplicate", "conflict", "complementary", "different"])),
        ]), dependencies: [])
        let session = LanguageModelSession(model: .default, instructions: """
        You compare two remembered facts. First decide whether they are about the SAME thing (the \
        same command, setting, name, file, or rule). If they are about different things, answer \
        different. If about the same thing: duplicate when they state the same value in other \
        words; conflict when they state different values; complementary when they add details \
        that do not contradict.
        Examples:
        "The test command is make test." / "The lint command is make lint." → different (test vs lint are different commands)
        "The test command is make test." / "The test command is now swift test." → conflict (same command, different value)
        "The lint command is make lint." / "Code validation runs with make lint." → duplicate
        "The main branch is trunk." / "Releases are tagged from trunk." → complementary
        """)
        let input = texts.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let r = try await session.respond(to: input, schema: schema, options: GenerationOptions(maximumResponseTokens: 20))
        return (try? r.content.value(String.self, forProperty: "relation")) ?? "complementary"
    }

    static let instructions = """
    You merge several remembered facts about the same subject into ONE short, self-contained     sentence. The facts are ordered newest first. Where they conflict, the newest fact is     correct and older ones are outdated. Keep exact names, paths, commands, and values. Do not     add anything that is not in the facts.
    """
    public static func merge(_ texts: [String]) async throws -> String? {
        let schema = try SchemaBuilder.object("Merged", [("text", "The single merged fact", SchemaBuilder.string)])
        let session = LanguageModelSession(model: .default, instructions: instructions)
        let input = texts.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let r = try await session.respond(to: input, schema: schema, options: GenerationOptions(maximumResponseTokens: 120))
        let t = (try? r.content.value(String.self, forProperty: "text"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.count >= 8 ? t : nil
    }
}
