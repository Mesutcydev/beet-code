import Foundation

/// The first — and deliberately only — framework adapter (spec Phase 14:
/// "make the first adapter genuinely useful; do not create dozens of shallow
/// adapters"). Covers the app's primary ecosystem, Apple platform Swift:
///
/// Swift source (via ParserCore output + raw content):
///   - `struct X: View` / `: App`                 → Screen
///   - `: ObservableObject` / `@Observable`       → Provider (+ @Published list)
///   - `@Model` / `: VersionedSchema` (SwiftData) → DatabaseModel
///   - `: SchemaMigrationPlan`                    → Migration
///   - `: Tool` / `AgentTool` / `LLMTool`         → Tool
///   - URL string literals                        → ExternalService / Endpoint
///   - `ProcessInfo … environment["KEY"]`         → SecretReference
///   - `BGTaskScheduler` identifiers              → BackgroundTask
///
/// Apple project files (content-only, no language parser):
///   - Info.plist `NS*UsageDescription`           → Permission
///   - *.entitlements `com.apple.*` keys          → Entitlement
///   - project.yml / Package.swift targets        → BuildTarget
///
/// Everything produced here is syntactic and labeled as such; an entity is a
/// detection, not a claim of semantic truth.
struct SwiftUIFrameworkAdapter: FrameworkAdapter {

    let adapterID = "swiftui-framework-adapter"

    func detect(file: SourceFile, parsed: ParsedFile?) -> [SemanticEntity] {
        var entities: [SemanticEntity] = []
        let ext = (file.path as NSString).pathExtension.lowercased()
        let baseName = (file.path as NSString).lastPathComponent

        if let parsed, parsed.language == "swift", baseName != "Package.swift" {
            entities += detectSwiftEntities(file: file, parsed: parsed)
        }
        if ext == "entitlements" {
            entities += detectEntitlements(file: file)
        }
        if baseName == "Info.plist" {
            entities += detectPermissions(file: file)
        }
        if baseName == "project.yml" {
            entities += detectProjectYMLTargets(file: file)
        }
        if baseName == "Package.swift" {
            entities += detectPackageTargets(file: file)
        }
        return entities
    }

    // MARK: Swift source entities

    private func detectSwiftEntities(file: SourceFile, parsed: ParsedFile) -> [SemanticEntity] {
        var entities: [SemanticEntity] = []
        let lines = file.content.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        let typeKinds: Set<SymbolKind> = [.class, .struct, .enum, .actor, .extension]
        for symbol in parsed.symbols where typeKinds.contains(symbol.kind) {
            let rels = Set(symbol.typeRelationships)
            let attributeLine = symbol.range.startLine >= 2 ? lines[symbol.range.startLine - 2] : ""

            // Screens: SwiftUI views and app entry points.
            if rels.contains("View") || rels.contains("App") {
                var attributes: [String: String] = [
                    "role": rels.contains("App") ? "app" : "view",
                ]
                let deps = environmentDependencies(lines: lines, range: symbol.range)
                if !deps.isEmpty { attributes["environmentDependencies"] = deps.joined(separator: ",") }
                entities.append(SemanticEntity(
                    kind: .screen, name: symbol.name, path: file.path,
                    line: symbol.range.startLine, symbolID: symbol.symbolID,
                    attributes: attributes, source: adapterID))
            }

            // Providers: observable state holders (both eras of the API).
            if rels.contains("ObservableObject") || attributeLine.contains("@Observable") {
                var attributes: [String: String] = [
                    "stateModel": rels.contains("ObservableObject") ? "observableObject" : "observableMacro",
                ]
                let published = publishedProperties(lines: lines, range: symbol.range)
                if !published.isEmpty { attributes["publishedProperties"] = published.joined(separator: ",") }
                entities.append(SemanticEntity(
                    kind: .provider, name: symbol.name, path: file.path,
                    line: symbol.range.startLine, symbolID: symbol.symbolID,
                    attributes: attributes, source: adapterID))
            }

            // SwiftData models and schema machinery.
            if attributeLine.contains("@Model") || rels.contains("VersionedSchema") {
                entities.append(SemanticEntity(
                    kind: .databaseModel, name: symbol.name, path: file.path,
                    line: symbol.range.startLine, symbolID: symbol.symbolID,
                    attributes: ["persistence": "swiftData"], source: adapterID))
            }
            if rels.contains("SchemaMigrationPlan") {
                entities.append(SemanticEntity(
                    kind: .migration, name: symbol.name, path: file.path,
                    line: symbol.range.startLine, symbolID: symbol.symbolID,
                    attributes: ["persistence": "swiftData"], source: adapterID))
            }

            // Agent tools (this app's own extension point).
            if !rels.isDisjoint(with: ["Tool", "AgentTool", "LLMTool"]) {
                entities.append(SemanticEntity(
                    kind: .tool, name: symbol.name, path: file.path,
                    line: symbol.range.startLine, symbolID: symbol.symbolID,
                    source: adapterID))
            }
        }

        entities += detectServiceEndpoints(file: file, lines: lines)
        entities += detectSecretReferences(file: file, lines: lines)
        entities += detectBackgroundTasks(file: file, lines: lines)
        return entities
    }

