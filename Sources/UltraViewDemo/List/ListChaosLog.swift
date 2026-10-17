#if canImport(UIKit)
import Foundation
import Darwin
import os

/// JSON lines and an atomically rewritten summary under Documents.
final class ListChaosLogFile: @unchecked Sendable {
    // @unchecked Sendable: `handle` is created before the first write and
    // then touched only on `queue`.
    private let queue = DispatchQueue(label: "dev.ultraview.listchaos.log", qos: .utility)
    private let handle: FileHandle?
    let logURL: URL
    let summaryURL: URL

    init(seed: UInt64) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logURL = directory.appendingPathComponent("list-chaos-\(seed).jsonl")
        summaryURL = directory.appendingPathComponent("list-chaos-\(seed)-summary.json")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: logURL)
    }

    static func encode(_ record: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(record),
              var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return nil }
        data.append(0x0A)
        return data
    }

    /// `durable` writes before returning, so the line survives a trap later in the same turn.
    func append(_ record: [String: Any], durable: Bool = false) {
        guard let data = Self.encode(record) else { return }
        if durable { queue.sync { try? handle?.write(contentsOf: data) } }
        else { queue.async { [self] in try? handle?.write(contentsOf: data) } }
    }

    func writeSummary(_ record: [String: Any], synchronous: Bool) {
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = summaryURL
        let write: @Sendable () -> Void = { [self] in
            try? data.write(to: url, options: .atomic)
            try? handle?.synchronize()
        }
        if synchronous { queue.sync(execute: write) } else { queue.async(execute: write) }
    }
}

/// Process memory through public Mach and libSystem calls.
enum ListChaosMemory {
    struct Sample {
        var footprint: UInt64
        var ledgerPeak: Int64
        var available: UInt64
    }

    static func sample() -> Sample? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Sample(footprint: info.phys_footprint, ledgerPeak: info.ledger_phys_footprint_peak, available: UInt64(os_proc_available_memory()))
    }
}

/// SplitMix64: one seed gives one decision stream for the same sequence of states.
struct ListChaosRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
    mutating func double(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + Double(next() >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }
    mutating func bool(_ probability: Double = 0.5) -> Bool { double(0...1) < probability }
    mutating func pick<T>(_ values: [T]) -> T { values[int(0...(values.count - 1))] }
}
#endif
