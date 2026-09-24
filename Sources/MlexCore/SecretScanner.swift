import Foundation
import FoundationModels

/// Finds secrets in a message before it is sent anywhere: routed, answered, remembered or saved.
/// Deterministic patterns catch structured secrets (API keys, bearer tokens, private keys,
/// credentials in URLs). The on-device model runs only when the text talks about passwords or
/// keys and no pattern matched, to catch natural-language cases ("my password is hunter2").
/// Model findings must quote the secret exactly as it appears, so a hallucination cannot block.
public enum SecretScanner {
    public struct Finding: Sendable, Equatable {
        public var kind: String          // anthropic, auth_header, password, …
        public var label: String         // "a token in an Authorization header"
        public var value: String         // the secret itself; never logged or shown whole
        public var source: String        // rule | model
        /// Enough to recognize which secret it is, not enough to use it.
        public var preview: String { value.count <= 6 ? String(repeating: "•", count: value.count) : "\(value.prefix(4))… (\(value.count) chars)" }
    }

    struct Rule { let kind: String; let label: String; let regex: NSRegularExpression; let group: Int; let filtered: Bool }
    static func rule(_ kind: String, _ label: String, _ pattern: String, group: Int = 0, filtered: Bool = false) -> Rule {
        Rule(kind: kind, label: label, regex: try! NSRegularExpression(pattern: pattern), group: group, filtered: filtered)
    }

