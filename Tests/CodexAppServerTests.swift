import XCTest
@testable import BeetCode

final class CodexAppServerTests: XCTestCase {

    func testParsesResponseAndServerRequestMessages() throws {
        let responseValue = try LFJSONValue.decode(
            #"{"id":7,"result":{"account":{"type":"chatgpt","planType":"plus"}}}"#)
        let response = try XCTUnwrap(CodexServerMessage(value: responseValue))
        XCTAssertTrue(response.isResponse)
        XCTAssertEqual(response.id, 7)
        XCTAssertEqual(response.result?.objectValue?["account"]?.objectValue?["type"]?.stringValue, "chatgpt")

        let requestValue = try LFJSONValue.decode(
            #"{"id":8,"method":"item/commandExecution/requestApproval","params":{"itemId":"item-1"}}"#)
        let request = try XCTUnwrap(CodexServerMessage(value: requestValue))
        XCTAssertTrue(request.isServerRequest)
        XCTAssertFalse(request.isNotification)
        XCTAssertEqual(request.method, "item/commandExecution/requestApproval")

        let notificationValue = try LFJSONValue.decode(
            #"{"method":"item/agentMessage/delta","params":{"delta":"hello"}}"#)
        let notification = try XCTUnwrap(CodexServerMessage(value: notificationValue))
        XCTAssertTrue(notification.isNotification)
        XCTAssertEqual(notification.params?.objectValue?["delta"]?.stringValue, "hello")
    }

    func testExecutableDiscoveryHonorsAnExplicitExecutable() {
        let candidate = "/bin/sh"
        guard FileManager.default.isExecutableFile(atPath: candidate) else { return }
        XCTAssertEqual(
            CodexAppServerClient.discoverExecutable(customPath: candidate)?.path,
            candidate)
    }

    func testSessionStoresOpaqueCodexThreadIdWithoutCredentials() throws {
        let record = SessionRecord(
            id: UUID(),
            title: "Codex account turn",
            createdAt: Date(),
            updatedAt: Date(),
            workspacePath: "/tmp/beetcode-codex-test",
            modelID: "openai-codex:gpt-5",
            messages: [],
            checkpoints: [],
            source: .app,
            schemaVersion: SessionRecord.currentSchemaVersion,
            codexThreadID: "thr_test")
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: data)
        XCTAssertEqual(decoded.codexThreadID, "thr_test")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("refresh"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("access_token"))
    }

    func testErrorsExplainWhichAppServerOperationFailed() {
        XCTAssertEqual(
            CodexAppServerError.timedOut("model/list").errorDescription,
            "Codex app-server timed out while handling model/list.")
        XCTAssertEqual(
            CodexAppServerError.malformedResponse("thread/resume").errorDescription,
            "Codex app-server returned an invalid response for thread/resume.")
    }
}
