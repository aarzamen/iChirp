import Darwin
import Foundation
import os

/// Process memory readings for About (device diagnostics) and the DEBUG smoke run.
enum MemoryProbe {
    /// The app's physical footprint (`task_vm_info.phys_footprint`, the number the system's memory limit counts),
    /// or nil when the kernel call fails.
    static func physicalFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    /// How much more memory the app may use before iOS terminates it (`os_proc_available_memory`), or nil where the
    /// system does not report it (the simulator reports 0).
    static func availableBytes() -> UInt64? {
        let available = os_proc_available_memory()
        return available > 0 ? UInt64(available) : nil
    }

    /// Whole megabytes (1 MB = 1,048,576 bytes, as Xcode's memory gauge shows).
    static func megabytes(_ bytes: UInt64) -> Int {
        Int(bytes / 1_048_576)
    }

    /// Samples the footprint every `interval` until cancelled and returns the peak in bytes.
    static func samplePeakFootprint(every interval: Duration = .milliseconds(250)) -> Task<UInt64, Never> {
        Task.detached(priority: .utility) {
            var peak = physicalFootprintBytes() ?? 0
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                peak = max(peak, physicalFootprintBytes() ?? 0)
            }
            return max(peak, physicalFootprintBytes() ?? 0)
        }
    }
}
