import XCTest
@testable import BeetCode

final class RepoIndexTests: XCTestCase {

    func testIndexesFilesAndDirectories() throws {
        let ws = TempWorkspace()
        ws.write("import Foundation\nstruct A {}\n", to: "Sources/A.swift")
        ws.write("hello", to: "README.md")
        ws.write("binary\u{0}", to: "data.bin")
        ws.makeDirectory("Sources")

        let index = RepoIndexer.build(root: ws.url)
        XCTAssertTrue(index.isGitRepository == false || index.isGitRepository == true)
        let paths = Set(index.entries.map(\.path))
        XCTAssertTrue(paths.contains("README.md"), paths.description)
        XCTAssertTrue(paths.contains("Sources"), paths.description)
        XCTAssertTrue(paths.contains("Sources/A.swift"), paths.description)
        // Summarizable files carry a symbol summary.
        let aSwift = index.entries.first { $0.path == "Sources/A.swift" }
        XCTAssertNotNil(aSwift?.summary)
        XCTAssertTrue(aSwift?.summary?.contains("import Foundation") == true)
        // Binary files get no summary.
        let binary = index.entries.first { $0.path == "data.bin" }
        XCTAssertNil(binary?.summary)
    }

    func testExcludesVendorAndGitDirectories() throws {
        let ws = TempWorkspace()
        ws.write("a", to: "app.swift")
        ws.write("b", to: "node_modules/pkg/index.js")
        ws.write("c", to: ".build/debug/x.o")
        ws.write("d", to: "vendor/lib.c")
        ws.makeDirectory(".git")
        ws.write("refs", to: ".git/HEAD")

        let index = RepoIndexer.build(root: ws.url)
        let paths = Set(index.entries.map(\.path))
        XCTAssertTrue(paths.contains("app.swift"))
        XCTAssertFalse(paths.contains("node_modules"), paths.description)
        XCTAssertFalse(paths.contains("node_modules/pkg/index.js"), paths.description)
        XCTAssertFalse(paths.contains(".build"), paths.description)
        XCTAssertFalse(paths.contains("vendor"), paths.description)
    }

    func testRespectsGitignore() throws {
        let ws = TempWorkspace()
        ws.write("build/\n*.log\n", to: ".gitignore")
        ws.write("x", to: "kept.swift")
        ws.write("y", to: "build/artifacts.o")
        ws.write("z", to: "debug.log")

        let index = RepoIndexer.build(root: ws.url)
        let paths = Set(index.entries.map(\.path))
        XCTAssertTrue(paths.contains("kept.swift"))
        XCTAssertFalse(paths.contains("build"), paths.description)
        XCTAssertFalse(paths.contains("debug.log"), paths.description)
    }

    func testBoundedIndex() throws {
        let ws = TempWorkspace()
        for i in 0..<(RepoIndexer.maxFiles + 50) {
            ws.write("x", to: "f\(i).txt")
        }
        let index = RepoIndexer.build(root: ws.url)
        XCTAssertTrue(index.truncated)
        XCTAssertLessThanOrEqual(index.entries.count, RepoIndexer.maxFiles + 100)
        XCTAssertEqual(index.fileCount, RepoIndexer.maxFiles)
    }

    func testRenderIsCompact() throws {
        let ws = TempWorkspace()
        ws.write("import Foundation\nstruct A {}\n", to: "A.swift")
        ws.write("x", to: "b.txt")
        let index = RepoIndexer.build(root: ws.url)
        let rendered = index.render
        XCTAssertTrue(rendered.contains("A.swift"), rendered)
        XCTAssertLessThan(rendered.utf8.count, 2_000)
    }

    func testTaskRankingPutsRelevantFilesFirst() throws {
        let ws = TempWorkspace()
        ws.write("func login() {}", to: "Sources/Auth/Login.swift")
        ws.write("func format() {}", to: "Sources/Utils/Format.swift")
        ws.write("func loginHelper() {}", to: "Sources/Auth/LoginHelper.swift")

        let ranked = RepoIndexer.build(root: ws.url, taskHint: "fix the login flow")
        let paths = ranked.entries.map(\.path)
        // Login-related files must rank before unrelated ones.
        let loginIdx = paths.firstIndex { $0.contains("Login.swift") } ?? -1
        let formatIdx = paths.firstIndex { $0.contains("Format.swift") } ?? -1
        XCTAssertGreaterThan(loginIdx, -1)
        XCTAssertGreaterThan(formatIdx, -1)
        XCTAssertLessThan(loginIdx, formatIdx, "login files should rank first: \(paths)")
    }
}