    /// `@EnvironmentObject` / `@Environment(\.key)` inside a type's range —
    /// a screen's injected dependencies, genuinely useful context.
    private func environmentDependencies(lines: [String], range: SourceRange) -> [String] {
        var deps: [String] = []
        let slice = lines[max(0, range.startLine - 1)..<min(lines.count, range.endLine)]
        for line in slice {
            if let match = line.range(
                of: #"@EnvironmentObject\s+(?:private\s+)?var\s+([A-Za-z_][A-Za-z0-9_]*)"#,
                options: .regularExpression) {
                let name = String(line[match])
                if let varRange = name.range(of: #"var\s+([A-Za-z_][A-Za-z0-9_]*)$"#,
                                             options: .regularExpression) {
                    deps.append(String(name[varRange].dropFirst(4)))
                }
            }
            if let match = line.range(of: #"@Environment\(\\\.([A-Za-z_][A-Za-z0-9_.]*)\)"#,
                                      options: .regularExpression) {
                let text = String(line[match])
                let inner = text.dropFirst("@Environment(\\.".count).dropLast(1)
                deps.append(String(inner))
            }
        }
        return deps
    }

    private func publishedProperties(lines: [String], range: SourceRange) -> [String] {
        var names: [String] = []
        let slice = lines[max(0, range.startLine - 1)..<min(lines.count, range.endLine)]
        for line in slice {
            if let match = line.range(
                of: #"@Published\s+(?:private\s+)?var\s+([A-Za-z_][A-Za-z0-9_]*)"#,
                options: .regularExpression) {
                let text = String(line[match])
                if let varRange = text.range(of: #"var\s+([A-Za-z_][A-Za-z0-9_]*)$"#,
                                             options: .regularExpression) {
                    names.append(String(text[varRange].dropFirst(4)))
                }
            }
        }
        return names
    }

