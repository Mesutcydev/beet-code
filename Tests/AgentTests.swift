import XCTest
@testable import BeetCode

final class ApplyPatchToolTests: XCTestCase {

    private var workspace: Workspace!
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lf-patch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        workspace = Workspace(root: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testParseBlocks() {
        let diff = """
        path/to/file.swift
        <<<<<<< SEARCH
        let x = 1
        =======
        let x = 2
        >>>>>>> REPLACE
        """
        let blocks = ApplyPatchTool.parseBlocks(diff)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].search.trimmingCharacters(in: .whitespaces), "let x = 1")
        XCTAssertEqual(blocks[0].replace.trimmingCharacters(in: .whitespaces), "let x = 2")
    }

    func testApplySingleBlock() throws {
        let result = try ApplyPatchTool.apply(
            diff: """
            <<<<<<< SEARCH
            let x = 1
            =======
            let x = 2
            >>>>>>> REPLACE
            """,
            to: "let x = 1\nlet y = 3")
        XCTAssertEqual(result.newContent, "let x = 2\nlet y = 3")
        XCTAssertEqual(result.appliedBlocks, 1)
    }

    func testApplyMultipleBlocksInOrder() throws {
        let content = "alpha\nbeta\ngamma\n"
        let result = try ApplyPatchTool.apply(
            diff: """
            <<<<<<< SEARCH
            alpha
            =======
            ALPHA
            >>>>>>> REPLACE
            <<<<<<< SEARCH
            gamma
            =======
            GAMMA
            >>>>>>> REPLACE
            """,
            to: content)
        XCTAssertEqual(result.newContent, "ALPHA\nbeta\nGAMMA\n")
        XCTAssertEqual(result.appliedBlocks, 2)
    }

    func testWhitespaceMustMatchExactly() {
        XCTAssertThrowsError(
            try ApplyPatchTool.apply(
                diff: """
                <<<<<<< SEARCH
                let x = 1
                =======
                let x = 2
                >>>>>>> REPLACE
                """,
                to: "let  x = 1")  // double space in the file
        ) { error in
            guard case ApplyPatchTool.PatchError.searchNotFound = error else {
                return XCTFail("expected searchNotFound, got \(error)")
            }
        }
    }

    func testEmptySearchCreatesContent() throws {
        let result = try ApplyPatchTool.apply(
            diff: """
            <<<<<<< SEARCH
            =======
            hello world
            >>>>>>> REPLACE
            """,
            to: "")
        XCTAssertEqual(result.newContent, "hello world")
    }

    func testEmptySearchAppendsToExisting() throws {
        let result = try ApplyPatchTool.apply(
            diff: """
            <<<<<<< SEARCH
            =======
            new line
            >>>>>>> REPLACE
            """,
            to: "existing")
        XCTAssertEqual(result.newContent, "existing\nnew line")
    }

    func testNoBlocksThrows() {
        XCTAssertThrowsError(try ApplyPatchTool.apply(diff: "no markers here", to: "x")) { error in
            guard case ApplyPatchTool.PatchError.noBlocksFound = error else {
                return XCTFail("expected noBlocksFound")
            }
        }
    }

    func testExecuteWritesFileAndRequiresPriorRead() async throws {
        let context = ToolContext(workspace: workspace)
        let path = "Sources/new-file.swift"
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("Sources"),
            withIntermediateDirectories: true)
        try "original content".write(toFile: tempDir.appendingPathComponent(path).path, atomically: true, encoding: .utf8)

        let call = ParsedToolCall(
            name: "apply_patch",
            arguments: .object([
                "path": .string(path),
                "diff": .string("""
                <<<<<<< SEARCH
                original content
                =======
                patched content
                >>>>>>> REPLACE
                """),
            ]),
            index: 0)

        // Without a prior read → refused.
        do {
            _ = try await ApplyPatchTool().execute(call, in: context)
            XCTFail("expected notPreviouslyRead")
        } catch let error as ToolError {
            XCTAssertEqual(error, .notPreviouslyRead(path))
        }

        // After a read → applied.
        let readCall = ParsedToolCall(name: "read_file", arguments: .object(["path": .string(path)]), index: 1)
        _ = try await ReadFileTool().execute(readCall, in: context)
        let output = try await ApplyPatchTool().execute(call, in: context)
        XCTAssertTrue(output.contains("1 block"), output)

        let patched = try String(contentsOfFile: tempDir.appendingPathComponent(path).path, encoding: .utf8)
        XCTAssertEqual(patched, "patched content")
    }
}

