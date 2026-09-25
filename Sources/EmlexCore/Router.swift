import Foundation
import FoundationModels

public enum Tier: String, Codable, Sendable, CaseIterable { case local, cheap, frontier }

public struct RouteRequest: Sendable {
    public var prompt: String
    public var recent: String          // compact summary of the last few turns
    public var tools: [String]
    public init(prompt: String, recent: String, tools: [String]) { self.prompt = prompt; self.recent = recent; self.tools = tools }
}

public struct RouteDecision: Sendable {
    public var tier: Tier
    public var reason: String
    public var confidence: Double      // 0…1
    public var router: String
}

public protocol Router: Sendable {
    func route(_ req: RouteRequest) async throws -> RouteDecision
}

/// The tier definitions shared by every router, so decisions mean the same thing everywhere.
public enum TierGuide {
    public static let local = "conversation, greetings, simple questions answerable directly or with one file read or one shell command (file dates, row counts, git status)"
    public static let cheap = "routine multi-step but well-defined work: run tests, rebase/commit, rename or move things, small localized edits, summarize a file"
    public static let frontier = "anything needing real reasoning or judgment: debugging, design decisions, multi-file refactors, ambiguous or high-stakes requests, writing substantial new code"
}

/// Deterministic floors applied after any router: a small classifier under-escalates judgment
/// work (a concurrency fix went to the cheap tier at 90% confidence), so signals that reliably
/// mean reasoning or multi-step editing raise the minimum tier. Floors only raise, never lower.
public enum RoutingFloor {
    static let frontierCues = ["race", "concurren", "deadlock", "thread", "debug", "root cause", "why does", "why is", "crash", "intermittent", "flaky",
                               "design", "architect", "migrat", "security", "vulnerab", "performance", "optimi", "tradeoff", "trade-off",
                               "without introducing", "without breaking", "make sure nothing", "edge case", "backward", "correctness", "invariant"]
    static let editCues = ["fix", "change", "replace", "add", "remove", "implement", "update", "rewrite", "rename", "move", "create", "write", "edit", "delete", "refactor"]
    static let codeCues = [".swift", ".js", ".ts", ".py", ".css", ".html", ".json", ".md", "sources/", "src/", "function", "func ", "class ", "struct "]

    public static func minimumTier(for prompt: String) -> (Tier, String)? {
        let l = prompt.lowercased()
        if let cue = frontierCues.first(where: { l.contains($0) }) { return (.frontier, "judgment cue: \(cue)") }
        let sentences = l.split(whereSeparator: { ".!?\n".contains($0) }).filter { $0.trimmingCharacters(in: .whitespaces).count > 3 }
        let editVerbs = editCues.filter { c in sentences.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix(c) || $0.contains(" " + c + " ") } }.count
        let touchesCode = codeCues.contains { l.contains($0) }
        let multiStep = l.contains(" then ") || l.contains(" also ") || l.contains(" and run") || l.contains(" and then") || l.contains("; ") || sentences.count >= 3
        if editVerbs >= 1 && multiStep { return (.cheap, "multi-step change") }
        if touchesCode && editVerbs >= 1 { return (.cheap, "code change") }
        // Questions about identifiers in the codebase need the source read, not a guess.
        if prompt.range(of: #"\b[A-Z][a-z]+[A-Z][A-Za-z]+\b"#, options: .regularExpression) != nil || ["what does", "how does", "where is", "explain"].contains(where: { l.contains($0) }) && (touchesCode || l.contains(" type") || l.contains(" class") || l.contains(" function") || l.contains(" module")) {
            return (.cheap, "question about code")
        }
        if prompt.count > 600 { return (.cheap, "long request") }
        return nil
    }

    static let order: [Tier] = [.local, .cheap, .frontier]

    static let affirmations: Set<String> = ["yes", "y", "yep", "yeah", "yes please", "ok", "okay", "sure", "go", "go ahead", "do it", "proceed",
                                            "continue", "go on", "please", "please do", "sounds good", "fine", "correct", "right", "that's right", "affirmative", "do that", "do so"]
    static let backReferences = ["previous question", "your question", "you asked", "as i said", "answering yes", "last message", "what you proposed", "what you suggested"]

    /// A bare "yes" answers whatever the assistant just offered, so it needs at least the tier
    /// that offer implied: never below the previous turn's tier, and never local (an offer to
    /// do work means tools). Returns nil for prompts that stand on their own.
    public static func continuation(prompt: String, previous: Tier?) -> (Tier, String)? {
        let l = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: .punctuationCharacters)
        let words = l.split(whereSeparator: { $0 == " " || $0 == "," }).map { $0.trimmingCharacters(in: .punctuationCharacters) }
        let affirmative = affirmations.contains(l) || (words.count <= 6 && words.first.map { affirmations.contains($0) } == true)
        let refersBack = words.count <= 20 && backReferences.contains { l.contains($0) }
        guard affirmative || refersBack else { return nil }
        let floor = order[max(order.firstIndex(of: previous ?? .cheap)!, 1)]
        return (floor, affirmative ? "continues the previous turn" : "refers back to the previous turn")
    }

    public static func apply(_ d: RouteDecision, prompt: String) -> RouteDecision {
        guard let (min, why) = minimumTier(for: prompt), order.firstIndex(of: min)! > order.firstIndex(of: d.tier)! else { return d }
        var e = d; e.tier = min; e.reason = "escalated (\(why)); router said \(d.tier.rawValue): \(d.reason)"; e.confidence = max(d.confidence, 0.8)
        return e
    }
}

