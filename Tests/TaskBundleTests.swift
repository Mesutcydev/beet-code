import Foundation
import XCTest
@testable import BeetCode

final class TaskBundleTests: XCTestCase {

    private func record(workspacePath: String = "/tmp/beetcode-project") -> SessionRecord {
        SessionRecord(
            id: UUID(),
            title: "Fix the build",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_120),
            workspacePath: workspacePath,
            modelID: "local-qwen",
            messages: [
                SessionMessage(
                    role: .user,
                    content: "Inspect the project and fix the failing build.",
                    toolName: nil,
                    timestamp: Date(timeIntervalSince1970: 1_700_000_001)),
                SessionMessage(
                    role: .toolCall,
                    content: "{\"command\":\"swift test\",\"token\":\"sk-abcdefghijklmnopqrstuvwx\"}",
                    toolName: "run_command",
                    timestamp: Date(timeIntervalSince1970: 1_700_000_002)),
                SessionMessage(
                    role: .toolResult,
                    content: "Build succeeded",
                    toolName: "run_command",
                    timestamp: Date(timeIntervalSince1970: 1_700_000_003)),
            ],
            checkpoints: [
                SessionCheckpoint(
                    id: UUID(), treeSHA: "old-tree", createdAt: Date(), summary: "before edit")
            ])
    }

    func testEncryptedRoundTripHidesTranscriptAndRedactsToolSecrets() throws {
        let original = record()
        let bundle = TaskBundle.make(from: original)
        XCTAssertEqual(bundle.version, TaskBundle.currentVersion)
        XCTAssertEqual(bundle.workspaceHint, "beetcode-project")
        XCTAssertEqual(bundle.session.source, .bundle)
        XCTAssertTrue(bundle.session.checkpoints.isEmpty)
        XCTAssertFalse(bundle.session.messages[1].content.contains("sk-abcdefghijklmnopqrstuvwx"))

        let data = try TaskBundleCodec.encode(bundle, passphrase: "correct horse")
        let encodedText = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(encodedText.contains(original.title))
        XCTAssertFalse(encodedText.contains("Inspect the project"))

        let decoded = try TaskBundleCodec.decode(data, passphrase: "correct horse")
        XCTAssertEqual(decoded, bundle)
    }

    func testWrongPassphraseAndWeakPassphraseAreRejected() throws {
        let data = try TaskBundleCodec.encode(
            TaskBundle.make(from: record()), passphrase: "correct horse")

        XCTAssertThrowsError(try TaskBundleCodec.decode(data, passphrase: "wrong horse")) { error in
            XCTAssertEqual(error as? TaskBundleError, .authenticationFailed)
        }
        XCTAssertThrowsError(try TaskBundleCodec.encode(TaskBundle.make(from: record()), passphrase: "short")) { error in
            XCTAssertEqual(error as? TaskBundleError, .passphraseTooShort)
        }
    }

    func testRebindingRequiresExistingWorkspaceAndDropsStaleCheckpoints() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("beetcode-bundle-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let bundle = TaskBundle.make(from: record(workspacePath: "/Users/another/project"))
        let rebound = try TaskBundleCodec.reboundSession(bundle, workspace: workspace)
        XCTAssertNotEqual(rebound.id, bundle.session.id)
        XCTAssertEqual(rebound.workspacePath, workspace.standardizedFileURL.path)
        XCTAssertEqual(rebound.source, .bundle)
        XCTAssertTrue(rebound.checkpoints.isEmpty)

        let missing = workspace.appendingPathComponent("missing")
        XCTAssertThrowsError(try TaskBundleCodec.reboundSession(bundle, workspace: missing)) { error in
            XCTAssertEqual(error as? TaskBundleError, .workspaceRequired)
        }
    }
}
