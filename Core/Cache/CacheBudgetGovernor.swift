import Foundation

/// RAM budget split for derived caches, computed from available memory.
/// MemoryAdvisor remains the sole authority for MODEL admission; this governor
/// only budgets disposable hot caches (KV allowance + CPU-side objects).
struct RuntimeBudget: Equatable, Sendable {
    let availableBytes: UInt64
    let reserveBytes: UInt64
    let kvBudgetBytes: UInt64
    let hotObjectBudgetBytes: UInt64
}

enum CacheBudgetGovernor {

    static func calculateBudget(availableBytes: UInt64) -> RuntimeBudget {
        let mib: UInt64 = 1_048_576

        // Preserve room for prefill spikes, Metal work, the UI, and the OS.
        let reserve = max(
            UInt64(Double(availableBytes) * 0.20),
            1_280 * mib)

        guard availableBytes > reserve + 512 * mib else {
            return RuntimeBudget(
                availableBytes: availableBytes,
                reserveBytes: reserve,
                kvBudgetBytes: 128 * mib,
                hotObjectBudgetBytes: 64 * mib)
        }

        let headroom = availableBytes - reserve
        return RuntimeBudget(
            availableBytes: availableBytes,
            reserveBytes: reserve,
            kvBudgetBytes: min(
                UInt64(Double(headroom) * 0.60),
                768 * mib),
            hotObjectBudgetBytes: min(
                UInt64(Double(headroom) * 0.20),
                256 * mib))
    }
}
