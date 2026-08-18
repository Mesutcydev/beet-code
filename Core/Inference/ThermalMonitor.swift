import Foundation
import MachO

/// Monitors thermal state with hysteresis so the UI and policy layer see a
/// debounced view: heating transitions apply after 8 s, cooling after 15 s,
/// and `.critical` applies immediately.
///
/// On Apple Silicon, `ProcessInfo.thermalState` alone is a poor signal: it
/// stays `.nominal` until the SoC hits throttling thresholds, so a genuinely
/// warm machine often reports cool. A CPU-load proxy (public
/// `host_processor_info`, no privileges) is therefore merged in: sustained
/// high CPU escalates the effective state even when the kernel says nominal.
@MainActor
final class ThermalMonitor: ObservableObject {

    @Published private(set) var effectiveState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    /// What the kernel reports (before the CPU-load proxy is merged).
    @Published private(set) var systemThermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    /// Busy fraction of host CPUs over the last window (0...1).
    @Published private(set) var cpuBusyFraction: Double = 0

    private var pendingState: ProcessInfo.ThermalState?
    private var applyTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var samplerTask: Task<Void, Never>?

    private let heatUpDelay: TimeInterval = 8
    private let coolDownDelay: TimeInterval = 15

    // CPU-load proxy state.
    private var cpuSamples: [Double] = []
    private var lastCPUTicks: (total: UInt64, busy: UInt64)?
    private var sustainedHotStart: Date?
    private var proxyState: ProcessInfo.ThermalState = .nominal
    private let proxyHeatWindow: TimeInterval = 15  // sustained busy before escalating
    private let proxyCoolWindow: TimeInterval = 30  // sustained calm before cooling

    init() {
        let notifications = NotificationCenter.default.notifications(
            named: ProcessInfo.thermalStateDidChangeNotification)
        notificationTask = Task { [weak self] in
            for await _ in notifications {
                self?.stateDidChange()
            }
        }
        startCPUSampling()
    }

    deinit {
        notificationTask?.cancel()
        applyTask?.cancel()
        samplerTask?.cancel()
    }

    // MARK: Kernel thermal state

    private func stateDidChange() {
        systemThermalState = ProcessInfo.processInfo.thermalState
        // The effective state is always the max of kernel and CPU-load
        // proxy: a kernel cool-down must not mask a hot proxy, and a kernel
        // heat-up applies even when the proxy is calm.
        let target = mergedState()
        guard target != effectiveState else {
            pendingState = nil
            applyTask?.cancel()
            return
        }

        // Critical is a safety stop — apply immediately.
        if target == .critical {
            applyTask?.cancel()
            pendingState = nil
            transition(to: target)
            return
        }

        pendingState = target
        applyTask?.cancel()
        let isHeating = rank(target) > rank(effectiveState)
        let delay = isHeating ? heatUpDelay : coolDownDelay
        applyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let pending = self.pendingState else { return }
            self.pendingState = nil
            self.transition(to: pending)
        }
    }

    // MARK: CPU-load proxy

    private func startCPUSampling() {
        // Sample host CPU load every 2 s; a 16-sample ring covers ~32 s.
        samplerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sampleCPU()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func sampleCPU() {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var num: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &count,
            &info,
            &num)
        guard result == KERN_SUCCESS, let info else {
            // API unavailable — fall back to the kernel state alone.
            proxyState = .nominal
            return
        }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(num) * vm_size_t(MemoryLayout<integer_t>.size)) }

        var total: UInt64 = 0
        var busy: UInt64 = 0
        let ticks = UnsafeBufferPointer(start: info, count: Int(num))
        // Each CPU contributes 4 ticks: user, system, idle, nice.
        var index = 0
        while index + 3 < ticks.count {
            let user = UInt64(ticks[index])
            let system = UInt64(ticks[index + 1])
            let idle = UInt64(ticks[index + 2])
            let nice = UInt64(ticks[index + 3])
            total += user + system + idle + nice
            busy += user + system + nice
            index += 4
        }

        if let previous = lastCPUTicks {
            let deltaTotal = total - previous.total
            let deltaBusy = busy - previous.busy
            if deltaTotal > 0 {
                let fraction = Double(deltaBusy) / Double(deltaTotal)
                cpuSamples.append(fraction)
                if cpuSamples.count > 16 { cpuSamples.removeFirst() }
                cpuBusyFraction = cpuSamples.reduce(0, +) / Double(cpuSamples.count)
                updateProxyState()
            }
        }
        lastCPUTicks = (total, busy)
    }

    /// Escalates the proxy state when CPU busy stays high, cools it after a
    /// calm window. The effective state is the max of kernel and proxy.
    private func updateProxyState() {
        let average = cpuSamples.reduce(0, +) / Double(max(cpuSamples.count, 1))
        let target: ProcessInfo.ThermalState
        if average > 0.90 {
            target = .serious
        } else if average > 0.75 {
            target = .fair
        } else {
            target = .nominal
        }

        let now = Date()
        if target.rawRank > proxyState.rawRank {
            // Heating: require the load to persist.
            if sustainedHotStart == nil { sustainedHotStart = now }
            if now.timeIntervalSince(sustainedHotStart!) >= proxyHeatWindow {
                proxyState = target
                sustainedHotStart = nil
                transition(to: mergedState())
            }
        } else if target.rawRank < proxyState.rawRank {
            // Cooling: require calm to persist.
            if sustainedHotStart == nil { sustainedHotStart = now }
            if now.timeIntervalSince(sustainedHotStart!) >= proxyCoolWindow {
                proxyState = target
                sustainedHotStart = nil
                transition(to: mergedState())
            }
        } else {
            sustainedHotStart = nil
        }
    }

    private func mergedState() -> ProcessInfo.ThermalState {
        rank(systemThermalState) >= rank(proxyState) ? systemThermalState : proxyState
    }

    private func transition(to state: ProcessInfo.ThermalState) {
        guard state != effectiveState else { return }
        effectiveState = state
        Log.thermal.info("Thermal state → \(state.description, privacy: .public) (cpu busy \(Int(self.cpuBusyFraction * 100))%)")
        objectWillChange.send()
    }

    private func rank(_ state: ProcessInfo.ThermalState) -> Int {
        state.rawRank
    }

    // MARK: Policy surface

    /// True when generation should be throttled (caps, no parallel work).
    var shouldThrottle: Bool {
        effectiveState == .serious || effectiveState == .critical
    }

    /// Safety stop: block loads, stop heavy work. Not user-disableable.
    var blocksHeavyWork: Bool {
        effectiveState == .critical
    }

    /// Token cap for the current thermal state, bounded by the caller's ceiling.
    func maxTokens(ceiling: Int) -> Int {
        switch effectiveState {
        case .critical: min(512, ceiling)
        case .serious: min(1536, ceiling)
        default: ceiling
        }
    }
}

private extension ProcessInfo.ThermalState {
    var rawRank: Int {
        switch self {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        @unknown default: 2
        }
    }
}

extension ProcessInfo.ThermalState {
    var description: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
    
    /// UI label for the status bar.
    var uiLabel: String {
        switch self {
        case .nominal: return "Cool"
        case .fair: return "Warm"
        case .serious: return "Hot — throttling"
        case .critical: return "Critical — loads blocked"
        @unknown default: return "Unknown"
        }
    }
    
    var uiIcon: String {
        switch self {
        case .nominal: return "thermometer.low"
        case .fair: return "thermometer.medium"
        case .serious: return "thermometer.high"
        case .critical: return "thermometer.sun.fill"
        @unknown default: return "thermometer.medium"
        }
    }
}