import Foundation
import Darwin

/// Unified-memory accounting for load decisions and UI.
public enum SystemMemory {
    public static var total: Int64 { Int64(ProcessInfo.processInfo.physicalMemory) }

    /// Bytes the system could hand out without swapping: free + inactive + speculative pages.
    public static func available() -> Int64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = Int64(sysconf(_SC_PAGESIZE))
        return (Int64(stats.free_count) + Int64(stats.inactive_count) + Int64(stats.speculative_count)) * page
    }

    /// This process's physical footprint (what Activity Monitor shows as Memory).
    public static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    public static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}
