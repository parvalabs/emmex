import Foundation
import Security

/// Reads this process's own code-signing entitlements.
public enum Entitlements {
    public static func value(_ key: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        var err: Unmanaged<CFError>?
        guard let v = SecTaskCopyValueForEntitlement(task, key as CFString, &err) else { return false }
        return (v as? Bool) ?? false
    }
    public static var hasPrivateCloudCompute: Bool { value("com.apple.developer.private-cloud-compute") }
}