final class PermissionGateTests: XCTestCase {

    private func call(name: String, command: String? = nil) -> ParsedToolCall {
        var arguments: [String: LFJSONValue] = [:]
        if let command { arguments["command"] = .string(command) }
        return ParsedToolCall(name: name, arguments: .object(arguments), index: 0)
    }

    func testReadsAlwaysAuto() {
        let gate = PermissionGate()
        XCTAssertEqual(gate.decision(for: call(name: "read_file"), risk: .read), .auto)
        XCTAssertEqual(gate.decision(for: call(name: "search"), risk: .read), .auto)
    }

    func testWritesNeedApprovalByDefault() {
        let gate = PermissionGate()
        XCTAssertEqual(gate.decision(for: call(name: "apply_patch"), risk: .write), .needsApproval)
    }

    func testWriteAutoWhenEnabled() {
        let gate = PermissionGate(autoApproveEdits: true)
        XCTAssertEqual(gate.decision(for: call(name: "write_file"), risk: .write), .auto)
    }

    func testCommandsRequireApprovalByDefault() {
        let workspace = Workspace(root: FileManager.default.temporaryDirectory)
        let gate = PermissionGate(workspace: workspace)
        XCTAssertEqual(
            gate.decision(for: call(name: "run_command", command: "swift build"), risk: .execute),
            .needsApproval)
    }

    func testSafeCommandsCanAutoApproveWhenEnabled() {
        let workspace = Workspace(root: FileManager.default.temporaryDirectory)
        let gate = PermissionGate(autoApproveCommands: true, workspace: workspace)
        XCTAssertEqual(
            gate.decision(for: call(name: "run_command", command: "swift build"), risk: .execute),
            .auto)
    }

    func testShellOperatorsAndOutsidePathsNeedApproval() {
        let workspace = Workspace(root: FileManager.default.temporaryDirectory)
        let gate = PermissionGate(autoApproveCommands: true, workspace: workspace)
        for command in ["swift build && rm -rf /", "ls; cat /etc/passwd", "swift build\nrm -rf /"] {
            XCTAssertEqual(
                gate.decision(for: call(name: "run_command", command: command), risk: .execute),
                .needsApproval,
                command)
        }
    }

    func testUnknownToolRiskNeedsApproval() {
        let gate = PermissionGate()
        XCTAssertEqual(gate.decision(for: call(name: "mystery"), risk: nil), .needsApproval)
    }
}

final class ContextCompactorTests: XCTestCase {

    private func message(_ role: SessionMessage.Role, _ content: String) -> SessionMessage {
        SessionMessage(role: role, content: content, toolName: nil, timestamp: Date())
    }

    func testEstimateAndThreshold() {
        let messages = [
            message(.user, String(repeating: "a", count: 4000)),  // ~1000 tokens
            message(.toolResult, "x"),
        ]
        let estimate = ContextCompactor.estimate(messages: messages, windowTokens: 1000)
        XCTAssertGreaterThan(estimate.fraction, 0.99)
        XCTAssertTrue(estimate.shouldCompact)
        XCTAssertEqual(ContextCompactor.estimate(messages: [], windowTokens: 1000).totalTokens, 0)
    }

    func testRequestEstimateIncludesSystemPromptAndResponseReserve() {
        let messages = [message(.user, String(repeating: "m", count: 10_400))]
        let messageOnly = ContextCompactor.estimate(messages: messages, windowTokens: 5_000)
        let request = ContextCompactor.estimateRequest(
            messages: messages,
            systemPrompt: String(repeating: "s", count: 4_400),
            windowTokens: 5_000,
            responseReserve: 1_024)

        XCTAssertEqual(request.historyTokens, 2_600)
        XCTAssertEqual(request.systemTokens, 1_100)
        XCTAssertEqual(request.totalTokens, 3_700)
        XCTAssertEqual(request.budgetTokens, 3_976)
        XCTAssertLessThan(messageOnly.fraction, 0.75)
        XCTAssertGreaterThan(request.fraction, 0.75)
        XCTAssertTrue(request.shouldCompact)
    }

