import Foundation

/// Deterministic structural parser for Swift. This is NOT SwiftSyntax and
/// NOT Tree-sitter: it is a comment/string-aware, brace-tracked declaration
/// extractor. Everything it emits is labeled `.syntactic`; it never claims
/// type resolution. Its guarantees:
///   - declarations (type/func/var/let/typealias/init/extension) with ranges
///   - container nesting via brace tracking
///   - imports
///   - inheritance/conformance clause candidates
///   - syntactic call-site candidates (`name(` outside own declarations)
/// Its documented weaknesses: macro-generated code, complex multi-line
/// signatures spanning generic where-clauses, and conditional compilation
/// blocks are parsed linearly (both branches recorded).
struct SwiftLanguageAdapter: LanguageAdapter {

    let languageID = "swift"
    let fileExtensions: Set<String> = ["swift"]

    private enum ContainerKind { case type, function }

    private struct Container {
        let id: String
        let name: String
        let kind: ContainerKind
        let depth: Int
    }

    func parse(file: SourceFile) -> ParsedFile {
        let cleaned = CommentStripper.strip(file.content)
        let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var symbols: [ParsedSymbol] = []
        var imports: [ParsedImport] = []
        var references: [ParsedReference] = []
        var stack: [Container] = []
        var depth = 0
        /// Pending type declarations awaiting their opening brace so the
        /// container push happens at the right depth.
        var pendingType: (id: String, name: String, depth: Int)?

        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            // Imports (line-level, only meaningful at file scope but cheap to accept anywhere).
            if let module = Self.parseImport(trimmed) {
                imports.append(ParsedImport(module: module, line: lineNumber))
            }

            // Declarations.
            var bodyCallsHandled = false
            if var decl = Self.parseDeclaration(trimmed) {
                // XCTest convention: instance methods named test* inside a
                // *Tests type are tests. Syntactic, container-aware, honest.
                if decl.kind == .function, decl.name.hasPrefix("test"),
                   let container = stack.last, container.kind == .type,
                   container.name.hasSuffix("Tests") || container.name.hasSuffix("Test") {
                    decl = Declaration(
                        name: decl.name, kind: .test, access: decl.access,
                        modifiers: decl.modifiers,
                        typeRelationships: decl.typeRelationships,
                        opensScope: decl.opensScope,
                        descriptorSuffix: decl.descriptorSuffix)
                }
                let containerChain = stack.map(\.name).joined(separator: "/")
                let scope = containerChain.isEmpty ? file.path : "\(file.path):\(containerChain)"
                let descriptor = "swift:\(scope)/\(decl.descriptorSuffix)"
                let id = ParsedSymbol.makeID(descriptor: descriptor)
                let parentID = stack.last?.id

                symbols.append(ParsedSymbol(
                    name: decl.name,
                    kind: decl.kind,
                    descriptor: descriptor,
                    symbolID: id,
                    range: SourceRange(startLine: lineNumber, endLine: lineNumber),
                    containerID: parentID,
                    access: decl.access,
                    modifiers: decl.modifiers,
                    typeRelationships: decl.typeRelationships,
                    confidence: .syntactic))

                // Type relationships also surface as references.
                for typeName in decl.typeRelationships {
                    references.append(ParsedReference(
                        name: typeName, kind: .typeMention,
                        line: lineNumber, containerID: parentID))
                }

                // Container tracking: types push on their opening brace;
                // functions push too so nested types/local decls scope right.
                if decl.opensScope {
                    let opensHere = trimmed.contains("{")
                    if opensHere {
                        stack.append(Container(
                            id: id, name: decl.name,
                            kind: decl.kind == .function || decl.kind == .method || decl.kind == .initializer ? .function : .type,
                            depth: depth + Self.braceDelta(trimmed).opens))
                    } else {
                        pendingType = (id, decl.name, depth + 1)
                    }

                    // Single-line bodies (`func f() { g() }`): the line is
                    // declaration-led, so callCandidates below would skip it
                    // entirely. Extract calls from the part after the first
                    // `{`, attributed to this declaration's own scope.
                    if let openBrace = trimmed.firstIndex(of: "{") {
                        let body = trimmed[trimmed.index(after: openBrace)...]
                            .trimmingCharacters(in: .whitespaces)
                        if !body.isEmpty {
                            for call in Self.callCandidates(in: body) {
                                references.append(ParsedReference(
                                    name: call, kind: .call, line: lineNumber,
                                    containerID: id))
                            }
                        }
                        bodyCallsHandled = true
                    }
                }
            } else if let pending = pendingType, trimmed.hasPrefix("{") || trimmed.contains("{") {
                stack.append(Container(
                    id: pending.id, name: pending.name, kind: .type,
                    depth: pending.depth))
                pendingType = nil
            }

            // Syntactic call-site candidates on non-declaration lines.
            if !trimmed.isEmpty && !bodyCallsHandled {
                for call in Self.callCandidates(in: trimmed) {
                    references.append(ParsedReference(
                        name: call, kind: .call, line: lineNumber,
                        containerID: stack.last?.id))
                }
            }

            // Brace accounting AFTER declaration handling so a decl's own
            // braces are inside its scope.
            let delta = Self.braceDelta(rawLine)
            depth += delta.opens - delta.closes
            while let top = stack.last, depth < top.depth {
                // Close the scope: record the real end line on the symbol.
                if let symbolIndex = symbols.firstIndex(where: { $0.symbolID == top.id }) {
                    symbols[symbolIndex] = ParsedSymbol(
                        name: symbols[symbolIndex].name,
                        kind: symbols[symbolIndex].kind,
                        descriptor: symbols[symbolIndex].descriptor,
                        symbolID: symbols[symbolIndex].symbolID,
                        range: SourceRange(
                            startLine: symbols[symbolIndex].range.startLine,
                            endLine: lineNumber),
                        containerID: symbols[symbolIndex].containerID,
                        access: symbols[symbolIndex].access,
                        modifiers: symbols[symbolIndex].modifiers,
                        typeRelationships: symbols[symbolIndex].typeRelationships,
                        confidence: .syntactic)
                }
                stack.removeLast()
            }
        }

