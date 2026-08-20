import AppKit
import SwiftUI

/// Resolves a real macOS app icon for sidebar group headers: the project's
/// own .app when one lives in the folder, otherwise Claude / Codex / Cursor
/// / Beet Code from Launch Services.
enum AppIconLookup {

    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()

    static func workspace(_ path: String) -> NSImage? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let key = "ws:\(trimmed)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let url = URL(fileURLWithPath: trimmed)
        let image: NSImage?
        if url.pathExtension == "app" {
            image = NSWorkspace.shared.icon(forFile: trimmed)
        } else if let nested = nestedApp(in: url) {
            image = NSWorkspace.shared.icon(forFile: nested.path)
        } else if FileManager.default.fileExists(atPath: trimmed) {
            image = NSWorkspace.shared.icon(forFile: trimmed)
        } else {
            image = nil
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    static func source(_ source: SessionSource) -> NSImage? {
        let key = "src:\(source.rawValue)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        for id in bundleIDs(for: source) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                let image = NSWorkspace.shared.icon(forFile: url.path)
                cache.setObject(image, forKey: key)
                return image
            }
        }
        return nil
    }

    /// Prefer a workspace app icon; if the folder is gone or generic, use
    /// the source app when every chat in the group came from one tool.
    static func header(path: String, records: [SessionRecord]) -> NSImage? {
        if let workspace = workspace(path), !isGenericFolder(workspace) {
            return workspace
        }
        let sources = Set(records.map(\.source))
        if sources.count == 1, let only = sources.first, let icon = source(only) {
            return icon
        }
        return workspace(path)
    }

    private static func nestedApp(in folder: URL) -> URL? {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return nil }
        let apps = children.filter { $0.pathExtension == "app" }
        if apps.count == 1 { return apps[0] }
        let named = folder.lastPathComponent
        return apps.first { $0.deletingPathExtension().lastPathComponent.compare(named, options: .caseInsensitive) == .orderedSame }
            ?? apps.first
    }

    private static func bundleIDs(for source: SessionSource) -> [String] {
        switch source {
        case .app: ["com.beetcode.app"]
        case .claude: ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        case .codex: ["com.openai.codex", "com.openai.chat"]
        case .cursor: ["com.todesktop.230313mzl4w4u92", "com.cursor.Cursor"]
        case .bundle: []
        }
    }

    /// NSWorkspace folder icons are 32² generic pictograms — skip those so
    /// we can fall through to the source app.
    private static func isGenericFolder(_ image: NSImage) -> Bool {
        image.size.width <= 32 && image.size.height <= 32 && image.name() == nil
    }
}
