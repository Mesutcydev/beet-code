import XCTest
@testable import BeetCode

/// ShellRunner fd-ownership regression tests.
///
/// Historical bug: the pipe's read fd had TWO owners (the Pipe's own
/// FileHandle plus a second FileHandle(closeOnDealloc: true)). The second
/// dealloc closed an fd number the test host had already reused as a
/// GUARDED fd → EXC_GUARD, killing the whole process mid-suite. These
/// tests exist so a future fd-ownership regression crashes the suite
/// loudly at the scene instead of surfacing as a random crash report.
final class ShellRunnerTests: XCTestCase {

    private var workspace: TempWorkspace!

    override func setUpWithError() throws {
        workspace = TempWorkspace()
    }

    override func tearDownWithError() throws {
        workspace = nil
    }

    /// Rapid SEQUENTIAL spawns: every run must return its own correct
    /// output and exit code, and no fd may leak across iterations (a leak
    /// would exhaust descriptors or double-close a reused one).
    func testRapidSequentialSpawnsReturnCorrectResults() throws {
        for i in 0..<120 {
            let result = try ShellRunner.run(
                command: "echo iteration-\(i)",
                workingDirectory: workspace.url,
                timeout: 10)
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertFalse(result.timedOut)
            XCTAssertEqual(
                result.output.trimmingCharacters(in: .whitespacesAndNewlines),
                "iteration-\(i)")
        }
    }

    /// CONCURRENT spawns: the old double-close needed an fd-number reuse to
    /// crash, and reuse races need concurrency to reproduce reliably.
    /// concurrentPerform interleaves spawns with the test host's own fd
    /// traffic; any ownership regression shows up here as EXC_GUARD.
    func testConcurrentSpawnsNeverDoubleCloseFDs() throws {
        let iterations = 150
        let failures = ManagedCounter()
        let directory = workspace.url
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            do {
                let result = try ShellRunner.run(
                    command: "printf 'concurrent-%d' \(i)",
                    workingDirectory: directory,
                    timeout: 15)
                let ok = result.exitCode == 0
                    && !result.timedOut
                    && result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "concurrent-\(i)"
                if !ok { failures.increment() }
            } catch {
                failures.increment()
            }
        }
        XCTAssertEqual(failures.value, 0, "concurrent spawns must all succeed with correct output")
    }

    /// Direct runProcess (the git/simctl path — the exact stack from the
    /// crash report: GitCheckpointer → runProcess) under repetition.
    func testRunProcessRepeatedGitLikeCalls() throws {
        for _ in 0..<60 {
            let result = try ShellRunner.runProcess(
                executable: "/usr/bin/true",
                arguments: [],
                workingDirectory: workspace.url,
                timeout: 10)
            XCTAssertEqual(result.exitCode, 0)
        }
    }

    /// Timeout path: the process group is SIGKILLed, output drained, and the
    /// runner still returns a typed result instead of hanging or crashing.
    func testTimeoutKillsProcessGroupAndReturns() throws {
        let started = Date()
        let result = try ShellRunner.run(
            command: "sleep 60",
            workingDirectory: workspace.url,
            timeout: 1)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exitCode, -1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "timeout path must not hang")
    }

    /// A nonexistent executable throws spawnFailed — never crashes, never
    /// returns a fake success.
    func testSpawnFailureThrows() {
        XCTAssertThrowsError(try ShellRunner.runProcess(
            executable: "/nonexistent/definitely-not-a-real-binary",
            arguments: [],
            workingDirectory: workspace.url,
            timeout: 5)) { error in
            guard case ShellRunnerError.spawnFailed = error else {
                XCTFail("expected spawnFailed, got \(error)")
                return
            }
        }
    }
}

/// Minimal thread-safe counter for concurrentPerform assertions.
private final class ManagedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