    func testCompactionKeepsRecentToolOutputs() {
        var messages: [SessionMessage] = [message(.user, "task")]
        for index in 0..<6 {
            messages.append(message(.assistant, "turn \(index)"))
            messages.append(message(.toolResult, String(repeating: "o", count: 100)))
        }
        let compacted = ContextCompactor.compact(messages, keepRecent: 3)
        let stubbed = compacted.filter { $0.content.contains("omitted") }
        XCTAssertEqual(stubbed.count, 3)
        // Non-tool messages untouched.
        XCTAssertEqual(compacted.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(compacted.filter { $0.role == .assistant }.count, 6)
    }

    func testFitAddsOmissionMarkerWhenProseHistoryExceedsBudget() {
        var messages: [SessionMessage] = [message(.user, "original objective")]
        for index in 0..<12 {
            messages.append(message(.assistant, "assistant turn \(index) " + String(repeating: "a", count: 700)))
            messages.append(message(.toolResult, "tool result \(index) " + String(repeating: "b", count: 700)))
        }

        let fitted = ContextCompactor.fit(
            messages,
            systemPrompt: String(repeating: "s", count: 1_000),
            windowTokens: 2_000,
            responseReserve: 256)
        let request = ContextCompactor.estimateRequest(
            messages: fitted,
            systemPrompt: String(repeating: "s", count: 1_000),
            windowTokens: 2_000,
            responseReserve: 256)

        XCTAssertTrue(fitted.contains { $0.content.contains("Earlier conversation omitted") })
        XCTAssertTrue(fitted.contains { $0.content == "original objective" })
        XCTAssertLessThanOrEqual(request.totalTokens, request.budgetTokens + 32)
    }
}

final class RunCommandToolTests: XCTestCase {

    private var workspace: Workspace!
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lf-cmd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        workspace = Workspace(root: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSuccessfulCommand() throws {
        let result = try ShellRunner.run(command: "echo hello", workingDirectory: workspace.root, timeout: 10)
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("hello"), result.output)
        XCTAssertFalse(result.failed)
    }

    func testFailingCommandReportsStatus() throws {
        let result = try ShellRunner.run(command: "exit 3", workingDirectory: workspace.root, timeout: 10)
        XCTAssertEqual(result.exitCode, 3, result.output)
        XCTAssertTrue(result.failed)
        let rendered = RunCommandTool.render(result)
        XCTAssertTrue(rendered.contains("exit status 3"), rendered)
    }

    func testTimeoutKillsProcessGroup() throws {
        let marker = "lf-timeout-marker-\(UUID().uuidString)"
        let result = try ShellRunner.run(
            command: "sleep 30 # \(marker)",
            workingDirectory: workspace.root,
            timeout: 2)
        XCTAssertTrue(result.timedOut, result.output)
        XCTAssertTrue(result.failed)
        XCTAssertTrue(RunCommandTool.render(result).contains("partial output"), result.output)
        // The child process must be dead — no survivor can outlive the call.
        let check = try ShellRunner.run(
            command: "pgrep -f '\(marker)' || true",
            workingDirectory: workspace.root,
            timeout: 5)
        XCTAssertFalse(check.output.contains("sleep"), "child survived: \(check.output)")
    }

    func testOutputTruncation() {
        let huge = String(repeating: "x", count: 100_000)
        let truncated = RunCommandTool.truncate(huge)
        XCTAssertLessThan(truncated.utf8.count, 20_000)
        XCTAssertTrue(truncated.contains("truncated"))
    }
}

final class GitCheckpointerTests: XCTestCase {

