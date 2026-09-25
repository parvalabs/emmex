import Foundation

/// Seatbelt (sandbox-exec) profiles for shell commands: default deny, with the process, sysctl,
/// Mach, and device allowances a build toolchain needs (modeled on OpenAI Codex's base policy,
/// Apache-2.0), reads everywhere except credential stores, writes only inside the workspace and
/// the session's temp directory, and network egress only to the local filtering proxy.
public struct Sandbox: Sendable {
    public var workspace: URL
    public var cwd: URL
    public var tempDir: URL
    public var proxyPort: UInt16?          // nil: no network at all
    public var extraWritable: [String] = []

    public init(workspace: URL, cwd: URL, tempDir: URL, proxyPort: UInt16?, extraWritable: [String] = []) {
        self.workspace = workspace; self.cwd = cwd; self.tempDir = tempDir; self.proxyPort = proxyPort; self.extraWritable = extraWritable
    }

    public static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") }
    static let home = NSHomeDirectory()

    /// The per-user temp and cache directories (mode 700, not shared): swiftc, xcrun, and clang
    /// use them regardless of $TMPDIR. /tmp itself stays closed.
    static func userDir(_ name: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(name, &buf, buf.count) > 0 else { return nil }
        return String(cString: buf)
    }

    /// Package-manager and toolchain caches that must stay writable for builds to work.
    static var toolCaches: [String] {
        [userDir(_CS_DARWIN_USER_TEMP_DIR), userDir(_CS_DARWIN_USER_CACHE_DIR)].compactMap { $0 } + ["\(home)/Library/Caches", "\(home)/Library/Logs", "\(home)/.cache", "\(home)/.npm", "\(home)/.yarn", "\(home)/.pnpm-store", "\(home)/.bun/install/cache",
         "\(home)/.cargo/registry", "\(home)/.cargo/git", "\(home)/.local/share/mise", "\(home)/.local/state/mise", "\(home)/.swiftpm", "\(home)/.gradle", "\(home)/.m2",
         "\(home)/Library/Developer/Xcode/DerivedData", "\(home)/Library/org.swift.swiftpm", "\(home)/.local/pipx", "\(home)/.cache/uv"]
    }

    /// Never readable, whatever the policy decided.
    static var secretDirs: [String] { ["\(home)/.ssh", "\(home)/.aws", "\(home)/.gnupg", "\(home)/.config/gh", "\(home)/Library/Keychains", "\(home)/.kube", "\(home)/.azure", "\(home)/.config/gcloud"] }
    static var secretFiles: [String] { ["\(home)/.netrc", "\(home)/.zsh_history", "\(home)/.bash_history", "\(home)/.docker/config.json", "\(home)/.npmrc", "\(home)/.pypirc", "\(home)/.git-credentials"] }

    /// Config that the agent or its tools would execute later: never writable, even in the
    /// workspace (git hooks and config, shell startup, editor and agent directories, MCP config).
    static let protectedNames: [String] = [".git/hooks", ".git/config", ".gitconfig", ".gitmodules", ".gitattributes", ".emlex", ".mlex", ".claude", ".cursor", ".vscode", ".idea", ".husky",
                                           ".mcp.json", ".zshrc", ".zprofile", ".zshenv", ".zlogin", ".bashrc", ".bash_profile", ".profile", ".ripgreprc", ".npmrc", ".direnv", ".envrc"]

