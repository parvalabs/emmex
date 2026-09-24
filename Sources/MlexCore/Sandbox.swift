import Foundation

/// Seatbelt (sandbox-exec) profiles for shell commands. Default-allow with explicit denies:
/// writes only inside the workspace, temp, device files, and known tool caches; no reads of
/// credential directories; network only when the policy says so. The profile is generated per
/// command, so a run that was allowed network gets it and a plain build does not.
public struct Sandbox: Sendable {
    public var workspace: URL
    public var cwd: URL
    public var network: Bool
    public var extraWritable: [String] = []

    public init(workspace: URL, cwd: URL, network: Bool, extraWritable: [String] = []) {
        self.workspace = workspace; self.cwd = cwd; self.network = network; self.extraWritable = extraWritable
    }

    public static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") }

    static let home = NSHomeDirectory()

    /// Where tools may write besides the workspace: temp, devices, and package-manager caches.
    static var toolCaches: [String] {
        ["/private/tmp", "/private/var/folders", "/dev", NSTemporaryDirectory(),
         "\(home)/Library/Caches", "\(home)/Library/Logs", "\(home)/.cache", "\(home)/.npm", "\(home)/.yarn", "\(home)/.pnpm-store",
         "\(home)/.cargo/registry", "\(home)/.cargo/git", "\(home)/.local/share/mise", "\(home)/.swiftpm", "\(home)/.gradle", "\(home)/.m2",
         "\(home)/Library/Developer/Xcode/DerivedData", "\(home)/Library/org.swift.swiftpm", "\(home)/.bun/install/cache", "\(home)/.local/pipx"]
    }

    /// Never readable by a sandboxed command, whatever the policy said.
    static var secrets: [String] {
        ["\(home)/.ssh", "\(home)/.aws", "\(home)/.gnupg", "\(home)/.config/gh", "\(home)/Library/Keychains", "\(home)/.netrc",
         "\(home)/.zsh_history", "\(home)/.bash_history", "\(home)/.docker/config.json", "\(home)/.kube"]
    }

    /// Never writable even inside the workspace: hooks and agent config could run code later.
    var protectedInWorkspace: [String] {
        [workspace.appending(path: ".git/hooks").path, workspace.appending(path: ".mlex").path, cwd.appending(path: ".git/hooks").path]
    }

    func quote(_ p: String) -> String { "\"" + p.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    public var profile: String {
        let writable = ([workspace.path, cwd.path] + Self.toolCaches + extraWritable).map { "(subpath \(quote($0)))" }.joined(separator: " ")
        let noWrite = protectedInWorkspace.map { "(subpath \(quote($0)))" }.joined(separator: " ")
        let noRead = Self.secrets.map { FileManager.default.fileExists(atPath: $0) && !$0.hasSuffix("json") && !$0.hasSuffix("history") && !$0.hasSuffix(".netrc") ? "(subpath \(quote($0)))" : "(literal \(quote($0)))" }.joined(separator: " ")
        return """
        (version 1)
        (allow default)
        (deny file-write*)
        (allow file-write* \(writable))
        (deny file-write* \(noWrite))
        (deny file-read* \(noRead))
        \(network ? "(allow network*)" : "(deny network*)")
        """
    }

    /// Wrap a command so it runs under the profile. SwiftPM applies its own sandbox to manifest
    /// and plugin evaluation, which macOS refuses inside another sandbox, so swift build/test/run/
    /// package get --disable-sandbox (ours already confines them).
    public func arguments(for command: String) -> (executable: String, arguments: [String]) {
        ("/usr/bin/sandbox-exec", ["-p", profile, "/bin/zsh", "-lc", Self.rewrite(command)])
    }

    static func rewrite(_ command: String) -> String {
        PolicyEngine.split(command).map { part -> String in
            let words = PolicyEngine.stripWrappers(part.split(separator: " ").map(String.init))
            if words.count >= 2, PolicyEngine.basename(words[0]) == "swift", ["build", "test", "run", "package"].contains(words[1]), !part.contains("--disable-sandbox") {
                return part.replacingOccurrences(of: "swift \(words[1])", with: "swift \(words[1]) --disable-sandbox")
            }
            return part
        }.joined(separator: " && ")
    }
}
