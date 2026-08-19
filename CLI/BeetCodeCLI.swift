import Foundation

// BeetCode headless harness. Exercises the same Core subsystems the app UI
// uses — downloads, admission, engine — with zero UI:
//
//   lf download <catalog-id>     download a catalog model (resumable)
//   lf generate <catalog-id> "prompt"   load + stream a one-shot generation
//   lf serve [--port N] [--model <catalog-id>]   OpenAI-compatible local API server
//   lf status                     memory / thermal / catalog verdicts

@main
struct CLI {
    static func main() async {
        let arguments = CommandLine.arguments.dropFirst()
        guard let subcommand = arguments.first else {
            print("usage: lf <download|generate|serve|status> [args]")
            return
        }
        switch subcommand {
        case "download":
            guard let id = arguments.dropFirst().first else {
                fallbackUsage()
                return
            }
            await download(modelID: id)
        case "generate":
            let rest = Array(arguments.dropFirst())
            guard let id = rest.first, let prompt = rest.dropFirst().first else {
                fallbackUsage()
                return
            }
            await generate(modelID: id, prompt: prompt)
        case "serve":
            let rest = Array(arguments.dropFirst())
            var port = 1234
            var modelID: String?
            var i = 0
            while i < rest.count {
                switch rest[i] {
                case "--port":
                    if i + 1 < rest.count, let parsed = Int(rest[i + 1]) { port = parsed }
                    i += 2
                case "--model":
                    if i + 1 < rest.count { modelID = rest[i + 1] }
                    i += 2
                default:
                    i += 1
                }
            }
            await serve(port: port, modelID: modelID)
        case "status":
            status()
        case "intel":
            // Workspace intelligence CLI (Phase 22): index / overview /
            // context / search / impact / verify / handoff / serve-mcp.
            let code = await IntelligenceCLI.run(arguments: Array(arguments.dropFirst()))
            if code != 0 { FileHandle.standardError.write(Data("exit \(code)\n".utf8)) }
        default:
            fallbackUsage()
        }
    }

    static func fallbackUsage() {
        print("usage: lf download <catalog-id> | lf generate <catalog-id> <prompt> | lf serve [--port 1234] [--model <catalog-id>] | lf status | lf intel <index|overview|context|search|impact|verify|handoff|serve-mcp>")
    }

    // MARK: Subcommands

    /// Runs the OpenAI-compatible local API server headless: loads a model
    /// (when requested), binds 127.0.0.1:<port>, serves until Ctrl-C. This is
    /// how external tools (Codex --oss, Claude Code, Aider) consume a
    /// BeetCode model without the app UI.
    static func serve(port: Int, modelID: String?) async {
        let engine = MLXEngine()

        if let modelID {
            guard let model = ModelCatalog.model(id: modelID) else {
                print("unknown model '\(modelID)' — known: \(ModelCatalog.all.map(\.id).joined(separator: ", "))")
                return
            }
            let directory = URL(fileURLWithPath: "beetcode-models/\(model.id)")
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path) else {
                print("model not downloaded — run: lf download \(modelID)")
                return
            }
            let diskBytes = Self.directorySize(directory) ?? model.diskBytes
            do {
                try MemoryAdvisor.admitLoad(diskBytes: diskBytes)
                try await engine.load(directory: directory, modelID: model.id, diskBytes: diskBytes)
                print("✓ loaded \(model.id)")
            } catch {
                print("error: \(error.localizedDescription)")
                return
            }
        } else {
            print("note: no --model given — /v1/chat/completions will fail until a model is loaded.")
        }

