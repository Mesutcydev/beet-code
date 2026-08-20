import Darwin
import Foundation


/// The single authority for model-load admission decisions.
///
/// Nothing else in the app decides whether a model may load — engines ask
/// `MemoryAdvisor` and obey. Measurement uses `phys_footprint` (not
/// `resident_size`, which double-counts Metal/GPU buffers on Apple Silicon).
///
/// Formulas adapted from the ios-local-llm project (MIT):
/// - available budget = physical RAM × (1 − osReserveFraction)  → 80% usable
/// - projected footprint = on-disk weights × workingSetOverhead + headroomReserve
/// - verdict: fits < 60% of budget, marginal < 95%, otherwise won't fit
enum MemoryAdvisor {

    struct Budget: Sendable, Equatable {
        let physicalTotal: UInt64
        let usableBudget: UInt64
        let currentFootprint: UInt64
        let projectedFootprint: UInt64
        let verdict: Verdict
    }

    enum Verdict: Sendable, Equatable {
        case fits
        case marginal
        case wontFit(String)

        var fitsLoad: Bool {
            switch self {
            case .fits, .marginal: true
            case .wontFit: false
            }
        }
    }

    enum AdmissionError: Error, LocalizedError, Equatable {
        case thermalCritical
        case pressureCooldown
        case wontFit(String)

        var errorDescription: String? {
            switch self {
            case .thermalCritical:
                return "The Mac is critically hot. Model loading is blocked until it cools down."
            case .pressureCooldown:
                return "Memory pressure just forced an emergency unload. Waiting out the cooldown before loading again."
            case .wontFit(let reason):
                return reason
            }
        }
    }

    // MARK: Tunables (kept internal so they can be adjusted after real-world testing)

    /// Fraction of physical RAM reserved for the OS and other apps.
    ///
    /// This leaves a little more room for large quantized models on Macs with
    /// attached cooling while still reserving 20% of physical RAM outside the
    /// model budget. Thermal and memory-pressure admission guards remain in
    /// force independently of this budget.
    nonisolated(unsafe) static var osReserveFraction: Double = 0.20
    /// On-disk weights → peak working-set multiplier (page-in spike + KV cache slack).
    nonisolated(unsafe) static var workingSetOverhead: Double = 1.3
    /// Fixed headroom kept free above the projected working set.
    nonisolated(unsafe) static var headroomReserveBytes: UInt64 = 500_000_000
    /// Headroom below which a critical memory-pressure event dumps the resident model.
    nonisolated(unsafe) static var criticalDumpHeadroom: UInt64 = 700_000_000
    /// Loads are blocked for this long after an emergency dump (avoids racing the kernel's reclaim).
    nonisolated(unsafe) static var pressureCooldownSeconds: TimeInterval = 20

    private static let cooldownLock = NSLock()
    nonisolated(unsafe) private static var pressureLoadBlockedUntil: Date = .distantPast

    // MARK: Measurements

    /// Total physical RAM.
    static var physicalMemory: UInt64 {
        UInt64(ProcessInfo.processInfo.physicalMemory)
    }

    /// This process's true memory footprint. `phys_footprint` matches what the
    /// kernel charges us and includes Metal buffers; `resident_size` would
    /// over-report once the GPU touches weights.
    static var processFootprint: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }

    // NOTE: `os_proc_available_memory()` is iOS-only. On macOS the budget is
    // derived from physical RAM and our own footprint, with kernel pressure
    // arriving out-of-band via MemoryPressureCoordinator.

    /// RAM usable for models after the OS reserve, minus what we already use.
    static var availableBudget: UInt64 {
        usableBudgetMinusCurrentFootprint(physical: physicalMemory, footprint: processFootprint)
    }

    // MARK: Verdicts

    /// Projected peak footprint for a model with the given on-disk byte size.
    static func projectedFootprint(diskBytes: Int64) -> UInt64 {
        guard diskBytes > 0 else { return 0 }
        let projected = Double(diskBytes) * workingSetOverhead + Double(headroomReserveBytes)
        return UInt64(min(projected, Double(UInt64.max / 2)))
    }

    static func budget(diskBytes: Int64) -> Budget {
        let physical = physicalMemory
        let footprint = processFootprint
        let usable = usableBudgetMinusCurrentFootprint(physical: physical, footprint: footprint)
        let projected = projectedFootprint(diskBytes: diskBytes)
        return Budget(
            physicalTotal: physical,
            usableBudget: usable,
            currentFootprint: footprint,
            projectedFootprint: projected,
            verdict: verdict(projected: projected, budget: usable)
        )
    }

    static func verdict(projected: UInt64, budget: UInt64) -> Verdict {
        guard budget > 0 else { return .wontFit("No memory budget available to evaluate.") }
        let ratio = Double(projected) / Double(budget)
        if ratio <= 0.60 { return .fits }
        if ratio <= 0.95 { return .marginal }
        return .wontFit(
            "Projected peak \(ByteFormatter.bytes(projected)) exceeds the safe memory budget "
                + "\(ByteFormatter.bytes(budget)) (needs ≤ 95%). Try a smaller quantization.")
    }

    // MARK: Admission gate

    /// The one gate every model load must pass. Thermal critical and the
    /// post-pressure cooldown are safety stops that cannot be bypassed.
    static func admitLoad(diskBytes: Int64, thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) throws {
        if thermalState == .critical {
            throw AdmissionError.thermalCritical
        }
        cooldownLock.lock()
        let blockedUntil = pressureLoadBlockedUntil
        cooldownLock.unlock()
        if Date() < blockedUntil {
            throw AdmissionError.pressureCooldown
        }
        let verdict = budget(diskBytes: diskBytes).verdict
        if case .wontFit(let reason) = verdict {
            throw AdmissionError.wontFit(reason)
        }
    }

    /// Records that an emergency dump happened; starts the load cooldown.
    static func notePressureDump() {
        cooldownLock.lock()
        pressureLoadBlockedUntil = Date().addingTimeInterval(pressureCooldownSeconds)
        cooldownLock.unlock()
        Log.memory.warning("Emergency model dump performed; loads blocked for \(self.pressureCooldownSeconds)s")
    }

    /// True when our own headroom is low enough that critical pressure is our problem.
    static var shouldDumpOnCriticalPressure: Bool {
        availableBudget < criticalDumpHeadroom
    }

    private static func usableBudgetMinusCurrentFootprint(physical: UInt64, footprint: UInt64) -> UInt64 {
        let usableTotal = Double(physical) * (1.0 - osReserveFraction)
        let usable = UInt64(usableTotal)
        return footprint >= usable ? 0 : usable - footprint
    }
}
