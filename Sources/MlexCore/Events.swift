import Foundation
import FoundationModels

/// Everything a UI or CLI needs to render an agent turn as it happens.
public enum AgentEvent: Sendable {
    case textDelta(String)
    case toolCall(name: String, arguments: String)
    case toolResult(name: String, output: String)
    case finished(usage: LanguageModelSession.Usage?, text: String)
    case warning(String)
}

public typealias EventSink = @Sendable (AgentEvent) -> Void

/// Shared context handed to tools: where they act and how they report.
public struct ToolContext: Sendable {
    public var cwd: String
    public var report: EventSink
    public var maxOutput: Int
    public init(cwd: String, maxOutput: Int = 4000, report: @escaping EventSink = { _ in }) {
        self.cwd = cwd; self.maxOutput = maxOutput; self.report = report
    }
    func clip(_ s: String) -> String {
        s.count > maxOutput ? String(s.prefix(maxOutput)) + "\n…[truncated \(s.count - maxOutput) chars]" : s
    }
}