        return ParsedFile(
            path: file.path,
            contentHash: file.contentHash,
            language: languageID,
            symbols: symbols,
            imports: imports,
            references: references)
    }

    // MARK: Declaration parsing

    struct Declaration {
        let name: String
        let kind: SymbolKind
        let access: String?
        let modifiers: [String]
        let typeRelationships: [String]
        let opensScope: Bool
        /// Name + signature shape used in the stable descriptor.
        let descriptorSuffix: String
    }

    private static let accessLevels: Set<String> = [
        "open", "public", "package", "internal", "fileprivate", "private",
    ]
    private static let memberModifiers: Set<String> = [
        "static", "final", "override", "mutating", "nonmutating",
        "lazy", "weak", "unowned", "convenience", "required",
    ]

    static func parseDeclaration(_ line: String) -> Declaration? {
        var rest = line
        // Strip leading attributes (@MainActor, @discardableResult, …).
        while rest.hasPrefix("@") {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            rest = String(rest[space...]).trimmingCharacters(in: .whitespaces)
        }

        var tokens = rest.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return nil }

        var access: String?
        var modifiers: [String] = []
        while let first = tokens.first {
            if accessLevels.contains(first) { access = first; tokens.removeFirst() }
            else if memberModifiers.contains(first) { modifiers.append(first); tokens.removeFirst() }
            else if first == "indirect" { tokens.removeFirst() }
            else { break }
        }
        guard let keyword = tokens.first else { return nil }

        let keywordKind: SymbolKind? = switch keyword {
        case "class": .class
        case "struct": .struct
        case "enum": .enum
        case "protocol": .protocol
        case "actor": .actor
        case "extension": .extension
        case "func": .function
        case "var", "let": .property
        case "typealias": .typeAlias
        case "init": .initializer
        default: nil
        }
        guard let kind = keywordKind else { return nil }

        let afterKeyword = tokens.dropFirst().joined(separator: " ")
        switch kind {
        case .class, .struct, .enum, .protocol, .actor, .extension:
            // Name is the first identifier; inheritance clause after ':'.
            guard let nameMatch = afterKeyword.range(of: #"^[A-Za-z_][A-Za-z0-9_]*"#,
                                                     options: .regularExpression)
            else { return nil }
            let name = String(afterKeyword[nameMatch])
            var relationships: [String] = []
            if let colon = afterKeyword.firstIndex(of: ":") {
                let clause = afterKeyword[afterKeyword.index(after: colon)...]
                // Cut at `where` or `{`; split on commas; strip generics noise.
                let cut = clause.components(separatedBy: CharacterSet(charactersIn: "{"))[0]
                    .components(separatedBy: " where ")[0]
                relationships = cut.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .compactMap { entry -> String? in
                        guard let match = entry.range(of: #"^[A-Za-z_][A-Za-z0-9_]*"#,
                                                      options: .regularExpression)
                        else { return nil }
                        return String(entry[match])
                    }
            }
            return Declaration(
                name: name, kind: kind, access: access,
                modifiers: modifiers.sorted(),
                typeRelationships: relationships,
                opensScope: true,
                descriptorSuffix: kind == .extension ? "extension-\(name)" : name)

        case .function:
            // Name up to `(`; async/throws in the tail shape the descriptor.
            guard let paren = afterKeyword.firstIndex(of: "(") else { return nil }
            let namePart = String(afterKeyword[..<paren])
            guard let nameMatch = namePart.range(of: #"^[A-Za-z_][A-Za-z0-9_]*"#,
                                                 options: .regularExpression)
            else { return nil }
            let name = String(namePart[nameMatch])
            var mods = modifiers
            if afterKeyword.contains(" async") || afterKeyword.hasSuffix("async") { mods.append("async") }
            if afterKeyword.contains(" throws") { mods.append("throws") }
            return Declaration(
                name: name,
                kind: .function,
                access: access,
                modifiers: mods.sorted(),
                typeRelationships: [],
                opensScope: true,
                descriptorSuffix: "\(name)()")

        case .property:
            guard let nameMatch = afterKeyword.range(of: #"^[A-Za-z_][A-Za-z0-9_]*"#,
                                                     options: .regularExpression)
            else { return nil }
            let name = String(afterKeyword[nameMatch])
            // Computed properties open a scope; stored ones do not.
            return Declaration(
                name: name, kind: .property, access: access,
                modifiers: modifiers.sorted(),
                typeRelationships: [],
                opensScope: afterKeyword.contains("{"),
                descriptorSuffix: name)

        case .typeAlias:
            guard let nameMatch = afterKeyword.range(of: #"^[A-Za-z_][A-Za-z0-9_]*"#,
                                                     options: .regularExpression)
            else { return nil }
            let name = String(afterKeyword[nameMatch])
            return Declaration(
                name: name, kind: .typeAlias, access: access,
                modifiers: modifiers.sorted(),
                typeRelationships: [], opensScope: false,
                descriptorSuffix: name)

        case .initializer:
            return Declaration(
                name: "init", kind: .initializer, access: access,
                modifiers: modifiers.sorted(),
                typeRelationships: [], opensScope: true,
                descriptorSuffix: "init()")

        case .test, .method:
            return nil // produced via .function path above
        }
    }

    // MARK: Imports / calls / braces

    static func parseImport(_ line: String) -> String? {
        var text = line
        if text.hasPrefix("@testable ") { text = String(text.dropFirst("@testable ".count)) }
        guard text.hasPrefix("import ") else { return nil }
        let rest = text.dropFirst("import ".count)
        // `import struct Foo.Bar` → module is Foo.
        let parts = rest.split(separator: " ")
        let target = parts.last ?? ""
        guard let match = target.range(of: #"^[A-Za-z_][A-Za-z0-9_.]*"#,
                                       options: .regularExpression)
        else { return nil }
        return String(target[match]).split(separator: ".").first.map(String.init)
    }

    /// `identifier(` occurrences that are not keywords/declarations of this
    /// line. Purely syntactic candidates — the graph phase decides what they
    /// can honestly connect to.
    static func callCandidates(in line: String) -> [String] {
        guard !line.isEmpty else { return [] }
        // Skip pure declaration/keyword-led lines: their `name(` is the
        // declaration itself. Assignments (`let x = call()`) keep their
        // calls — only the leading keyword distinguishes a declaration.
        let declKeywords = ["func ", "init", "import ",
                            "class ", "struct ", "enum ", "protocol ", "actor ",
                            "extension ", "typealias "]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for keyword in declKeywords where trimmed.hasPrefix(keyword) { return [] }
        if trimmed.hasPrefix("//") { return [] }

        var results: [String] = []
        guard let regex = try? NSRegularExpression(
            pattern: #"([A-Za-z_][A-Za-z0-9_]*)\s*\("#) else { return [] }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        for match in regex.matches(in: trimmed, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: trimmed) else { continue }
            let name = String(trimmed[nameRange])
            let keywords: Set<String> = ["if", "while", "for", "switch", "guard", "return"]
            if !keywords.contains(name) { results.append(name) }
        }
        return results
    }

    static func braceDelta(_ line: String) -> (opens: Int, closes: Int) {
        var opens = 0, closes = 0
        for char in line {
            if char == "{" { opens += 1 }
            else if char == "}" { closes += 1 }
        }
        return (opens, closes)
    }
}