    private var tempDir: URL!
    private var checkpointer: GitCheckpointer!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lf-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        checkpointer = GitCheckpointer(workspace: Workspace(root: tempDir))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSnapshotAndRestoreRoundTrip() throws {
        // No repo → explicit error.
        XCTAssertFalse(checkpointer.hasRepository())

        try runGit(["init", "-q"])
        try "original".write(toFile: tempDir.appendingPathComponent("file.txt").path, atomically: true, encoding: .utf8)

        let checkpoint = try checkpointer.snapshot(summary: "before edit")
        XCTAssertFalse(checkpoint.treeSHA.isEmpty)

        // Mutate + add a new file.
        try "mutated".write(toFile: tempDir.appendingPathComponent("file.txt").path, atomically: true, encoding: .utf8)
        try "extra".write(toFile: tempDir.appendingPathComponent("added.txt").path, atomically: true, encoding: .utf8)

        try checkpointer.restore(checkpoint)

        let restored = try String(contentsOfFile: tempDir.appendingPathComponent("file.txt").path, encoding: .utf8)
        XCTAssertEqual(restored, "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("added.txt").path))
    }

    private func runGit(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = tempDir
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments) failed")
    }

    func testFileCreatedAfterCheckpointIsRemovedOnRestore() throws {
        try runGit(["init", "-q"])
        try "original".write(toFile: tempDir.appendingPathComponent("file.txt").path, atomically: true, encoding: .utf8)
        try runGit(["add", "-A"])
        try runGit(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base"])

        let checkpoint = try checkpointer.snapshot(summary: "before")

        // The agent then creates a NEW file that did not exist at snapshot time.
        try "agent-made".write(toFile: tempDir.appendingPathComponent("newly-created.txt").path, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("nested/deep"),
            withIntermediateDirectories: true)
        try "agent-made-nested".write(
            toFile: tempDir.appendingPathComponent("nested/deep/file.txt").path,
            atomically: true, encoding: .utf8)

        try checkpointer.restore(checkpoint)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("newly-created.txt").path),
                       "file created after the checkpoint must be removed on restore")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("nested/deep/file.txt").path),
                       "nested file created after the checkpoint must be removed on restore")
        // The pre-checkpoint file is back to its snapshot content.
        let restored = try String(contentsOfFile: tempDir.appendingPathComponent("file.txt").path, encoding: .utf8)
        XCTAssertEqual(restored, "original")
    }

    func testNewlineContainingFilenamesRoundTrip() throws {
        try runGit(["init", "-q"])
        let newlineName = "weird\nname.txt"
        try "nl-content".write(toFile: tempDir.appendingPathComponent(newlineName).path, atomically: true, encoding: .utf8)
        try "tracked".write(toFile: tempDir.appendingPathComponent("file.txt").path, atomically: true, encoding: .utf8)

        let checkpoint = try checkpointer.snapshot(summary: "before")

        // Mutate both; add another newline-named file after the checkpoint.
        try "mutated".write(toFile: tempDir.appendingPathComponent("file.txt").path, atomically: true, encoding: .utf8)
        try "nl-mutated".write(toFile: tempDir.appendingPathComponent(newlineName).path, atomically: true, encoding: .utf8)
        let secondNewlineName = "another\nfile.txt"
        try "post-checkpoint".write(toFile: tempDir.appendingPathComponent(secondNewlineName).path, atomically: true, encoding: .utf8)

        try checkpointer.restore(checkpoint)

        // Pre-checkpoint newline-named file restored to snapshot content.
        let restoredNL = try String(contentsOfFile: tempDir.appendingPathComponent(newlineName).path, encoding: .utf8)
        XCTAssertEqual(restoredNL, "nl-content", "newline-containing path must be restored exactly")
        // Post-checkpoint newline-named file removed.
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(secondNewlineName).path),
                       "newline-containing path created after checkpoint must be removed")
        let restored = try String(contentsOfFile: tempDir.appendingPathComponent("file.txt").path, encoding: .utf8)
        XCTAssertEqual(restored, "tracked")
    }

    func testRestoreRefusesForeignTree() throws {
        try runGit(["init", "-q"])
        try "original".write(toFile: tempDir.appendingPathComponent("file.txt").path, atomically: true, encoding: .utf8)
        let foreign = SessionCheckpoint(
            id: UUID(),
            treeSHA: "0000000000000000000000000000000000000000",
            createdAt: Date(),
            summary: "not from this repo")
        XCTAssertThrowsError(try checkpointer.restore(foreign)) { error in
            guard case GitCheckpointer.CheckpointError.foreignTree = error else {
                return XCTFail("expected foreignTree, got \(error)")
            }
        }
        let content = try String(contentsOfFile: tempDir.appendingPathComponent("file.txt").path, encoding: .utf8)
        XCTAssertEqual(content, "original", "worktree must be untouched")
    }

    func testRestorePreservesIgnoredFiles() throws {
        try runGit(["init", "-q"])
        try "build/\n*.log\n".write(toFile: tempDir.appendingPathComponent(".gitignore").path, atomically: true, encoding: .utf8)
        try "tracked".write(toFile: tempDir.appendingPathComponent("file.txt").path, atomically: true, encoding: .utf8)
        try runGit(["add", "-A"])
        try runGit(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base"])

        let checkpoint = try checkpointer.snapshot(summary: "before")

        // An ignored file created *after* the checkpoint: cleanup must never
        // delete ignored paths (they were not in the snapshot's scope, and
        // `git clean -x`-style semantics are out of scope for agent undo).
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("build"),
            withIntermediateDirectories: true)
        try "build-artifact".write(
            toFile: tempDir.appendingPathComponent("build/ignored.txt").path,
            atomically: true, encoding: .utf8)

        try checkpointer.restore(checkpoint)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("build/ignored.txt").path),
            "ignored files must survive restore")
    }

    func testRestorePreservesStagedIndexState() throws {
        try runGit(["init", "-q"])
        try "one".write(toFile: tempDir.appendingPathComponent("f.txt").path, atomically: true, encoding: .utf8)
        try runGit(["add", "-A"])
        try runGit(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base"])

        // The user stages a modification before the agent runs.
        try "two".write(toFile: tempDir.appendingPathComponent("f.txt").path, atomically: true, encoding: .utf8)
        try runGit(["add", "f.txt"])

        let checkpoint = try checkpointer.snapshot(summary: "before")

        // The agent overwrites the file in the worktree.
        try "agent".write(toFile: tempDir.appendingPathComponent("f.txt").path, atomically: true, encoding: .utf8)

        try checkpointer.restore(checkpoint)

        // Worktree returns to the snapshot state…
        let content = try String(contentsOfFile: tempDir.appendingPathComponent("f.txt").path, encoding: .utf8)
        XCTAssertEqual(content, "two")
        // …and the user's staged change is still staged (M in column 1).
        let porcelain = try runGitOutput(["status", "--porcelain"])
        XCTAssertTrue(porcelain.contains("M  f.txt"), porcelain)
    }

    func testRestoreDoesNotFollowSymlinksDuringCleanup() throws {
        try runGit(["init", "-q"])
        try "tracked".write(toFile: tempDir.appendingPathComponent("file.txt").path, atomically: true, encoding: .utf8)
        try runGit(["add", "-A"])
        try runGit(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base"])

        let checkpoint = try checkpointer.snapshot(summary: "before")

        // An untracked symlink pointing outside the workspace, created after
        // the checkpoint. Cleanup must not follow it and must not delete the
        // outside file — the link itself is left alone too.
        let outside = tempDir.deletingLastPathComponent()
            .appendingPathComponent("lf-outside-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try "outside-secret".write(
            toFile: outside.appendingPathComponent("secret.txt").path,
            atomically: true, encoding: .utf8)
        let link = tempDir.appendingPathComponent("escape-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        try checkpointer.restore(checkpoint)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outside.appendingPathComponent("secret.txt").path),
            "cleanup must not delete through a symlink")
    }

    private func runGitOutput(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = tempDir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments) failed")
        return String(decoding: data, as: UTF8.self)
    }


}

