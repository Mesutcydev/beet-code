import XCTest
@testable import BeetCode

final class AgentMemoryTests: XCTestCase {

    func testFactsPersistAcrossInstances() throws {
        let workspace = TempWorkspace()
        let key = AgentMemory.key(for: workspace.url.path)
        let memory = AgentMemory(workspacePath: workspace.url.path)
        XCTAssertEqual(memory.workspaceKey, key)

        memory.addFact("the project uses SwiftUI for the UI layer", source: "test")
        memory.addFact("the build command is swift build", source: "test")
        XCTAssertEqual(memory.allFacts.count, 2)

        // A fresh instance (simulated relaunch) reads the same facts.
        let reloaded = AgentMemory(workspacePath: workspace.url.path)
        XCTAssertEqual(reloaded.allFacts.count, 2)
        XCTAssertTrue(reloaded.allFacts.contains { $0.text.contains("SwiftUI") })
    }

    func testDeduplicationAndBounds() {
        let workspace = TempWorkspace()
        let memory = AgentMemory(workspacePath: workspace.url.path)
        memory.addFact("duplicate fact here")
        memory.addFact("duplicate fact here")
        XCTAssertEqual(memory.allFacts.count, 1, "near-identical facts must deduplicate")
        // Short noise is refused.
        XCTAssertNil(memory.addFact("tiny"))
    }

    func testDeleteFactByTextAndID() {
        let workspace = TempWorkspace()
        let memory = AgentMemory(workspacePath: workspace.url.path)
        let fact = memory.addFact("remember this important detail")
        XCTAssertNotNil(fact)
        memory.deleteFact(text: "remember this important detail")
        XCTAssertTrue(memory.allFacts.isEmpty)
        memory.addFact("another important detail")
        if let stored = memory.allFacts.first {
            memory.deleteFact(id: stored.id)
            XCTAssertTrue(memory.allFacts.isEmpty)
        }
    }

    func testSummariesAndContextSection() {
        let workspace = TempWorkspace()
        let memory = AgentMemory(workspacePath: workspace.url.path)
        memory.addSummary("fixed the login flow by adding a token refresh", sessionTitle: "login fix")
        memory.addFact("the login flow uses token refresh")

        // Facts mode excludes summaries.
        let factsOnly = memory.contextSection(mode: .facts, taskHint: "login")
        XCTAssertNotNil(factsOnly)
        XCTAssertTrue(factsOnly?.contains("login flow") == true)
        XCTAssertFalse(factsOnly?.contains("Earlier sessions") == true)

        // Full mode includes both; task-relevant facts rank first.
        let full = memory.contextSection(mode: .full, taskHint: "login token")
        XCTAssertTrue(full?.contains("Earlier sessions") == true)
        XCTAssertTrue(full?.contains("token refresh") == true)

        // Off mode produces nothing.
        XCTAssertNil(memory.contextSection(mode: .off, taskHint: "login"))
    }

    func testContextSectionBounded() {
        let workspace = TempWorkspace()
        let memory = AgentMemory(workspacePath: workspace.url.path)
        for index in 0..<30 {
            memory.addFact("fact number \(index) about the project")
        }
        let section = memory.contextSection(mode: .facts, taskHint: "", maxFacts: 8)
        XCTAssertNotNil(section)
        XCTAssertLessThanOrEqual(section!.components(separatedBy: "\n").count - 1, 8)
    }
}

final class CompressionLevelTests: XCTestCase {

    func testCompactionRespectsLevel() {
        func message(_ content: String) -> SessionMessage {
            SessionMessage(role: .toolResult, content: content, toolName: "t", timestamp: Date())
        }
        var messages: [SessionMessage] = []
        for index in 0..<8 {
            messages.append(message("output \(index) " + String(repeating: "x", count: 4_000)))
        }

        // Light keeps 6 full results.
        let light = ContextCompactor.compact(messages, keepRecent: CompressionLevel.light.keepRecent)
        XCTAssertEqual(light.filter { $0.content.contains("omitted") }.count, 2)

        // Aggressive keeps 1 and truncates the preserved ones.
        let aggressive = ContextCompactor.compact(
            messages,
            keepRecent: CompressionLevel.aggressive.keepRecent,
            maxToolResultChars: CompressionLevel.aggressive.maxToolResultChars)
        XCTAssertEqual(aggressive.filter { $0.content.contains("omitted") }.count, 7)
        let kept = aggressive.last?.content ?? ""
        XCTAssertTrue(kept.contains("truncated by aggressive compression"), kept)
        XCTAssertLessThan(kept.utf8.count, 2_200)
    }
}