/// Blanks comments and string literal contents while preserving every byte
/// position and newline, so line/column structure and brace accounting stay
/// exact. Handles: //, /* */ (nested), "…", """…""", #"…"# raw forms.
enum CommentStripper {

    static func strip(_ source: String) -> String {
        let chars = Array(source)
        var output = chars
        var i = 0
        var state: State = .code

        enum State {
            case code, lineComment, blockComment(Int), string(raw: Int, multiline: Bool)
        }

        func blank(_ index: Int) {
            if index < output.count, output[index] != "\n" { output[index] = " " }
        }

        while i < chars.count {
            let c = chars[i]
            let next = i + 1 < chars.count ? chars[i + 1] : "\0"
            let next2 = i + 2 < chars.count ? chars[i + 2] : "\0"
            switch state {
            case .code:
                if c == "/" && next == "/" { state = .lineComment; blank(i); blank(i + 1); i += 2; continue }
                if c == "/" && next == "*" { state = .blockComment(1); blank(i); blank(i + 1); i += 2; continue }
                if c == "\"" && next == "\"" && next2 == "\"" {
                    state = .string(raw: 0, multiline: true); blank(i); blank(i + 1); blank(i + 2); i += 3; continue
                }
                if c == "\"" { state = .string(raw: 0, multiline: false); blank(i); i += 1; continue }
                if c == "#" && next == "\"" { state = .string(raw: 1, multiline: false); blank(i); blank(i + 1); i += 2; continue }
                i += 1
            case .lineComment:
                if c == "\n" { state = .code } else { blank(i) }
                i += 1
            case .blockComment(let nesting):
                if c == "/" && next == "*" { state = .blockComment(nesting + 1); blank(i); blank(i + 1); i += 2; continue }
                if c == "*" && next == "/" {
                    blank(i); blank(i + 1); i += 2
                    let n = nesting - 1
                    state = n == 0 ? .code : .blockComment(n)
                    continue
                }
                blank(i); i += 1
            case .string(let raw, let multiline):
                if raw == 0 && c == "\\" && !multiline { blank(i); blank(i + 1); i += 2; continue }
                if multiline {
                    if c == "\"" && next == "\"" && next2 == "\"" {
                        blank(i); blank(i + 1); blank(i + 2); i += 3; state = .code; continue
                    }
                    blank(i); i += 1
                } else {
                    if c == "\"" { blank(i); i += 1; state = .code; continue }
                    if c == "\n" { state = .code; i += 1; continue }
                    blank(i); i += 1
                }
            }
        }
        return String(output)
    }
}