    /// Most specific first: when two rules match the same characters, the first one names it.
    static let rules: [Rule] = [
        rule("private_key", "a private key", #"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----"#),
        rule("anthropic", "an Anthropic API key", #"\bsk-ant-[A-Za-z0-9_-]{20,}"#),
        rule("github", "a GitHub token", #"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{22,})"#),
        rule("gitlab", "a GitLab token", #"\bglpat-[A-Za-z0-9_-]{20,}"#),
        rule("slack", "a Slack token", #"\bxox[abposr]-[A-Za-z0-9-]{10,}"#),
        rule("aws", "an AWS access key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        rule("google", "a Google API key", #"\bAIza[0-9A-Za-z_-]{35}"#),
        rule("huggingface", "a Hugging Face token", #"\bhf_[A-Za-z0-9]{30,}"#),
        rule("stripe", "a Stripe secret key", #"\b[sr]k_live_[0-9A-Za-z]{20,}"#),
        rule("npm", "an npm token", #"\bnpm_[A-Za-z0-9]{36}\b"#),
        rule("jwt", "a JSON Web Token", #"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#),
        rule("openai", "an OpenAI API key", #"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{32,}"#),
        rule("auth_header", "a token in an Authorization header", #"(?i)\bauthorization\b['"]?\s*[:=]\s*['"]?(?:bearer|basic|token|bot)\s+([A-Za-z0-9._~+/-]{8,}=*)"#, group: 1, filtered: true),
        rule("bearer", "a bearer token", #"(?i)\bbearer\s+([A-Za-z0-9._~+/-]{20,}=*)"#, group: 1, filtered: true),
        rule("url_credentials", "a password in a URL", #"\b[a-zA-Z][a-zA-Z0-9+.-]*://[^/\s:@]+:([^/\s@]{3,})@"#, group: 1, filtered: true),
        rule("curl_user", "a password passed with -u", #"(?:^|\s)(?:-u|--user)\s+['"]?[^\s:'"]+:([^\s'"]{3,})"#, group: 1, filtered: true),
        rule("password", "a password", #"(?i)\b(?:password|passwd|passcode|passphrase|pwd|pass)\s*[:=]\s*['"]?([^\s'"]{4,})"#, group: 1, filtered: true),
        rule("assignment", "a secret assigned to a variable", #"(?i)\b[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY|AUTH_?KEY)[A-Z0-9_]*['"]?\s*[=:]\s*['"]?([^\s'"]{8,})"#, group: 1, filtered: true),
    ]

    /// A value that names or stands in for a secret rather than being one.
    static let placeholder = try! NSRegularExpression(pattern: #"(?i)^(?:x{3,}|\*+|•+|\.{3,}|<[^>]*>?|\{[^}]*\}?|\$.*|\[redacted\].*|redacted|your[-_ ].*|example.*|placeholder|changeme|null|none|nil|undefined|true|false|required|optional|string|secret|token|password)$"#)

    /// Generic patterns (a word after `password:`) need the value to look like a credential:
    /// a digit or symbol in it, or long enough to be random, and not a function call or path.
    static func plausible(_ v: String) -> Bool {
        let range = NSRange(v.startIndex..., in: v)
        if placeholder.firstMatch(in: v, range: range) != nil { return false }
        if v.contains("(") || v.hasPrefix("/") || v.hasPrefix("~") || v.hasPrefix("process.env") || v.hasPrefix("os.environ") || v.hasPrefix("ENV[") { return false }
        let hasDigit = v.contains { $0.isNumber }
        let hasSymbol = v.contains { "!@#%^&*-_+=?~".contains($0) }
        return hasDigit || hasSymbol || v.count >= 16
    }

    /// Pattern findings only; no model, microseconds.
    public static func ruleFindings(_ text: String) -> [Finding] {
        var kept: [(NSRange, Finding)] = []
        let all = NSRange(text.startIndex..., in: text)
        for r in rules {
            for m in r.regex.matches(in: text, range: all) {
                let nr = m.range(at: r.group)
                guard nr.location != NSNotFound, let sr = Range(nr, in: text) else { continue }
                let value = String(text[sr])
                if r.filtered, !plausible(value) { continue }
                if kept.contains(where: { NSIntersectionRange($0.0, nr).length > 0 || NSIntersectionRange($0.0, m.range).length > 0 }) { continue }
                kept.append((m.range, Finding(kind: r.kind, label: r.label, value: value, source: "rule")))
            }
        }
        return kept.map(\.1)
    }

    /// Words that make a natural-language secret plausible enough to ask the model.
    static let trigger = try! NSRegularExpression(pattern: #"(?i)\b(?:pass(?:word|wd|code|phrase)?s?|pwd|pins?|codes?|log ?in(?:to)?|sign ?in|unlock|creds?|credentials?|tokens?|secrets?|keys?|api[ _-]?keys?|phrase|seed|recovery|decrypt|encrypt(?:ed|ion)?|2fa|otp|mfa|cvv|auth)\b"#)

    public static func mentionsSecrets(_ text: String) -> Bool {
        trigger.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Patterns, then the on-device model when the text mentions secrets and no pattern matched.
    public static func scan(_ text: String, useModel: Bool = true) async -> [Finding] {
        let found = ruleFindings(text)
        guard found.isEmpty, useModel, mentionsSecrets(text) else { return found }
        return await modelFindings(text)
    }

    static let instructions = """
    You check a message a user is about to send to an AI assistant for secret values that must \
    not be shared: passwords, passphrases, PINs, API keys, access tokens, private keys, session \
    cookies. Answer yes only when the message contains the secret value itself. Answer no when \
    it only talks about secrets, names a variable or environment variable (like $TOKEN or \
    API_KEY) without its value, uses a placeholder (<token>, xxx, your-key-here), or asks how \
    to handle credentials. When the answer is yes, copy the secret exactly as it appears.
    """

    /// The default guardrails refuse messages that contain passwords ("May contain unsafe
    /// content"), which is exactly what this check has to read. `MLEX_SECRETS_MODEL` picks the
    /// variant for evals: general | tagging, each with default or permissive guardrails.
    static var checkerModel: SystemLanguageModel {
        switch ProcessInfo.processInfo.environment["MLEX_SECRETS_MODEL"] ?? "general-permissive" {
        case "general-default": SystemLanguageModel(useCase: .general, guardrails: .default)
        case "tagging-default": SystemLanguageModel(useCase: .contentTagging, guardrails: .default)
        case "tagging-permissive": SystemLanguageModel(useCase: .contentTagging, guardrails: .permissiveContentTransformations)
        default: SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        }
    }

    /// A model-quoted value that is really a path, a phrase naming the kind, or text inside a
    /// command substitution (`$(security find-generic-password …)`) is not a secret.
    static func groundedSecret(_ value: String, in text: String) -> Bool {
        guard value.count >= 3, text.contains(value) else { return false }
        let v = value.lowercased()
        if ["private key", "api key", "access token", "secret key", "password", "passphrase", "pin", "token", "secret"].contains(v) { return false }
        if placeholder.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil { return false }
        if value.hasPrefix("/") || value.hasPrefix("~") || value.hasPrefix("$") { return false }
        let subst = try! NSRegularExpression(pattern: #"\$\([^)]*\)|`[^`]*`"#)
        let spans = subst.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
        var search = text.startIndex..<text.endIndex, outside = false
        while let r = text.range(of: value, range: search) {
            if !spans.contains(where: { $0.contains(r.lowerBound) }) { outside = true; break }
            search = r.upperBound..<text.endIndex
        }
        return outside
    }

    static let textInstructions = instructions + """
     Reply with exactly one line and nothing else: the word none, or the kind of secret, a \
    colon, and the secret copied from the message. Kinds: password, pin, passphrase, api key, \
    access token, private key, other.
    Example replies:
    none
    password: blue42sky
    pin: 0917
    api key: k83hd92jq
    """

    public static func modelFindings(_ text: String) async -> [Finding] {
        guard case .available = SystemLanguageModel.default.availability else { return [] }
        let debug = ProcessInfo.processInfo.environment["MLEX_DEBUG"] != nil
        do {
            // Plain-text output: permissive guardrails only cover string generation, and the
            // default guardrails refuse to read messages that contain passwords.
            let session = LanguageModelSession(model: checkerModel, instructions: textInstructions)
            let r = try await session.respond(to: "Message:\n\(text.prefix(2000))", options: GenerationOptions(temperature: 0, maximumResponseTokens: 60))
            let line = r.content.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "`"))) ?? ""
            if debug { FileHandle.standardError.write(Data("[secrets] model: \(line)\n".utf8)) }
            guard line.lowercased() != "none", let colon = line.firstIndex(of: ":") else { return [] }
            let kind = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"'`")))
            let kinds = ["password", "pin", "passphrase", "api key", "access token", "private key", "other"]
            guard kinds.contains(kind), groundedSecret(value, in: text) else { return [] }
            let label = ["password": "a password", "pin": "a PIN", "passphrase": "a passphrase", "api key": "an API key",
                         "access token": "an access token", "private key": "a private key"][kind] ?? "a secret"
            return [Finding(kind: kind.replacingOccurrences(of: " ", with: "_"), label: label, value: value, source: "model")]
        } catch {
            if debug { FileHandle.standardError.write(Data("[secrets] model error: \(error)\n".utf8)) }
            return []
        }
    }

    /// The text with every finding replaced by `[REDACTED]`.
    public static func redact(_ text: String, _ findings: [Finding]) -> String {
        var out = text
        for f in findings.sorted(by: { $0.value.count > $1.value.count }) where !f.value.isEmpty {
            out = out.replacingOccurrences(of: f.value, with: "[REDACTED]")
        }
        return out
    }

    /// One sentence for the user naming what was found.
    public static func describe(_ findings: [Finding]) -> String {
        let labels = findings.map(\.label).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return labels.count <= 1 ? labels.first ?? "a secret" : labels.dropLast().joined(separator: ", ") + " and " + labels.last!
    }
}
