import Foundation
import FoundationModels

/// One reasoning/effort dial for every backend, applied per request.
/// - Claude: light/moderate/deep map to low/medium/high effort; `off` sends no effort field.
/// - MLX (Qwen3-style): any level turns thinking on; `off` disables it via the bridge's `no_think`.
/// - Apple models: passed through as the framework's reasoning level.
public enum Effort: String, CaseIterable, Sendable, Codable {
    case off, low, medium, high

    public static let `default`: Effort = .off

    public func contextOptions(for spec: ModelSpec) -> ContextOptions {
        switch (self, spec) {
        case (.off, .mlx): ContextOptions(reasoningLevel: .custom("no_think"))
        case (_, .auto): ContextOptions()
        case (.off, .provider): ContextOptions()
        case (.off, _): ContextOptions()
        case (.low, _): ContextOptions(reasoningLevel: .light)
        case (.medium, _): ContextOptions(reasoningLevel: .moderate)
        case (.high, _): ContextOptions(reasoningLevel: .deep)
        }
    }
}