/// Apple's on-device model as the classifier: guided generation with an enum, so the output is
/// always one of the tiers. About one to two seconds per decision, offline.
public struct OnDeviceRouter: Router {
    /// false returns the model's own decision, without the deterministic floor (for evals).
    public var applyFloor: Bool
    public init(applyFloor: Bool = true) { self.applyFloor = applyFloor }

    public func route(_ req: RouteRequest) async throws -> RouteDecision {
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Route", properties: [
            .init(name: "tier", description: "Which tier should handle this request", schema: SchemaBuilder.choice("Tier", Tier.allCases.map(\.rawValue))),
            .init(name: "confidence", description: "How sure you are", schema: SchemaBuilder.choice("Confidence", ["low", "medium", "high"])),
            .init(name: "reason", description: "One short clause", schema: SchemaBuilder.string),
        ]), dependencies: [])
        let session = LanguageModelSession(model: .default, instructions: """
        You route requests to an AI coding agent to the cheapest capable tier.
        local: \(TierGuide.local).
        cheap: \(TierGuide.cheap).
        frontier: \(TierGuide.frontier).
        Prefer the cheaper tier when unsure between two. Ignore the wording's length; judge the work required.
        A short reply such as "yes" answers the assistant's last question in the recent context: route by the work that answer sets in motion.
        """)
        let prompt = "Recent context: \(req.recent.isEmpty ? "(none)" : req.recent)\n\nRequest: \(req.prompt)"
        let r = try await session.respond(to: prompt, schema: schema, options: GenerationOptions(maximumResponseTokens: 80))
        let tierRaw = (try? r.content.value(String.self, forProperty: "tier")) ?? "frontier"
        let conf = (try? r.content.value(String.self, forProperty: "confidence")) ?? "low"
        let reason = (try? r.content.value(String.self, forProperty: "reason")) ?? ""
        var tier = Tier(rawValue: tierRaw) ?? .frontier
        let confidence: Double = ["low": 0.4, "medium": 0.7, "high": 0.9][conf] ?? 0.4
        // A small model's low-confidence "local" is the dangerous case; escalate one step.
        if confidence < 0.5, tier == .local { tier = .cheap }
        let decision = RouteDecision(tier: tier, reason: reason, confidence: confidence, router: "ondevice")
        return applyFloor ? RoutingFloor.apply(decision, prompt: req.prompt) : decision
    }
}

/// TypeSafe Jev: a decision-only model returning calibrated probabilities (experimental; the
/// request shape follows TypeSafe's published examples and may need adjusting).
public struct JevRouter: Router {
    let key: String
    public init?() {
        guard let k = ProcessInfo.processInfo.environment["JEV_API_KEY"] ?? Secrets.keychain(service: "emlex-jev"), !k.isEmpty else { return nil }
        key = k
    }

    public func route(_ req: RouteRequest) async throws -> RouteDecision {
        var r = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "state": "Recent context: \(req.recent)\n\nRequest: \(req.prompt)",
            "questions": ["tier": [
                "type": "choice",
                "instructions": "Which tier should handle this request to an AI coding agent? Prefer the cheapest capable tier.",
                "criteria": ["local": TierGuide.local, "cheap": TierGuide.cheap, "frontier": TierGuide.frontier],
            ]],
        ]
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw EmlexError.modelUnavailable("jev HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let answers = (obj["answers"] as? [String: Any]) ?? (obj["results"] as? [String: Any]) ?? obj
        guard let t = answers["tier"] as? [String: Any], let choice = t["choice"] as? String, let tier = Tier(rawValue: choice) else {
            throw EmlexError.modelUnavailable("jev: unexpected response \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        let probs = t["probabilities"] as? [String: Double] ?? [:]
        return RoutingFloor.apply(.init(tier: tier, reason: probs.map { "\($0.key) \(Int($0.value * 100))%" }.sorted().joined(separator: ", "), confidence: probs[choice] ?? 0.5, router: "jev"), prompt: req.prompt)
    }
}

/// Resolves tiers to concrete specs, falling back when a tier's backend is not usable.
public struct TierResolver: Sendable {
    public var routes: Settings.Routes
    public var available: Set<String>

    public init(routes: Settings.Routes, available: Set<String>) { self.routes = routes; self.available = available }

    public func spec(for tier: Tier) -> ModelSpec {
        let order: [String] = switch tier {
        case .local: [routes.local, routes.cheap, routes.frontier]
        case .cheap: [routes.cheap, routes.frontier, routes.local]
        case .frontier: [routes.frontier, routes.cheap, routes.local]
        }
        for s in order {
            if available.contains(s), let spec = try? ModelSpec(parsing: s) { return spec }
        }
        return .system
    }

    public static func current() async -> TierResolver {
        let settings = Settings.load()
        var avail = Set(await Backends.status().filter(\.available).map(\.spec))
        // Any Claude id is usable when a key exists; Haiku is not listed by status().
        if avail.contains("claude:sonnet5") { avail.formUnion([settings.routes.cheap, settings.routes.frontier].filter { $0.hasPrefix("claude:") }) }
        return .init(routes: settings.routes, available: avail)
    }

    public static func makeRouter() -> any Router {
        if Settings.load().router == "jev", let j = JevRouter() { return j }
        return OnDeviceRouter()
    }
}
