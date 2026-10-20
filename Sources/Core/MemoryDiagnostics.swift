import Foundation
import Darwin
import os

/// Low-frequency, metadata-only measurements. Footprint includes compressed memory;
/// RSS alone cannot distinguish a leak from allocator or rendering caches.
enum MemoryDiagnostics {
    private static let logger = Logger(subsystem: Log.subsystem, category: "memory")

    private static let lock = NSLock()
    private static var metrics: [UUID: [String: Int]] = [:]
    private static var operations: [UUID: (String, TimeInterval)] = [:]

    /// Explicit finish in defer measures executing work, not retained Task handles.
    static func begin(_ kind: String) -> UUID {
        let id = UUID()
        lock.lock()
        operations[id] = (kind, ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        return id
    }

    static func end(_ id: UUID) {
        lock.lock()
        operations.removeValue(forKey: id)
        metrics.removeValue(forKey: id)
        lock.unlock()
    }

    static func update(_ id: UUID, values: [String: Int]) {
        lock.lock()
        if operations[id] != nil { metrics[id] = values }
        lock.unlock()
    }

    static var activitySummary: String {
        lock.lock()
        let snapshot = Array(operations.values)
        var totals: [String: Int] = [:]
        for values in metrics.values {
            for (key, value) in values { totals[key, default: 0] += value }
        }
        lock.unlock()
        let now = ProcessInfo.processInfo.systemUptime
        let groups = Dictionary(grouping: snapshot, by: { $0.0 })
        let activities = groups.keys.sorted().map { kind in
            let items = groups[kind]!
            let age = Int(max(0, now - (items.map { $0.1 }.min() ?? now)))
            return "\(kind):\(items.count)/oldestSeconds:\(age)"
        }.joined(separator: ",")
        return activities + " metrics=" + totals.keys.sorted().map { "\($0):\(totals[$0]!)" }.joined(separator: ",")
    }

    static func sample(_ event: String, details: String) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            logger.notice("[MEM-DIAG] event=\(event, privacy: .public) measurementError=\(result)")
            return
        }
        let mib = 1_048_576.0
        let measurements = String(format: "pid=%d uptimeSeconds=%.0f rssMiB=%.2f footprintMiB=%.2f compressedMiB=%.2f peakRSSMiB=%.2f", ProcessInfo.processInfo.processIdentifier, ProcessInfo.processInfo.systemUptime, Double(info.resident_size) / mib, Double(info.phys_footprint) / mib, Double(info.compressed) / mib, Double(info.resident_size_peak) / mib)
        logger.notice("[MEM-DIAG] event=\(event, privacy: .public) \(measurements, privacy: .public) \(details, privacy: .public) activities=\(activitySummary, privacy: .public)")
    }
}
