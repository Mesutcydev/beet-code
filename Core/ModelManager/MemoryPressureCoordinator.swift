import Foundation

/// Watches kernel memory-pressure notifications and drives the layered response:
/// - `.warning`  → clear inference caches (models stay resident)
/// - `.critical` → dump the resident model, but only when our own headroom is low
///
/// The coordinator itself knows nothing about engines — callers inject the
/// reactions, keeping this testable and dependency-free.
final class MemoryPressureCoordinator: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.beetcode.memory-pressure", qos: .utility)
    private var source: DispatchSourceMemoryPressure?
    private let onWarning: @Sendable () async -> Void
    private let onCritical: @Sendable () async -> Void
    private let lock = NSLock()
    private var started = false

    init(
        onWarning: @escaping @Sendable () async -> Void,
        onCritical: @escaping @Sendable () async -> Void
    ) {
        self.onWarning = onWarning
        self.onCritical = onCritical
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: queue)
        self.source = source

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            if event.contains(.critical) {
                Log.memory.fault("Kernel memory pressure: CRITICAL")
                Task { await self.onCritical() }
            } else if event.contains(.warning) {
                Log.memory.warning("Kernel memory pressure: warning")
                Task { await self.onWarning() }
            }
        }
        source.resume()
        Log.memory.info("Memory pressure coordinator started")
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        source?.cancel()
        source = nil
        started = false
    }
}