        let server = LocalAPIServer(engine: engine)
        do {
            try await server.start(.init(port: port, bindIPv6: false, modelIDOverride: modelID))
        } catch {
            print("error: \(error.localizedDescription)")
            return
        }
        let base = "http://127.0.0.1:\(await server.actualPort)"
        print("""
        BeetCode API server running (loopback only).
          base URL:  \(base)
          models:    GET  \(base)/v1/models
          chat:      POST \(base)/v1/chat/completions
          health:    GET  \(base)/health
        Ctrl-C to stop.
        """)
        // Block forever; SIGINT (Ctrl-C) terminates the process directly.
        // (A never-resumed continuation would leak — sleeping in a loop is
        // the honest async equivalent of "run until killed".)
        while true {
            try? await Task.sleep(for: .seconds(3_600))
        }
    }

    static func download(modelID: String) async {
        guard let model = ModelCatalog.model(id: modelID) else {
            print("unknown model '\(modelID)' — known: \(ModelCatalog.all.map(\.id).joined(separator: ", "))")
            return
        }
        let directory = URL(fileURLWithPath: "beetcode-models").appendingPathComponent(model.id)
        let hub = HFHubClient(tokenProvider: { HFTokenStore.currentToken() })

        do {
            let files = try await hub.listModelFiles(repo: model.repo)
            let total = files.reduce(Int64(0)) { $0 + $1.sizeBytes }
            print("\(files.count) files, \(ByteFormatter.bytes(total)) total → \(directory.path)")

            for file in files {
                let destination = directory.appendingPathComponent(file.path)
                let existing = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil
                if existing == file.sizeBytes {
                    print("✓ \(file.path) already complete")
                    continue
                }
                let downloader = SmartFileDownloader(
                    hub: hub, file: file,
                    sourceURL: hub.resolveURL(repo: model.repo, path: file.path),
                    destination: destination)
                let result: Result<URL, SmartFileDownloader.DownloadError> = await withCheckedContinuation { cont in
                    downloader.start(
                        progress: { done, total in
                            Self.printProgress(label: file.path, done: done, total: total)
                        },
                        completion: { cont.resume(returning: $0) })
                }
                switch result {
                case .success: print("\n✓ \(file.path)")
                case .failure(let error): print("\n✗ \(file.path): \(error.localizedDescription)")
                }
            }
            print("done")
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }

    static func generate(modelID: String, prompt: String) async {
        guard let model = ModelCatalog.model(id: modelID) else {
            print("unknown model '\(modelID)'")
            return
        }
        let directory = URL(fileURLWithPath: "beetcode-models/\(model.id)")
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path) else {
            print("model not downloaded — run: lf download \(modelID)")
            return
        }

        let diskBytes = Self.directorySize(directory) ?? model.diskBytes
        do {
            try MemoryAdvisor.admitLoad(diskBytes: diskBytes)
        } catch {
            print("admission refused: \(error.localizedDescription)")
            return
        }

        let engine = MLXEngine()
        do {
            let started = Date()
            try await engine.load(directory: directory, modelID: model.id, diskBytes: diskBytes)
            print(String(format: "loaded in %.1fs", Date().timeIntervalSince(started)))

            let stream = engine.stream(
                adding: [
                    ChatTurn(role: .system, content: "You are a helpful assistant. Answer in one short sentence."),
                    ChatTurn(role: .user, content: prompt),
                ],
                maxTokens: 120,
                temperature: 0.6)
            print("— generation —")
            for try await chunk in stream {
                print(chunk, terminator: "")
                fflush(stdout)
            }
            print()
            let stats = await engine.stats
            if let tps = stats.tokensPerSecond {
                print(String(format: "— %.1f tokens/s —", tps))
            }
            await engine.unload()
        } catch {
            print("engine error: \(error.localizedDescription)")
        }
    }

    static func status() {
        let budget = MemoryAdvisor.budget(diskBytes: 0)
        print("physical:      \(ByteFormatter.bytes(budget.physicalTotal))")
        print("usable budget: \(ByteFormatter.bytes(budget.usableBudget)) (30% OS reserve)")
        print("footprint:     \(ByteFormatter.bytes(budget.currentFootprint))")
        print("thermal:       \(ProcessInfo.processInfo.thermalState.description)")
        for model in ModelCatalog.all {
            let verdict = MemoryAdvisor.budget(diskBytes: model.diskBytes).verdict
            print("\(model.id): \(verdict.label) — \(model.subtitle)")
        }
    }

    static func printProgress(label: String, done: Int64, total: Int64) {
        let fraction = total > 0 ? Double(done) / Double(total) * 100 : 0
        print(String(format: "\r  %@: %.1f%% (%@ / %@)", label, fraction, ByteFormatter.bytes(done), ByteFormatter.bytes(total)), terminator: "")
        fflush(stdout)
    }

    static func directorySize(_ url: URL) -> Int64? {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return nil }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

extension MemoryAdvisor.Verdict {
    var label: String {
        switch self {
        case .fits: "fits"
        case .marginal: "marginal"
        case .wontFit: "won't fit"
        }
    }
}
