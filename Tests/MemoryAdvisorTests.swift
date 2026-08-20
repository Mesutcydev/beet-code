import XCTest
@testable import BeetCode

final class MemoryAdvisorTests: XCTestCase {

    private let gb: UInt64 = 1_000_000_000

    func testVerdictThresholds() {
        let budget: UInt64 = 10 * gb
        // 60% of budget → fits
        XCTAssertEqual(MemoryAdvisor.verdict(projected: 6 * gb, budget: budget), .fits)
        // 61% → marginal
        XCTAssertEqual(MemoryAdvisor.verdict(projected: 6_100_000_000, budget: budget), .marginal)
        // 95% → marginal boundary
        XCTAssertEqual(MemoryAdvisor.verdict(projected: 9_500_000_000, budget: budget), .marginal)
        // 96% → wontFit
        if case .wontFit = MemoryAdvisor.verdict(projected: 9_600_000_000, budget: budget) {
            // expected
        } else {
            XCTFail("expected wontFit")
        }
    }

    func testVerdictReasonIncludesNumbers() {
        if case .wontFit(let reason) = MemoryAdvisor.verdict(projected: 20 * gb, budget: 5 * gb) {
            XCTAssertTrue(reason.contains("GB") || reason.contains("MB"), "reason should quantify: \(reason)")
        } else {
            XCTFail("expected wontFit")
        }
    }

    func testProjectedFootprintIncludesOverheadAndHeadroom() {
        MemoryAdvisor.workingSetOverhead = 1.3
        MemoryAdvisor.headroomReserveBytes = 500_000_000
        let disk: Int64 = 1_000_000_000
        let projected = MemoryAdvisor.projectedFootprint(diskBytes: disk)
        XCTAssertEqual(projected, 1_300_000_000 + 500_000_000)
    }

    func testZeroBudgetNeverFits() {
        if case .wontFit = MemoryAdvisor.verdict(projected: 1, budget: 0) {
            // expected
        } else {
            XCTFail("expected wontFit on zero budget")
        }
    }

    func testAdmissionBlocksOnCooldown() {
        MemoryAdvisor.pressureCooldownSeconds = 60
        MemoryAdvisor.notePressureDump()
        XCTAssertThrowsError(try MemoryAdvisor.admitLoad(diskBytes: 1_000_000)) { error in
            XCTAssertEqual(error as? MemoryAdvisor.AdmissionError, .pressureCooldown)
        }
        MemoryAdvisor.pressureCooldownSeconds = 0.01
        MemoryAdvisor.notePressureDump() // reset with a near-zero cooldown for other tests
    }
}
