import Foundation
import ClaudeForFoundationModels

/// Claude models emmex knows by short name. The picker shows `shown`; any other model can be
/// added to it with `claudeModels` in settings, by short name or by full API id.
public enum ClaudeCatalog {
    public struct Entry: Sendable {
        public var name: String          // what follows `claude:` in a spec
        public var label: String
        public var model: ClaudeModel
    }

    static let haiku = ClaudeModel(id: "claude-haiku-4-5-20251001", capabilities: .init(effortLevels: [], structuredOutput: true))
    /// Released 2026-09-28, after ClaudeForFoundationModels 0.2.1; capabilities as documented
    /// (adaptive thinking, effort) and mirroring the package's Sonnet 5.
    static let sonnet5_5 = ClaudeModel(id: "claude-sonnet-5-5", capabilities: .init(
        effortLevels: [.low, .medium, .high, .xhigh, .max], adaptiveThinking: true, structuredOutput: true, imageInput: true))

    public static let entries: [Entry] = [
        .init(name: "fable5_1", label: "Fable 5.1", model: .fable5_1),
        .init(name: "opus5_5", label: "Opus 5.5", model: .opus5_5),
        .init(name: "sonnet5_5", label: "Sonnet 5.5", model: sonnet5_5),
        .init(name: "sonnet5", label: "Sonnet 5", model: .sonnet5),
        .init(name: "haiku", label: "Haiku 4.5, the cheap tier", model: haiku),
        .init(name: "fable5", label: "Fable 5", model: .fable5),
        .init(name: "opus5", label: "Opus 5", model: .opus5),
        .init(name: "opus4_8", label: "Opus 4.8", model: .opus4_8),
        .init(name: "opus4_7", label: "Opus 4.7", model: .opus4_7),
        .init(name: "opus4_6", label: "Opus 4.6", model: .opus4_6),
        .init(name: "sonnet4_6", label: "Sonnet 4.6", model: .sonnet4_6),
    ]

    /// Shown in the picker without any setting.
    public static let shown = ["opus5_5", "sonnet5_5", "haiku"]

    /// Other spellings people use for the same models.
    static let aliases: [String: String] = [
        "sonnet": "sonnet5_5", "sonnet5.5": "sonnet5_5", "opus": "opus5_5", "fable": "fable5_1",
        "opus5.5": "opus5_5", "fable5.1": "fable5_1", "opus4.8": "opus4_8", "opus4.7": "opus4_7", "opus4.6": "opus4_6",
        "sonnet4.6": "sonnet4_6", "haiku4_5": "haiku", "haiku4.5": "haiku",
    ]

    /// The entry for a short name, an alias, or a full API id.
    public static func entry(_ name: String) -> Entry? {
        let key = aliases[name] ?? name
        return entries.first { $0.name == key || $0.model.id == name }
    }

    /// The model to call: a known entry, or any other API id with conservative capabilities.
    public static func model(_ name: String) -> ClaudeModel {
        entry(name)?.model ?? ClaudeModel(id: name, capabilities: .init(effortLevels: [.low, .high], structuredOutput: true))
    }

    /// Picker names: the defaults plus `claudeModels` from settings, without duplicates.
    public static func pickerNames(settings: Settings = .load()) -> [String] {
        var out: [String] = []
        for n in shown + (settings.claudeModels ?? []) {
            let canonical = entry(n)?.name ?? n
            if !out.contains(canonical) { out.append(canonical) }
        }
        return out
    }
}
