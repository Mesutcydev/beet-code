import Foundation

/// Applies semantic-provider output onto the syntactic graph (Phase 5).
/// Matching is conservative: a parser symbol is upgraded to a semantic
/// source label only when the provider reports the SAME name within a small
/// line tolerance in the SAME file. Nothing new is invented — enrichment
/// verifies, it does not fabricate.
struct SemanticEnricher: Sendable {

    struct Report: Sendable, Equatable {
        var filesChecked = 0
        var symbolsUpgraded = 0
        var filesUnavailable = 0
    }

    /// Line tolerance: the syntactic parser and the LSP occasionally disagree
    /// by a line on multi-line declarations.
    static let lineTolerance = 2

    func enrich(
        graph: SymbolGraph,
        provider: any SemanticProvider,
        files: [(parsed: ParsedFile, absolutePath: String, content: String)]
    ) async -> Report {
        guard await provider.isAvailable() else {
            return Report(filesChecked: 0, symbolsUpgraded: 0,
                          filesUnavailable: files.count)
        }
        var report = Report()
        for file in files {
            do {
                let resolved = try await provider.documentSymbols(
                    path: file.absolutePath, content: file.content,
                    language: file.parsed.language)
                report.filesChecked += 1
                var matched: [String] = []
                for symbol in file.parsed.symbols {
                    let hit = resolved.contains { candidate in
                        candidate.name == symbol.name
                            && abs(candidate.line - symbol.range.startLine) <= Self.lineTolerance
                    }
                    if hit { matched.append(symbol.symbolID) }
                }
                if !matched.isEmpty {
                    let count = (try? graph.markSemantic(
                        nodeIDs: matched, source: provider.sourceLabel)) ?? 0
                    report.symbolsUpgraded += count
                }
            } catch {
                report.filesUnavailable += 1
            }
        }
        return report
    }
}
