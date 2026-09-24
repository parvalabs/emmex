import Foundation
import FoundationModels

/// Everything a UI or CLI needs to render an agent turn as it happens.
public enum AgentEvent: Sendable {
    case textDelta(String)
    case toolCall(name: String, arguments: String)
    case toolResult(name: String, output: String)
    case finished(usage: LanguageModelSession.Usage?, text: String)
    case warning(String)
    case info(String)
    /// A side-effecting tool call is waiting for the user's decision.
    case approvalNeeded(ToolRequest)
    /// The pending request was resolved (by the user or automatically); `layer` says by what.
    case approvalResolved(id: String, allowed: Bool, layer: String)
}

/// How a host answers approval requests: the closure returns (allowed, alwaysAllowPattern?).
public typealias Approver = @Sendable (ToolRequest) async -> (Bool, String?)

public typealias EventSink = @Sendable (AgentEvent) -> Void

/// Shared context handed to tools: where they act and how they report.
public struct ToolContext: Sendable {
    public var cwd: String
    public var report: EventSink
    public var maxOutput: Int
    public var policy: PolicyEngine?
    public var approver: Approver?
    public init(cwd: String, maxOutput: Int = 4000, report: @escaping EventSink = { _ in }, policy: PolicyEngine? = nil, approver: Approver? = nil) {
        self.cwd = cwd; self.maxOutput = maxOutput; self.report = report; self.policy = policy; self.approver = approver
    }

    /// Gate a side-effecting call. Returns nil when it may proceed, else the text to hand back
    /// to the model explaining the refusal.
    func gate(_ r: ToolRequest) async -> String? {
        guard let policy else { return nil }
        var r = r
        switch await policy.decide(r) {
        case .allow(let layer):
            report(.approvalResolved(id: r.id, allowed: true, layer: layer)); return nil
        case .deny(let why):
            report(.approvalResolved(id: r.id, allowed: false, layer: why)); return "denied: \(why)"
        case .ask(let why):
            r.reason = why
            guard let approver else { report(.approvalResolved(id: r.id, allowed: false, layer: "no approver")); return "denied: needs approval (\(why)) and no one is available to approve" }
            report(.approvalNeeded(r))
            let (ok, always) = await approver(r)
            if let always { await policy.addAllowPattern(always) }
            report(.approvalResolved(id: r.id, allowed: ok, layer: ok ? "user" : "user denied"))
            return ok ? nil : "denied by the user"
        }
    }
    func clip(_ s: String) -> String {
        s.count > maxOutput ? String(s.prefix(maxOutput)) + "\n…[truncated \(s.count - maxOutput) chars]" : s
    }
}
