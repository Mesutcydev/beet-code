import Foundation
import XCTest
@testable import BeetCode

final class TaskQueueTests: XCTestCase {

    private func isolatedQueue() -> (TaskQueueStore, URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beetcode-task-queue-\(UUID().uuidString)")
        let queueURL = root.appendingPathComponent("Queue", isDirectory: true)
        let workspace = root.appendingPathComponent("Workspace", isDirectory: true)
        try! FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let store = TaskQueueStore()
        store.overrideDirectory = queueURL
        return (store, root, workspace)
    }

    func testQueuePersistsAndRecoversInterruptedWork() throws {
        let (store, root, workspace) = isolatedQueue()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID()
        let task = try store.enqueue(
            sessionID: sessionID,
            workspacePath: workspace.path,
            message: "Run the project checks",
            modelID: "local-qwen")
        XCTAssertEqual(store.load(id: task.id)?.state, .queued)

        store.update(task.id) { item in
            item.state = .awaitingApproval
            item.phase = "Needs approval"
        }
        let recovered = store.recoverInterrupted()
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].id, task.id)
        XCTAssertEqual(recovered[0].state, .queued)
        XCTAssertEqual(recovered[0].attempts, 1)
        XCTAssertEqual(recovered[0].lastError, "Requeued after Beet Code restarted.")
    }

    func testQueueRejectsMissingWorkspaceAndEmptyPrompt() throws {
        let (store, root, workspace) = isolatedQueue()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try store.enqueue(
            sessionID: UUID(), workspacePath: workspace.path, message: "  ", modelID: "m")) { error in
            XCTAssertEqual(error as? TaskQueueError, .invalidMessage)
        }
        XCTAssertThrowsError(try store.enqueue(
            sessionID: UUID(), workspacePath: root.appendingPathComponent("missing").path,
            message: "hello", modelID: "m")) { error in
            XCTAssertEqual(error as? TaskQueueError, .invalidWorkspace)
        }
    }
}
