import Foundation

/// Project MCP servers and hooks execute workspace-supplied binaries. They
/// load only after the user trusts that folder — user-global config
/// (`~/.beetcode/`) is always allowed.
enum WorkspaceTrust {
    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func isTrusted(_ url: URL) -> Bool {
        let path = canonicalPath(url)
        return AppPreferencesStore.shared.current.trustedWorkspacePaths.contains(path)
    }

    static func trust(_ url: URL) {
        var preferences = AppPreferencesStore.shared.current
        let path = canonicalPath(url)
        guard !preferences.trustedWorkspacePaths.contains(path) else { return }
        preferences.trustedWorkspacePaths.append(path)
        AppPreferencesStore.shared.save(preferences)
    }

    /// True when the folder contains project-local MCP or hook configs that
    /// would spawn processes if trusted.
    static func hasProjectExecutables(_ url: URL) -> Bool {
        let beet = url.appendingPathComponent(".beetcode", isDirectory: true)
        let mcp = beet.appendingPathComponent("mcp.json")
        let hooks = beet.appendingPathComponent("hooks.json")
        if FileManager.default.fileExists(atPath: mcp.path) { return true }
        if FileManager.default.fileExists(atPath: hooks.path) { return true }
        let openCode = url.appendingPathComponent("opencode.json")
        let openCodeJSONC = url.appendingPathComponent("opencode.jsonc")
        if FileManager.default.fileExists(atPath: openCode.path) { return true }
        if FileManager.default.fileExists(atPath: openCodeJSONC.path) { return true }
        return false
    }

    static func needsConsent(_ url: URL) -> Bool {
        hasProjectExecutables(url) && !isTrusted(url)
    }
}
