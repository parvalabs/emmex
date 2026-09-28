import Foundation

public enum Secrets {
    /// Anthropic key from the environment, else the macOS Keychain (service `emmex-anthropic`).
    public static func anthropicKey() -> String? {
        if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty { return k }
        return keychain(service: "emmex-anthropic")
    }

    /// API key for a configured provider: env var first, then Keychain.
    public static func providerKey(_ p: Settings.Provider) -> String? {
        if let e = p.env, let v = ProcessInfo.processInfo.environment[e], !v.isEmpty { return v }
        if let k = p.keychain, let v = keychain(service: k) { return v }
        return nil
    }

    /// Keychain lookup; an `emmex-*` service falls back to its pre-rename `emlex-*` and `mlex-*` items.
    static func keychain(service: String) -> String? {
        if let v = keychainItem(service) { return v }
        guard service.hasPrefix("emmex-") else { return nil }
        let rest = service.dropFirst("emmex-".count)
        return Paths.legacyNames.lazy.compactMap { keychainItem("\($0)-\(rest)") }.first
    }

    static func keychainItem(_ service: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
