import Darwin
import Foundation

/// GGUF engine: runs llama.cpp's `llama-server` as a localhost child process
/// against the model's `.gguf` file and streams through the same
/// OpenAI-compatible client used for BYOK servers. This gives Beet Code the
/// full GGUF quantization universe (Q2–Q8, every architecture llama.cpp
/// supports) without vendoring the C++ runtime — llama.cpp already has
/// first-class Apple Silicon Metal support.
///
/// Lifecycle mirrors the MLX engine: admission goes through `MemoryAdvisor`,
/// generation is serialized on the pool's shared `GenerationGate`, and unload
/// terminates the server process.
final class GGUFEngine: LLMEngine, @unchecked Sendable {

    enum GGUFError: Error, LocalizedError, Equatable {
        case noGGUFFile
        case serverBinaryMissing(String)
        case serverFailedToStart(String)
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .noGGUFFile:
                return "No .gguf weight file found in the model directory."
            case .serverBinaryMissing(let hint):
                return hint
            case .serverFailedToStart(let detail):
                return "llama-server failed to start: \(detail)"
            case .notLoaded:
                return "No GGUF model is loaded."
            }
        }
    }

    /// Pure decisions — deterministic and unit-testable.
    enum Planner {

        /// The weight file to serve: the LARGEST `.gguf` in the directory
        /// (multi-file splits are rare; the biggest shard is the real model).
        static func selectGGUF(named fileNames: [String]) -> String? {
            let candidates = fileNames.filter { $0.lowercased().hasSuffix(".gguf") }
            return candidates.max { a, b in
                if a.count != b.count { return a.count < b.count }
                return quantizationLevel(a) < quantizationLevel(b)
            }
        }

        /// Numeric -q<digits> marker ("model-q8.gguf" -> 8); 0 when absent.
        private static func quantizationLevel(_ name: String) -> Int {
            let lower = name.lowercased()
            guard let dot = lower.range(of: ".gguf") else { return 0 }
            let stem = String(lower[lower.startIndex..<dot.lowerBound])
            guard let qRange = stem.range(of: "-q") else { return 0 }
            let rest = stem[qRange.upperBound...]
            let digits = rest.prefix(while: { $0.isNumber })
            guard digits.count > 0 else { return 0 }
            return Int(digits) ?? 0
        }

        /// Server launch arguments: loopback-only, no web UI, GPU-offloaded.
        /// `speculativeMTP` turns on draft-mtp speculative decoding — only
        /// pass true when the GGUF ships nextn tensors (GGUFMetadata
        /// .supportsDraftMTP); without them the flag is dead weight.
        /// n-max 2: deeper drafts waste verify passes on code (acceptance
        /// falls off fast past the second token).
        static func serverArguments(modelPath: String, port: Int, contextSize: Int = defaultContextSize,
                                    speculativeMTP: Bool = false) -> [String] {
            var args = [
                "--model", modelPath,
                "--host", "127.0.0.1",
                "--port", String(port),
                "--ctx-size", String(clampContextSize(contextSize)),
                "--n-gpu-layers", "99",
                "--alias", "beetcode",
                "--no-webui",
            ]
            if speculativeMTP {
                args += ["--spec-type", "draft-mtp", "--spec-draft-n-max", "2"]
            }
            return args
        }

        /// Context the server gets when the catalog says nothing.
        static let defaultContextSize = 8_192
        /// Sanity ceiling for any launch. The RAM-aware choice below is the
        /// real limit; this only bounds absurd catalog values (attention cost
        /// also grows quadratically past a few hundred K).
        static let maxContextSize = 262_144
        static let minContextSize = 4_096
        /// Conservative cap when the GGUF header can't be sniffed: KV cache
        /// scales linearly with ctx and MemoryAdvisor admission counts only
        /// the weights, so unknown models stay in proven-safe territory.
        static let fallbackContextSize = 32_768

        static func clampContextSize(_ requested: Int) -> Int {
            min(max(requested, minContextSize), maxContextSize)
        }

        /// KV cache bytes per token (f16 K+V): 2 caches × layers × kv-heads ×
        /// head-dim × 2 bytes. Needs the transformer dims from the GGUF
        /// header; MHA models (no kv-head count) use the full head count.
        static func kvBytesPerToken(metadata: GGUFMetadata) -> Int? {
            guard let layers = metadata.blockCount,
                  let embedding = metadata.embeddingLength,
                  let heads = metadata.attentionHeadCount, heads > 0
            else { return nil }
            let kvHeads = metadata.attentionHeadCountKV ?? heads
            let headDim = embedding / heads
            guard kvHeads > 0, headDim > 0 else { return nil }
            let (value, overflow) = (2 * layers * kvHeads).multipliedReportingOverflow(by: headDim * 2)
            return overflow ? nil : value
        }

        /// Largest context that fits the RAM budget honestly: the weights'
        /// projected footprint is spent first, what remains buys KV tokens.
        /// `availableBudget` is MemoryAdvisor's usable-minus-footprint figure.
        /// The floor is `minContextSize` — the load was already admitted on
        /// the weights, and 4 K of KV is small next to any 9 B file.
        static func chooseContextSize(
            requested: Int,
            kvBytesPerToken: Int?,
            projectedWeights: UInt64,
            availableBudget: UInt64
        ) -> Int {
            let requestedClamped = clampContextSize(requested)
            guard let kvPerToken = kvBytesPerToken, kvPerToken > 0 else {
                return min(requestedClamped, fallbackContextSize)
            }
            let kvBudget = availableBudget > projectedWeights ? availableBudget - projectedWeights : 0
            let affordable = kvBudget / UInt64(kvPerToken)
            let capped = min(UInt64(requestedClamped), affordable)
            return max(Int(capped), minContextSize)
        }

        /// Watchdog script: kill the server when the APP dies, even on a
        /// hard crash (SIGABRT skips applicationWillTerminate). macOS has no
        /// parent-death signal, so a tiny /bin/sh loop polls both PIDs; it
        /// exits as soon as either is gone, killing the server if the parent
        /// went first. Pure function for tests.
        static func janitorCommand(serverPID: Int32, parentPID: Int32) -> [String] {
            [
                "-c",
                """
                while kill -0 "$1" 2>/dev/null; do
                  kill -0 "$2" 2>/dev/null || { kill "$1" 2>/dev/null; break; }
                  sleep 3
                done
                """,
                "beetcode-gguf-janitor", String(serverPID), String(parentPID),
            ]
        }

        /// True when the health response body indicates the model is ready.
        static func isHealthy(responseBody: String) -> Bool {
            responseBody.contains("\"data\"") || responseBody.contains("beetcode")
        }
    }

    // MARK: State

    private let lock = NSLock()
    private var process: Process?
    /// Crash-safety watchdog for `process` (see Planner.janitorCommand).
    private var janitor: Process?
    private var port: Int = 0
    private var loadedID: String?
    /// The ctx-size the running server was actually launched with (RAM-fitted
    /// by the Planner — often smaller than the catalog window). The agent
    /// loop compacts against this, never the catalog number.
    private var launchedContextSize: Int?
    private var statsState = EngineStats()
    /// Stateless replay buffer — identical semantics to RemoteLLMEngine:
    /// llama-server slots are not guaranteed across requests, so every call
    /// sends the full conversation.
    private var accumulated: [ChatTurn] = []

    init() {}

    var loadedModelID: String? {
        get async { withLock { loadedID } }
    }

    var effectiveContextWindow: Int? {
        get async { withLock { launchedContextSize } }
    }

    var stats: EngineStats {
        get async { withLock { statsState } }
    }

    // MARK: Lifecycle

    func load(directory: URL, modelID: String, diskBytes: Int64) async throws {
        try await load(directory: directory, modelID: modelID, diskBytes: diskBytes, contextSize: nil)
    }

    /// `contextSize` comes from the catalog entry; the Planner fits it to the
    /// RAM budget (KV cache) before launch. nil uses the 8 K default.
    func load(directory: URL, modelID: String, diskBytes: Int64, contextSize: Int?) async throws {
        // Defensive: loading while resident must replace the old server, not
        // orphan it (the pool normally prevents this; the unpooled path and
        // tests don't).
        if withLock({ process != nil }) {
            await unload()
        }
        // Same admission authority as every other engine: the GGUF weights
        // inflate the child's footprint just like MLX's mmap does.
        try MemoryAdvisor.admitLoad(diskBytes: diskBytes)

        let fileNames = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard let ggufName = Planner.selectGGUF(named: fileNames) else {
            throw GGUFError.noGGUFFile
        }
        let modelPath = directory.appendingPathComponent(ggufName).path
        let binary = try Self.resolveServerBinary()

        // RAM-honest context sizing: sniff the transformer dims from the GGUF
        // header and buy as many KV tokens as the budget left over after the
        // weights affords. Unsniffable headers keep the conservative 32 K cap.
        let sniffed = GGUFMetadata.read(from: URL(fileURLWithPath: modelPath))
        let chosenContext = Planner.chooseContextSize(
            requested: contextSize ?? Planner.defaultContextSize,
            kvBytesPerToken: sniffed.flatMap(Planner.kvBytesPerToken),
            projectedWeights: MemoryAdvisor.projectedFootprint(diskBytes: diskBytes),
            availableBudget: MemoryAdvisor.availableBudget)

        // MTP speculative decoding: when the GGUF ships nextn tensors (Qwen3.5
        // "MTP" builds like Qwythos), prefer a draft-mtp launch — llama.cpp
        // reports ~1.3–1.4× decode on this hybrid arch. A binary too old to
        // know the flag exits at arg-parse, which fails the health wait in
        // ~250 ms; we then retry once without it rather than failing the load.
        let wantsMTP = sniffed?.supportsDraftMTP == true
        var attempt = try await launchServer(
            binary: binary, modelPath: modelPath,
            contextSize: chosenContext, speculativeMTP: wantsMTP)
        if attempt == nil, wantsMTP {
            Log.engine.warning("llama-server rejected draft-mtp; retrying without speculative decoding")
            attempt = try await launchServer(
                binary: binary, modelPath: modelPath,
                contextSize: chosenContext, speculativeMTP: false)
        }
        guard let (child, watchdog, serverPort) = attempt else {
            throw GGUFError.serverFailedToStart("no response from llama-server within 120s")
        }

        withLock {
            self.process = child
            self.janitor = watchdog
            self.port = serverPort
            self.loadedID = modelID
            self.launchedContextSize = chosenContext
            self.statsState = EngineStats()
            self.accumulated.removeAll()
        }
        child.terminationHandler = { [weak self] _ in
            ChildProcessRegistry.unregister(child)
            guard let self else { return }
            self.withLock {
                self.process = nil
                self.loadedID = nil
            }
        }
        Log.engine.info("GGUF server ready: \(modelID, privacy: .public) on port \(serverPort)")
    }

    func unload() async {
        let (child, watchdog) = withLock { () -> (Process?, Process?) in
            let p = process
            let j = janitor
            process = nil
            janitor = nil
            port = 0
            loadedID = nil
            launchedContextSize = nil
            statsState = EngineStats()
            accumulated.removeAll()
            return (p, j)
        }
        // The watchdog exits on its own once the server is gone; terminate it
        // explicitly so unload never waits on its 3 s poll.
        if let watchdog, watchdog.isRunning { watchdog.terminate() }
        guard let child, child.isRunning else { return }
        child.terminate()
        // Graceful → forced: never leak a model server.
        let deadline = Date().addingTimeInterval(3)
        while child.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if child.isRunning {
            kill(child.processIdentifier, SIGKILL)
        }
    }

    func reset() async {
        withLock { accumulated.removeAll() }
    }

    // MARK: Generation

    func stream(
        adding turns: [ChatTurn],
        maxTokens: Int?,
        temperature: Double?
    ) -> AsyncThrowingStream<String, Error> {
        let allTurns = withLock { () -> [ChatTurn] in
            accumulated.append(contentsOf: turns)
            return accumulated
        }
        let baseURL = withLock { URL(string: "http://127.0.0.1:\(port)/v1")! }
        let inner = RemoteLLMClient.streamOpenAICompatible(
            provider: .custom,
            baseURL: baseURL,
            apiKey: "",
            model: "beetcode",
            turns: allTurns,
            temperature: temperature ?? 0.6,
            maxTokens: maxTokens)

        // Relay while measuring throughput (same stats contract as the other
        // engines).
        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                var tokens = 0
                let started = Date()
                do {
                    for try await chunk in inner {
                        if Task.isCancelled { break }
                        continuation.yield(chunk)
                        tokens += 1
                    }
                    let elapsed = Date().timeIntervalSince(started)
                    if elapsed > 0.2 {
                        let newStats = EngineStats(
                            tokensPerSecond: Double(tokens) / elapsed,
                            generatedTokens: tokens)
                        // NSLock lives inside the synchronous withLock
                        // helper — never raw lock/unlock in async contexts.
                        if let self {
                            self.withLock { self.statsState = newStats }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func streamReplay(_ turns: [ChatTurn], maxTokens: Int?, temperature: Double?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let saved = self.withLock { () -> [ChatTurn] in
                    let old = self.accumulated
                    self.accumulated = []
                    return old
                }
                defer { self.withLock { self.accumulated = saved } }
                let inner = self.stream(adding: turns, maxTokens: maxTokens, temperature: temperature)
                do {
                    for try await chunk in inner {
                        if Task.isCancelled { break }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cancelGeneration() async {
        // In-flight HTTP generation stops when the caller cancels the stream;
        // nothing queued exists on the local server.
    }

    @discardableResult
    func dumpIfResident() async -> Bool {
        let wasLoaded = withLock { loadedID != nil }
        if wasLoaded {
            await unload()
            Log.memory.warning("GGUF model dumped by memory pressure")
        }
        return wasLoaded
    }

    // MARK: Helpers

    /// Spawns llama-server (plus its crash watchdog) and waits for the health
    /// endpoint. Returns nil when the server never answers — the caller may
    /// retry with different arguments. Spawn failures throw immediately (no
    /// retry would fix a bad binary path).
    private func launchServer(
        binary: URL, modelPath: String,
        contextSize: Int, speculativeMTP: Bool
    ) async throws -> (child: Process, watchdog: Process, port: Int)? {
        let serverPort = Self.freePort()
        let child = Process()
        child.executableURL = binary
        child.arguments = Planner.serverArguments(
            modelPath: modelPath, port: serverPort,
            contextSize: contextSize, speculativeMTP: speculativeMTP)
        child.environment = ShellRunner.sanitizedEnvironment()
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice

        do {
            try child.run()
        } catch {
            throw GGUFError.serverFailedToStart(error.localizedDescription)
        }
        // Quit-safety net: if the app exits without an unload (window close,
        // ⌘Q with a model resident), the app delegate SIGTERMs registered
        // children — otherwise a multi-GB llama-server outlives the app.
        ChildProcessRegistry.register(child)
        // Crash-safety net: SIGABRT skips willTerminate, so a watchdog shell
        // kills the server if the app process disappears (see Planner).
        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = Planner.janitorCommand(
            serverPID: child.processIdentifier,
            parentPID: ProcessInfo.processInfo.processIdentifier)
        watchdog.standardOutput = FileHandle.nullDevice
        watchdog.standardError = FileHandle.nullDevice
        try? watchdog.run()

        // Wait for the HTTP health endpoint (model page-in can take a while).
        let healthy = await waitForHealthy(port: serverPort, process: child, timeout: 120)
        guard healthy else {
            child.terminate()
            watchdog.terminate()
            ChildProcessRegistry.unregister(child)
            return nil
        }
        return (child, watchdog, serverPort)
    }

    /// Polls the server's model endpoint until it answers or the deadline /
    /// process death arrives.
    private func waitForHealthy(port: Int, process: Process, timeout: TimeInterval) async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        let session = URLSession(configuration: .ephemeral)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning { return false }
            if let (_, response) = try? await session.data(from: url),
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                session.finishTasksAndInvalidate()
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        session.finishTasksAndInvalidate()
        return false
    }

    /// Locates `llama-server`: PATH first (Homebrew installs link it), then
    /// the canonical Homebrew prefix. Absence is reported with install
    /// guidance instead of a cryptic spawn error.
    nonisolated static func resolveServerBinary() throws -> URL {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("llama-server")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        let homebrew = URL(fileURLWithPath: "/opt/homebrew/bin/llama-server")
        if FileManager.default.isExecutableFile(atPath: homebrew.path) {
            return homebrew
        }
        throw GGUFError.serverBinaryMissing(
            "llama-server not found. Install llama.cpp (brew install llama.cpp) to run GGUF models.")
    }

    /// An ephemeral loopback port: bind port 0, read the assignment, close.
    nonisolated static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 8901 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return 8901 }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &length)
            }
        }
        guard nameResult == 0 else { return 8901 }
        return Int(UInt16(bigEndian: actual.sin_port))
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