final class CommandPolicyTests: XCTestCase {

    private var workspace: Workspace!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lf-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workspace = Workspace(root: dir)
    }

    private func evaluate(_ command: String) -> CommandPolicy.Decision {
        CommandPolicy().evaluate(command, workspace: workspace)
    }

    func testExactCommandBoundaries() {
        XCTAssertTrue(evaluate("ls").safeForAutoApproval)
        XCTAssertTrue(evaluate("ls -la").safeForAutoApproval)
        // `ls-malicious` is a different executable and must not match `ls`.
        XCTAssertFalse(evaluate("ls-malicious").safeForAutoApproval)
        XCTAssertFalse(evaluate("ls-malicious -la").safeForAutoApproval)
        XCTAssertTrue(evaluate("git status").safeForAutoApproval)
        XCTAssertFalse(evaluate("git-status").safeForAutoApproval)
    }

    func testShellOperatorsNeverAutoApproved() {
        for command in [
            "swift build; rm -rf ~",
            "swift build && rm -rf ~",
            "ls || true",
            "cat a.txt | grep x",
            "echo $(whoami)",
            "echo `whoami`",
            "echo hi > file.txt",
            "cat < file.txt",
            "echo hi >> file.txt",
            "swift build\nrm -rf ~",
            "sleep 5 &",
            "echo $PATH",
            "echo {1..5}",
            "git log --format=%h; echo x",
            "echo ~",
        ] {
            XCTAssertFalse(evaluate(command).safeForAutoApproval, command)
        }
    }

    func testOutsideWorkspacePathsRequireApproval() throws {
        let outside = workspace.root.deletingLastPathComponent()
            .appendingPathComponent("lf-outside-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        for command in [
            "cat /etc/passwd",
            "git status /etc",
            "ls ..",
            "cat ../secret.txt",
            "find . -name 'x' -exec rm {} \\;",
            "rg pattern \(outside.path)",
        ] {
            XCTAssertFalse(evaluate(command).safeForAutoApproval, command)
        }
    }

    func testInsideWorkspacePathsAreFine() throws {
        let dir = workspace.root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertTrue(evaluate("ls sub").safeForAutoApproval)
        XCTAssertTrue(evaluate("find sub -name '*.swift'").safeForAutoApproval)
        XCTAssertTrue(evaluate("rg pattern sub").safeForAutoApproval)
    }

    func testGitAndFindMutationsAreNeverAutoApproved() {
        XCTAssertFalse(evaluate("git reset --hard").safeForAutoApproval)
        XCTAssertFalse(evaluate("git push").safeForAutoApproval)
        XCTAssertFalse(evaluate("git config --global user.email a@b.c").safeForAutoApproval)
        XCTAssertFalse(evaluate("find . -delete").safeForAutoApproval)
        XCTAssertTrue(evaluate("git status").safeForAutoApproval)
        XCTAssertTrue(CommandPolicy().isPotentiallyMutating("git reset --hard"))
        XCTAssertTrue(CommandPolicy().isPotentiallyMutating("find . -delete"))
        XCTAssertFalse(CommandPolicy().isPotentiallyMutating("git status"))
        XCTAssertFalse(CommandPolicy().isPotentiallyMutating("find . -name '*.swift'"))
    }

    func testUnknownExecutableDenied() {
        XCTAssertFalse(evaluate("rm -rf .").safeForAutoApproval)
        XCTAssertFalse(evaluate("curl http://evil").safeForAutoApproval)
        XCTAssertFalse(evaluate("sudo rm -rf /").safeForAutoApproval)
    }

    func testEmptyCommandDenied() {
        XCTAssertFalse(evaluate("").safeForAutoApproval)
        XCTAssertFalse(evaluate("   ").safeForAutoApproval)
    }

    func testEnvironmentStripsGitOverrides() {
        let env = ShellRunner.sanitizedEnvironment()
        XCTAssertNil(env["GIT_DIR"])
        XCTAssertNil(env["GIT_WORK_TREE"])
        XCTAssertNil(env["GIT_INDEX_FILE"])
        XCTAssertNotNil(env["PATH"])
        XCTAssertFalse(env["USER", default: ""].isEmpty)
    }
}
