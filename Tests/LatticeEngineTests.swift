import XCTest
@testable import BeetCode

final class LatticeEngineTests: XCTestCase {

    private func cell(_ id: String, _ row: String, weight: Double = 0.9,
                      fragment: String = "do the thing", locked: Bool = false,
                      active: Bool = true) -> LatticeEngineCell {
        LatticeEngineCell(id: id, rowId: row, colId: "files", active: active,
                          weight: weight, locked: locked, promptFragment: fragment)
    }

    func testEstimateTokensEmptyIsZero() {
        XCTAssertEqual(LatticeEngine.estimateTokens(""), 0)
        XCTAssertEqual(LatticeEngine.estimateTokens("   \n  "), 0)
    }

    func testEstimateTokensScalesWithLength() {
        let short = LatticeEngine.estimateTokens("hello world")
        let long = LatticeEngine.estimateTokens(String(repeating: "hello world ", count: 50))
        XCTAssertGreaterThan(long, short)
    }

    func testComposeSortsByPriorityThenWeight() {
        // plan=10 (higher priority) should come before verify=40.
        let state = LatticeEngineState(cells: [
            cell("v", "verify", weight: 0.9),
            cell("p", "plan", weight: 0.5),
        ])
        let result = LatticeEngine.compose(state)
        XCTAssertEqual(result.sortedIds, ["p", "v"])
    }

    func testComposeEncodesRoleAndContextWithoutWeightTiers() {
        let state = LatticeEngineState(cells: [
            cell("hi", "plan", weight: 0.9),
            cell("lo", "verify", weight: 0.2),
        ])
        let content = LatticeEngine.compose(state).systemContent
        XCTAssertTrue(content.contains("### PLAN"))
        XCTAssertTrue(content.contains("### VERIFY"))
        XCTAssertFalse(content.contains("HIGH"))
        XCTAssertFalse(content.contains("weight:"))
    }

    func testComposeInjectsResolvedContext() {
        let state = LatticeEngineState(cells: [cell("p", "plan")])
        let result = LatticeEngine.compose(state) { col in
            col == "files" ? [ResolvedContext(source: "files", content: "42 lines", tokenEstimate: 10)] : []
        }
        XCTAssertTrue(result.systemContent.contains("--- Context ---"))
        XCTAssertTrue(result.systemContent.contains("[files]"))
    }

    func testComposeEmptyYieldsEmptyContent() {
        let result = LatticeEngine.compose(LatticeEngineState(cells: []))
        XCTAssertEqual(result.systemContent, "")
        XCTAssertEqual(result.activeCellCount, 0)
    }

    func testBudgetPrunesLowPriorityWhenOverHardLimit() {
        let big = String(repeating: "token ", count: 120) // ~ large fragment
        let state = LatticeEngineState(cells: [
            cell("plan", "plan", fragment: big),
            cell("bg", "background", fragment: big),
        ])
        let config = TokenBudgetConfig(hardLimit: 300, softLimit: 250)
        let r = LatticeEngine.budgetAwareCompose(state, config: config)
        // background (pri 50) is less important than plan (pri 10) -> pruned first.
        XCTAssertTrue(r.pruned.contains("bg"))
        XCTAssertFalse(r.pruned.contains("plan"))
        XCTAssertLessThanOrEqual(r.budget.used, config.hardLimit)
    }

    func testBudgetProtectsLockedCells() {
        let big = String(repeating: "token ", count: 120)
        let state = LatticeEngineState(cells: [
            cell("plan", "plan", fragment: big),
            cell("bg", "background", fragment: big, locked: true),
        ])
        let config = TokenBudgetConfig(hardLimit: 200, softLimit: 150)
        let r = LatticeEngine.budgetAwareCompose(state, config: config)
        XCTAssertFalse(r.pruned.contains("bg"), "locked cells must never be pruned")
    }

    func testBudgetStatusWarnings() {
        let big = String(repeating: "token ", count: 400)
        let state = LatticeEngineState(cells: [cell("plan", "plan", fragment: big)])
        let status = LatticeEngine.budgetStatus(state, config: TokenBudgetConfig(hardLimit: 200, softLimit: 100))
        XCTAssertTrue(status.softExceeded)
        XCTAssertTrue(status.hardExceeded)
        XCTAssertFalse(status.warnings.isEmpty)
    }
}