    func q(_ p: String) -> String { "\"" + p.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    func re(_ s: String) -> String { "#\"" + s + "\"" }
    static func escapeRegex(_ s: String) -> String { s.replacingOccurrences(of: ".", with: "\\.").replacingOccurrences(of: "/", with: "\\/") }

    public var profile: String {
        // Seatbelt matches real paths: /tmp and /var are symlinks into /private, so resolve everything.
        let c = PolicyEngine.canonical
        let roots = Array(Set([c(workspace.path), c(cwd.path)]))
        let writable = (roots + [c(tempDir.path)] + Self.toolCaches.map(c) + extraWritable.map(c)).map { "(subpath \(q($0)))" }.joined(separator: "\n  ")
        // Protected config in every root, as literal subpaths and as **/name regexes (nested packages).
        let protectedLiteral = roots.flatMap { r in Self.protectedNames.map { "(subpath \(q(r + "/" + $0)))" } }.joined(separator: "\n  ")
        let protectedRegex = Self.protectedNames.map { "(regex \(re("(^|\\/)" + Self.escapeRegex($0) + "(\\/|$)")))" }.joined(separator: "\n  ")
        // Ancestors of protected paths cannot be renamed or unlinked, so `mv .git .git2` cannot
        // dodge the deny above (Codex's guard).
        let ancestors = roots.flatMap { r in [r + "/.git", r] }.map { "(literal \(q($0)))" }.joined(separator: " ")
        let noRead = (Self.secretDirs.map { "(subpath \(q(c($0))))" } + Self.secretFiles.map { "(literal \(q(c($0))))" }).joined(separator: "\n  ")
        let network: String = proxyPort.map { p in
            """
            (allow network-outbound (remote ip "localhost:\(p)"))
            (allow mach-lookup
              (global-name "com.apple.SecurityServer") (global-name "com.apple.trustd.agent") (global-name "com.apple.ocspd")
              (global-name "com.apple.networkd") (global-name "com.apple.SystemConfiguration.configd")
              (global-name "com.apple.SystemConfiguration.DNSConfiguration") (global-name "com.apple.system.opendirectoryd.membership"))
            (allow system-socket (require-all (socket-domain AF_SYSTEM) (socket-protocol 2)))
            """
        } ?? "(deny network*)"
        return """
        ; emlex sandbox. Process/sysctl/Mach/device allowances modeled on OpenAI Codex's Seatbelt base policy (Apache-2.0).
        (version 1)
        (deny default)
        (allow process-exec)
        (allow process-fork)
        (allow signal (target same-sandbox))
        (allow process-info* (target same-sandbox))
        (allow sysctl-read
          (sysctl-name "hw.activecpu") (sysctl-name "hw.busfrequency_compat") (sysctl-name "hw.byteorder") (sysctl-name "hw.cacheconfig")
          (sysctl-name "hw.cachelinesize_compat") (sysctl-name "hw.cpufamily") (sysctl-name "hw.cpufrequency_compat") (sysctl-name "hw.cputype")
          (sysctl-name "hw.l1dcachesize_compat") (sysctl-name "hw.l1icachesize_compat") (sysctl-name "hw.l2cachesize_compat") (sysctl-name "hw.l3cachesize_compat")
          (sysctl-name "hw.logicalcpu_max") (sysctl-name "hw.machine") (sysctl-name "hw.model") (sysctl-name "hw.memsize") (sysctl-name "hw.ncpu")
          (sysctl-name "hw.nperflevels") (sysctl-name-prefix "hw.optional.") (sysctl-name "hw.packages") (sysctl-name "hw.pagesize_compat") (sysctl-name "hw.pagesize")
          (sysctl-name "hw.physicalcpu") (sysctl-name "hw.physicalcpu_max") (sysctl-name "hw.logicalcpu") (sysctl-name "hw.cpufrequency") (sysctl-name "hw.tbfrequency_compat")
          (sysctl-name "hw.vectorunit") (sysctl-name "machdep.cpu.brand_string") (sysctl-name "kern.argmax") (sysctl-name "kern.hostname") (sysctl-name "kern.maxfilesperproc")
          (sysctl-name "kern.maxproc") (sysctl-name "kern.osproductversion") (sysctl-name "kern.osrelease") (sysctl-name "kern.ostype") (sysctl-name "kern.osvariant_status")
          (sysctl-name "kern.osversion") (sysctl-name "kern.secure_kernel") (sysctl-name "kern.sysv.semmns") (sysctl-name "kern.usrstack64") (sysctl-name "kern.version")
          (sysctl-name "sysctl.proc_cputype") (sysctl-name "vm.loadavg") (sysctl-name-prefix "hw.perflevel") (sysctl-name-prefix "kern.proc.pgrp.") (sysctl-name-prefix "kern.proc.pid.")
          (sysctl-name-prefix "net.routetable.") (sysctl-name "kern.boottime") (sysctl-name "kern.ngroups") (sysctl-name "kern.hv_vmm_present"))
        (allow sysctl-write (sysctl-name "kern.grade_cputype"))
        (allow iokit-open (iokit-registry-entry-class "RootDomainUserClient"))
        (allow mach-lookup (global-name "com.apple.system.opendirectoryd.libinfo") (global-name "com.apple.PowerManagement.control")
                           (global-name "com.apple.bsd.dirhelper") (global-name "com.apple.system.logger") (global-name "com.apple.system.notification_center")
                           (global-name "com.apple.FSEvents") (global-name "com.apple.CoreServices.coreservicesd") (global-name "com.apple.coreservices.launchservicesd")
                           (global-name "com.apple.distributed_notifications@Uv3") (global-name "com.apple.lsd.mapdb") (global-name "com.apple.cfprefsd.daemon") (global-name "com.apple.cfprefsd.agent"))
        (allow ipc-posix-sem)
        (allow ipc-posix-shm)
        (allow pseudo-tty)
        (allow file-ioctl (literal "/dev/null") (literal "/dev/zero") (literal "/dev/random") (literal "/dev/urandom") (literal "/dev/tty") (literal "/dev/dtracehelper") (literal "/dev/ptmx") (regex #"^/dev/ttys[0-9]+"))
        (allow file-read* file-write* (literal "/dev/null") (literal "/dev/zero") (literal "/dev/random") (literal "/dev/urandom") (literal "/dev/tty") (literal "/dev/dtracehelper") (literal "/dev/ptmx") (regex #"^/dev/ttys[0-9]+") (regex #"^/dev/fd/"))
        (allow file-read* file-test-existence file-map-executable)
        (deny file-read*
          \(noRead))
        (allow file-write*
          \(writable))
        (deny file-write*
          \(protectedLiteral)
          \(protectedRegex))
        (deny file-write-unlink (require-all (vnode-type DIRECTORY) (require-any \(ancestors))))
        (deny system-fcntl (fcntl-command 80 110))
        (deny network*)
        \(network)
        """
    }

    /// Wrap a command so it runs under the profile with the proxy and temp environment.
    public func arguments(for command: String, proxyURL: String?) -> (executable: String, arguments: [String], environment: [String: String]) {
        var env = ProcessInfo.processInfo.environment
        env["TMPDIR"] = tempDir.path
        env["EMLEX_SANDBOX"] = "seatbelt"
        if let proxyURL {
            for k in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] { env[k] = proxyURL }
            env["NO_PROXY"] = ""; env["no_proxy"] = ""
            env["GIT_CONFIG_PARAMETERS"] = "'http.proxyAuthMethod=basic' 'credential.helper='"   // keychain is unreadable in the sandbox
        } else {
            for k in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] { env[k] = nil }
        }
        if Env.value("EMLEX_SANDBOX_DEBUG") != nil { FileHandle.standardError.write(Data((profile + "\n").utf8)) }
        return ("/usr/bin/sandbox-exec", ["-p", profile, "/bin/zsh", "-lc", Self.rewrite(command)], env)
    }

    /// SwiftPM applies its own sandbox to manifest and plugin evaluation, which macOS refuses
    /// inside another sandbox; ours already confines it.
    static func rewrite(_ command: String) -> String {
        guard !command.contains("--disable-sandbox") else { return command }
        // In place, so pipes, redirects, and separators are untouched.
        return command.replacingOccurrences(of: #"(^|[\s;&|(])((?:\S*/)?swift)\s+(build|test|run|package)\b"#, with: "$1$2 $3 --disable-sandbox", options: .regularExpression)
    }
}

/// Process-wide sandbox services: the filtering proxy and a per-session temp directory.
public actor SandboxRuntime {
    public static let shared = SandboxRuntime()
    private var proxy: NetworkProxy?
    private var tempDirs: [String: URL] = [:]

    public func proxyInstance() async -> NetworkProxy? {
        if let proxy { return proxy }
        do { let p = try NetworkProxy(); try await p.start(); proxy = p; return p } catch { return nil }
    }

    /// One temp directory per session, created on first use, the only writable temp inside the sandbox.
    public func tempDir(session: String) -> URL {
        if let d = tempDirs[session] { return d }
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "emlex-\(session.prefix(8))")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs[session] = d
        return d
    }

    public func cleanup(session: String) {
        if let d = tempDirs.removeValue(forKey: session) { try? FileManager.default.removeItem(at: d) }
    }
}