    /// URL string literals → external services (host) and endpoints (full
    /// URL with a path). Local/test hosts are excluded — they are not
    /// external services in any honest sense.
    private func detectServiceEndpoints(file: SourceFile, lines: [String]) -> [SemanticEntity] {
        var entities: [SemanticEntity] = []
        var seenHosts: Set<String> = []
        var seenURLs: Set<String> = []
        let excludedHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "example.com"]
        guard let regex = try? NSRegularExpression(
            pattern: #"https?://([A-Za-z0-9.-]+)(/[A-Za-z0-9_./~%+-]*)?"#) else { return [] }

        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            for match in regex.matches(in: line, range: range) {
                guard let hostRange = Range(match.range(at: 1), in: line) else { continue }
                let host = String(line[hostRange]).lowercased()
                guard !excludedHosts.contains(host), !host.hasSuffix(".local") else { continue }
                let fullURL = Range(match.range(at: 0), in: line).map { String(line[$0]) } ?? host
                if seenHosts.insert(host).inserted {
                    entities.append(SemanticEntity(
                        kind: .externalService, name: host, path: file.path,
                        line: index + 1, attributes: ["literal": "true"], source: adapterID))
                }
                let hasPath = fullURL != "https://\(host)" && fullURL != "http://\(host)"
                    && !fullURL.hasSuffix("/")
                if hasPath, seenURLs.insert(fullURL).inserted {
                    entities.append(SemanticEntity(
                        kind: .endpoint, name: fullURL, path: file.path,
                        line: index + 1,
                        attributes: ["host": host, "literal": "true"], source: adapterID))
                }
            }
        }
        return entities
    }

    /// `ProcessInfo.processInfo.environment["KEY"]` — a place where the code
    /// expects a secret/config value. The VALUE is never read or recorded.
    private func detectSecretReferences(file: SourceFile, lines: [String]) -> [SemanticEntity] {
        var entities: [SemanticEntity] = []
        var seen: Set<String> = []
        guard let regex = try? NSRegularExpression(
            pattern: #"environment\s*\[\s*"([A-Za-z_][A-Za-z0-9_]*)"\s*\]"#) else { return [] }
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            for match in regex.matches(in: line, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: line) else { continue }
                let key = String(line[keyRange])
                if seen.insert(key).inserted {
                    entities.append(SemanticEntity(
                        kind: .secretReference, name: key, path: file.path,
                        line: index + 1, attributes: ["mechanism": "environmentVariable"],
                        source: adapterID))
                }
            }
        }
        return entities
    }

    private func detectBackgroundTasks(file: SourceFile, lines: [String]) -> [SemanticEntity] {
        var entities: [SemanticEntity] = []
        var seen: Set<String> = []
        guard let regex = try? NSRegularExpression(
            pattern: #"[Ii]dentifier:\s*"([A-Za-z0-9_.-]+)""#) else { return [] }
        for (index, line) in lines.enumerated() where line.contains("BGTaskScheduler") {
            let range = NSRange(line.startIndex..., in: line)
            for match in regex.matches(in: line, range: range) {
                guard let idRange = Range(match.range(at: 1), in: line) else { continue }
                let identifier = String(line[idRange])
                if seen.insert(identifier).inserted {
                    entities.append(SemanticEntity(
                        kind: .backgroundTask, name: identifier, path: file.path,
                        line: index + 1, attributes: ["scheduler": "BGTaskScheduler"],
                        source: adapterID))
                }
            }
        }
        return entities
    }

    // MARK: Apple project files

    /// Info.plist `NS*UsageDescription` keys → runtime permissions the app
    /// requests. Content-only scan of the XML; key names are stable.
    private func detectPermissions(file: SourceFile) -> [SemanticEntity] {
        var entities: [SemanticEntity] = []
        guard let regex = try? NSRegularExpression(
            pattern: #"<key>(NS[A-Za-z]+UsageDescription)</key>"#) else { return [] }
        let range = NSRange(file.content.startIndex..., in: file.content)
        for match in regex.matches(in: file.content, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: file.content) else { continue }
            let key = String(file.content[keyRange])
            let purpose = key.dropFirst(2).dropLast("UsageDescription".count)
            entities.append(SemanticEntity(
                kind: .permission, name: String(purpose), path: file.path,
                attributes: ["infoPlistKey": key], source: adapterID))
        }
        return entities
    }

    private func detectEntitlements(file: SourceFile) -> [SemanticEntity] {
        var entities: [SemanticEntity] = []
        guard let regex = try? NSRegularExpression(
            pattern: #"<key>(com\.apple\.[A-Za-z0-9.-]+)</key>"#) else { return [] }
        let range = NSRange(file.content.startIndex..., in: file.content)
        for match in regex.matches(in: file.content, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: file.content) else { continue }
            let key = String(file.content[keyRange])
            entities.append(SemanticEntity(
                kind: .entitlement, name: key, path: file.path, source: adapterID))
        }
        return entities
    }

    /// xcodegen project.yml: target names are the indented keys directly
    /// under the top-level `targets:` mapping.
    private func detectProjectYMLTargets(file: SourceFile) -> [SemanticEntity] {
        var entities: [SemanticEntity] = []
        var inTargets = false
        for (index, rawLine) in file.content
            .split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine)
            if line.hasPrefix("targets:") { inTargets = true; continue }
            if inTargets {
                if !line.hasPrefix(" ") && !line.isEmpty { inTargets = false; continue }
                if let match = line.range(of: #"^  ([A-Za-z_][A-Za-z0-9_ ]*):"#,
                                          options: .regularExpression) {
                    let name = String(line[match].dropFirst(2).dropLast())
                    entities.append(SemanticEntity(
                        kind: .buildTarget, name: name, path: file.path,
                        line: index + 1, attributes: ["manifest": "xcodegen"],
                        source: adapterID))
                }
            }
        }
        return entities
    }

    private func detectPackageTargets(file: SourceFile) -> [SemanticEntity] {
        var entities: [SemanticEntity] = []
        guard let regex = try? NSRegularExpression(
            pattern: #"\.target\(\s*name:\s*"([^"]+)""#) else { return [] }
        let range = NSRange(file.content.startIndex..., in: file.content)
        for match in regex.matches(in: file.content, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: file.content) else { continue }
            entities.append(SemanticEntity(
                kind: .buildTarget, name: String(file.content[nameRange]), path: file.path,
                attributes: ["manifest": "swiftpm"], source: adapterID))
        }
        return entities
    }
}
