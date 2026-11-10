// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Darwin
import FileProviderShell
import os
import Synchronization

/// How much memory this extension uses. iOS stops it at about 20 MB, and nobody could see how close
/// it gets without this. It's measured in Release builds too, because Debug ones differ in what
/// they use. The report holds numbers only, and a new highest goes to the diagnostics log.
enum Footprint {
    private static let drives = Mutex(0)

    /// A drive's extension started in this process.
    static func driveStarted() {
        drives.withLock { $0 += 1 }
    }

    /// A drive's extension was told it's no longer needed.
    static func driveStopped() {
        drives.withLock { $0 = max(0, $0 - 1) }
    }

    static func note(_ event: String) {
        guard let (now, peak) = current(), let saved = DriveStore.phoneShared() else { return }
        let available = UInt64(os_proc_available_memory())
        let (report, isNewHighest) = MemoryReport.record(
            event: event, now: now, peak: peak, available: available, threads: threadCount(),
            drives: drives.withLock { $0 }, at: saved.memoryReportURL)
        Trace.log("memory \(event): \(MemoryReport.megabytes(now)), peak \(MemoryReport.megabytes(peak))")
        if isNewHighest {
            saved.diagnostics.record(report.summary)
        }
    }

    /// What iOS counts against the limit, now and at most so far in this run.
    private static func current() -> (now: UInt64, peak: UInt64)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (info.phys_footprint, UInt64(max(info.ledger_phys_footprint_peak, 0)))
    }

    private static func threadCount() -> Int? {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return nil }
        let size = vm_size_t(MemoryLayout<thread_t>.stride * Int(count))
        for index in 0..<Int(count) {
            mach_port_deallocate(mach_task_self_, threads[index])
        }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), size)
        return Int(count)
    }
}
