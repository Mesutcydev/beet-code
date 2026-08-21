import Darwin
import Foundation

/// Typed outcome of a shell command so the executor can mark failures from
/// facts (exit code, timeout) instead of string-sniffing.
struct CommandResult: Sendable, Equatable {
    var exitCode: Int32
    var timedOut: Bool
    var output: String

    var failed: Bool { exitCode != 0 || timedOut }
}

enum ShellRunnerError: Error, LocalizedError {
    case spawnFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let code):
            return "Failed to launch the shell (posix_spawn error \(code))."
        }
    }
}

/// Runs `/bin/zsh -c <command>` in a **fresh process group** so the entire
/// process tree can be killed on timeout or cancellation — child processes
/// cannot survive the tool call. Uses posix_spawn (not Foundation Process)
/// because POSIX_SPAWN_SETPGROUP must be set before exec, which `Process`
/// cannot express.
enum ShellRunner {

    /// Environment inherited by shell commands. Deliberately minimal, and
    /// stripped of Git override variables: ambient GIT_DIR/GIT_WORK_TREE/
    /// GIT_INDEX_FILE (e.g. exported by a terminal the app was launched from)
    /// must never redirect git commands run by the agent.
    static func sanitizedEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let gitOverrides: Set<String> = [
            "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
            "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            "GIT_COMMON_DIR", "GIT_NAMESPACE", "GIT_PREFIX", "GIT_SHALLOW_FILE",
        ]
        return [
            "PATH": inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
            "HOME": inherited["HOME"] ?? NSHomeDirectory(),
            "TMPDIR": inherited["TMPDIR"] ?? NSTemporaryDirectory(),
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
        ].filter { key, _ in !gitOverrides.contains(key) }
    }

    /// Runs the command until exit or timeout, then returns a typed result.
    /// On timeout or when `cancelCheck()` returns true, the entire process
    /// group receives SIGKILL.
    static func run(
        command: String,
        workingDirectory: URL,
        environment: [String: String] = sanitizedEnvironment(),
        timeout: TimeInterval,
        maxOutputBytes: Int = 4 * 1024 * 1024,
        cancelCheck: @escaping @Sendable () -> Bool = { false }
    ) throws -> CommandResult {
        try runProcess(
            executable: "/bin/zsh",
            arguments: ["-c", command],
            workingDirectory: workingDirectory,
            environment: environment,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes,
            cancelCheck: cancelCheck)
    }

    /// Runs ANY executable with a hard timeout — the single time-bounded
    /// process runner for git, rg, argent, and simctl. Same semantics as
    /// `run`: process group, sanitized environment, group SIGKILL on
    /// timeout/cancel, typed result.
    static func runProcess(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String] = sanitizedEnvironment(),
        timeout: TimeInterval,
        maxOutputBytes: Int = 4 * 1024 * 1024,
        cancelCheck: @escaping @Sendable () -> Bool = { false }
    ) throws -> CommandResult {
        let pipe = Pipe()
        let writeFD = pipe.fileHandleForWriting.fileDescriptor

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, writeFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, writeFD, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, writeFD)
        // posix_spawn does NOT inherit the caller's working directory — it
        // must be set explicitly or the child starts in the parent's cwd.
        _ = workingDirectory.path.withCString { path in
            // The `_np` spelling is available in the macOS 15 SDK used by
            // CI; newer SDKs may also expose the non-suffixed alias.
            posix_spawn_file_actions_addchdir_np(&fileActions, path)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)  // child becomes group leader
        defer { posix_spawnattr_destroy(&attributes) }

        // argv[0] must be the program name: git (and most CLIs) parse
        // arguments starting at argv[1], treating argv[0] as the
        // invocation name.
        let invocation = [URL(fileURLWithPath: executable).lastPathComponent] + arguments
        let argv: [UnsafeMutablePointer<CChar>?] = invocation.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let environmentPairs = environment.map { "\($0.key)=\($0.value)" }
        let envp: [UnsafeMutablePointer<CChar>?] = environmentPairs.map { strdup($0) } + [nil]
        defer { envp.forEach { free($0) } }

        var pid: pid_t = 0
        let spawnResult = executable.withCString { executableCString in
            posix_spawn(
                &pid,
                executableCString,
                &fileActions,
                &attributes,
                argv,
                envp)
        }
        guard spawnResult == 0 else {
            throw ShellRunnerError.spawnFailed(spawnResult)
        }

        // Parent side: close the write end, drain the read end, enforce the
        // deadline, and kill the group on timeout/cancel.
        try? pipe.fileHandleForWriting.close()

        let collected = OutputBuffer(maxBytes: maxOutputBytes)
        let readerDone = DispatchSemaphore(value: 0)
        // Read through the PIPE'S OWN handle: wrapping readFD in a second
        // FileHandle(closeOnDealloc: true) created two owners for one
        // descriptor — whoever deallocated last closed an already-closed
        // (and on modern macOS, GUARDED) fd, which is an EXC_GUARD crash,
        // not a benign EBADF. Single owner, no double close.
        let readHandle = pipe.fileHandleForReading
        // .userInitiated, NOT .utility: the waiting thread (runProcess's
        // caller) runs at user-initiated QoS for interactive agent commands.
        // Blocking a user-initiated thread on a utility reader is a QoS
        // inversion — the Thread Performance Checker reports it and its
        // inline symbolication of the report wedged XCTest's main run loop
        // (deterministic hang in testCancellationDuringToolExecution).
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let data = readHandle.availableData
                if data.isEmpty { break }
                collected.append(data)
            }
            readerDone.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        var reaped = false
        var timedOut = false

        while true {
            if cancelCheck() {
                timedOut = true
                break
            }
            if Date() >= deadline {
                timedOut = true
                break
            }
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid {
                reaped = true
                break
            }
            if waited == -1 {
                break
            }
            usleep(20_000)
        }

        if !reaped {
            kill(-pid, SIGKILL)  // the whole process group
            _ = waitpid(pid, &status, 0)
        }

        _ = readerDone.wait(timeout: .now() + 2)
        let output = collected.string
        let exitCode = exitCode(from: status)

        return CommandResult(
            exitCode: timedOut ? -1 : exitCode,
            timedOut: timedOut,
            output: output)
    }

    /// Starts `/bin/zsh -c` in a new process group and returns immediately.
    /// stdout/stderr go to `logURL`. Caller owns the pid and must `killGroup`.
    static func spawnDetached(
        command: String,
        workingDirectory: URL,
        logURL: URL,
        environment: [String: String] = sanitizedEnvironment()
    ) throws -> pid_t {
        let logFD = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard logFD >= 0 else { throw ShellRunnerError.spawnFailed(errno) }
        defer { close(logFD) }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, logFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, logFD, STDERR_FILENO)
        _ = workingDirectory.path.withCString { path in
            posix_spawn_file_actions_addchdir_np(&fileActions, path)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        defer { posix_spawnattr_destroy(&attributes) }

        let invocation = ["zsh", "-c", command]
        let argv: [UnsafeMutablePointer<CChar>?] = invocation.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let environmentPairs = environment.map { "\($0.key)=\($0.value)" }
        let envp: [UnsafeMutablePointer<CChar>?] = environmentPairs.map { strdup($0) } + [nil]
        defer { envp.forEach { free($0) } }

        var pid: pid_t = 0
        let spawnResult = "/bin/zsh".withCString { executableCString in
            posix_spawn(&pid, executableCString, &fileActions, &attributes, argv, envp)
        }
        guard spawnResult == 0 else { throw ShellRunnerError.spawnFailed(spawnResult) }
        return pid
    }

    static func killGroup(_ pid: pid_t, waitSeconds: TimeInterval = 2) {
        kill(-pid, SIGTERM)
        let deadline = Date().addingTimeInterval(waitSeconds)
        var status: Int32 = 0
        while Date() < deadline {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid || waited == -1 { return }
            usleep(20_000)
        }
        kill(-pid, SIGKILL)
        _ = waitpid(pid, &status, 0)
    }

    private static func exitCode(from status: Int32) -> Int32 {
        // sys/wait.h macros are not visible to Swift; decode manually.
        let signalBits = status & 0x7f
        if signalBits == 0 {
            // WIFEXITED: normal exit → WEXITSTATUS.
            return (status >> 8) & 0xff
        }
        if signalBits != 0x7f {
            // WIFSIGNALED: killed by a signal → 128 + WTERMSIG.
            return Int32(128 + signalBits)
        }
        return -1
    }
}

/// Thread-safe bounded byte collector for command output.
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int

    init(maxBytes: Int) {
        self.limit = maxBytes
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard data.count < limit else { return }
        data.append(chunk.prefix(limit - data.count))
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
