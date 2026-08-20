import AppKit
import Foundation
import WebKit

extension Notification.Name {
    static let openBrowserPanel = Notification.Name("com.beetcode.openBrowserPanel")
}

/// In-app browser the agent can control.
///
/// One shared WKWebView, hosted in the docked browser panel, driven by the
/// `browser_*` agent tools through this controller. Every mutating action
/// (navigate, click, type, eval) goes through the normal PermissionGate at
/// the tool layer — the controller itself performs no authorization.
///
/// Extraction helpers (`extractText`, `extractLinks`, `pageInfo`) are pure
/// JavaScript snippets; the JS escaping in `jsLiteral` is the security
/// boundary between agent-supplied strings and page execution.
@MainActor
final class BrowserController: ObservableObject {

    /// Singleton handle. Lazily created under a lock so the reference is
    /// reachable from any actor; the WKWebView itself is only ever touched
    /// through MainActor-isolated methods (tools hop via @MainActor Tasks).
    private static let sharedLock = NSLock()
    private static nonisolated(unsafe) var sharedInstance: BrowserController?

    static var shared: BrowserController {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let existing = sharedInstance { return existing }
        let created = BrowserController()
        sharedInstance = created
        return created
    }

    private var storedWebView: WKWebView?

    var webView: WKWebView { ensureWebView() }

    @Published var currentURL: URL?
    @Published var title: String = ""
    @Published var isLoading = false
    @Published var lastError: String?

    /// Test seam: tools check this instead of asserting UI state.
    private(set) var navigationCount = 0

    /// WKWebView is MainActor-only on Xcode 26/27 SDKs. The singleton can be
    /// *referenced* off-main (lock-backed); the view is created the first
    /// time a MainActor method actually needs it.
    nonisolated private init() {}

    @MainActor
    private func ensureWebView() -> WKWebView {
        if let storedWebView { return storedWebView }
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = "BeetCode/0.8 (agent-controlled browser)"
        storedWebView = view
        return view
    }

    // MARK: Navigation

    @discardableResult
    func open(_ urlString: String, filePolicy: BrowserURLValidator.FilePolicy = .allowAny) throws -> URL {
        let url = try BrowserURLValidator.validatedURL(urlString, filePolicy: filePolicy)
        navigationCount += 1
        isLoading = true
        lastError = nil
        webView.load(URLRequest(url: url))
        currentURL = url
        return url
    }

    func back() { webView.goBack() }
    func forward() { webView.goForward() }
    func reload() { webView.reload() }
    func stop() { webView.stopLoading() }

    /// Blocks until loading settles or the deadline passes. Bounded so a
    /// tool call can never hang the agent loop.
    func waitForLoad(timeout: TimeInterval = 12) async {
        let deadline = Date().addingTimeInterval(timeout)
        while isLoading, Date() < deadline {
            // The navigation delegate is attached by the SwiftUI panel. If
            // an agent navigates before that panel is mounted, use the page's
            // own readyState as a fallback so the tool still settles.
            if let state = try? await webView.evaluateJavaScript("document.readyState") as? String,
               state == "interactive" || state == "complete" {
                isLoading = false
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // One grace settle for post-load JS activity.
        try? await Task.sleep(for: .milliseconds(250))
    }

    // MARK: JavaScript evaluation

    /// Evaluates a caller-controlled JS expression. Returns the stringified
    /// result. Errors surface as thrown `BrowserError`.
    func evaluate(_ script: String) async throws -> String {
        do {
            let result = try await webView.evaluateJavaScript(script)
            return Self.stringify(result)
        } catch {
            throw BrowserError.scriptFailed(String(describing: error).prefix(300).description)
        }
    }

    private static func stringify(_ value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return String(describing: value)
    }

    // MARK: Page extraction (agent-facing, bounded)

    /// Visible text of the page, truncated for prompt budgets.
    func extractText(limit: Int = 12_000) async throws -> String {
        let text = try await evaluate("document.body ? document.body.innerText : ''")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "\n…[truncated]" : trimmed
    }

    struct PageLink: Sendable, Equatable {
        var text: String
        var href: String
    }

    /// All links on the page: visible text + resolved URL. Capped so a
    /// link-farm page cannot blow up the tool output.
    func extractLinks(limit: Int = 60) async throws -> [PageLink] {
        let js = """
        (() => {
          const out = [];
          const anchors = document.querySelectorAll('a[href]');
          for (let i = 0; i < anchors.length && out.length < \(limit); i++) {
            const a = anchors[i];
            const text = (a.innerText || a.title || '').trim().slice(0, 120);
            out.push({ text: text, href: a.href });
          }
          return out;
        })()
        """
        let raw = try await evaluate(js)
        guard let data = raw.data(using: .utf8),
              let entries = try? JSONDecoder().decode([LinkWire].self, from: data)
        else { return [] }
        return entries.map { PageLink(text: $0.text, href: $0.href) }
    }

    private struct LinkWire: Codable {
        var text: String
        var href: String
    }

    /// True when a page is loaded or loading.
    var hasOpenPage: Bool { webView.url != nil || currentURL != nil }

    /// One-line summary of where the browser is.
    func pageInfo() -> String {
        var parts: [String] = []
        if let url = currentURL ?? webView.url { parts.append("url: \(url.absoluteString)") }
        if !title.isEmpty { parts.append("title: \(title)") }
        if isLoading { parts.append("(still loading)") }
        return parts.joined(separator: " | ")
    }

    // MARK: Interaction

    /// Clicks the first element matching a CSS selector. Returns a
    /// human-readable confirmation (or throws when nothing matches).
    func click(selector: String) async throws -> String {
        let js = """
        (() => {
          const el = document.querySelector(\(Self.jsLiteral(selector)));
          if (!el) return { clicked: false };
          el.scrollIntoView({ block: 'center' });
          el.click();
          return { clicked: true, tag: el.tagName.toLowerCase() };
        })()
        """
        let raw = try await evaluate(js)
        if raw.contains("\"clicked\":true") {
            return "clicked element matching \(selector)"
        }
        throw BrowserError.noSuchElement(selector)
    }

    /// Clicks the first clickable element whose visible text contains the
    /// given string (case-insensitive). More natural for agents than CSS.
    func clickByText(_ text: String) async throws -> String {
        let js = """
        (() => {
          const needle = \(Self.jsLiteral(text)).toLowerCase();
          const candidates = document.querySelectorAll('a, button, [role="button"], input[type="submit"], [onclick]');
          for (const el of candidates) {
            const label = (el.innerText || el.value || '').toLowerCase();
            if (label.includes(needle)) {
              el.scrollIntoView({ block: 'center' });
              el.click();
              return { clicked: true, tag: el.tagName.toLowerCase(), label: (el.innerText || el.value || '').slice(0, 80) };
            }
          }
          return { clicked: false };
        })()
        """
        let raw = try await evaluate(js)
        if raw.contains("\"clicked\":true") {
            return "clicked element containing text: \(text)"
        }
        throw BrowserError.noSuchElement(text)
    }

    /// Types into the first field matching a CSS selector.
    func type(text: String, into selector: String) async throws -> String {
        let js = """
        (() => {
          const el = document.querySelector(\(Self.jsLiteral(selector)));
          if (!el) return { typed: false };
          el.focus();
          el.value = \(Self.jsLiteral(text));
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return { typed: true };
        })()
        """
        let raw = try await evaluate(js)
        if raw.contains("\"typed\":true") {
            return "typed into \(selector)"
        }
        throw BrowserError.noSuchElement(selector)
    }

    /// Snapshot of the visible page, saved as PNG.
    func snapshot(to fileURL: URL) async throws -> URL {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: 1280)
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: config) { snapshot, error in
                if let snapshot {
                    continuation.resume(returning: snapshot)
                } else {
                    continuation.resume(throwing: BrowserError.snapshotFailed)
                }
            }
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw BrowserError.snapshotFailed }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: fileURL)
        return fileURL
    }

    // MARK: JS string safety

    /// Escapes an agent-supplied string into a safe JS string literal.
    /// This is the ONLY path from tool arguments into page JavaScript.
    /// Pure — no actor isolation needed, callable from any context.
    nonisolated static func jsLiteral(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }

    enum BrowserError: Error, LocalizedError {
        case emptyURL
        case invalidURL(String)
        case fileOutsideWorkspace(String)
        case scriptFailed(String)
        case noSuchElement(String)
        case snapshotFailed

        var errorDescription: String? {
            switch self {
            case .emptyURL: "No URL provided."
            case .invalidURL(let raw): "Invalid or non-http(s) URL: \(raw)"
            case .fileOutsideWorkspace(let path): "Refused to open '\(path)' — file URLs must stay inside the open workspace."
            case .scriptFailed(let detail): "Page script failed: \(detail)"
            case .noSuchElement(let query): "No element found for: \(query)"
            case .snapshotFailed: "Could not capture the page snapshot."
            }
        }
    }
}

/// Scheme + confinement policy for agent and chrome navigations.
/// `file://` is a workspace-escape if left unrestricted (`file:///etc/passwd`).
enum BrowserURLValidator: Sendable {
    enum FilePolicy: Sendable {
        /// User-typed address bar: any local file the user asked to open.
        case allowAny
        /// Agent tools: `file://` only when the path is inside the workspace.
        case confined(Workspace)
        /// Reject `file://` entirely.
        case refuse
    }

    static func validatedURL(_ urlString: String, filePolicy: FilePolicy) throws -> URL {
        var raw = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw BrowserController.BrowserError.emptyURL }
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else {
            throw BrowserController.BrowserError.invalidURL(raw)
        }
        switch scheme {
        case "http", "https":
            return url
        case "file":
            switch filePolicy {
            case .allowAny:
                return url
            case .refuse:
                throw BrowserController.BrowserError.invalidURL(raw)
            case .confined(let workspace):
                do {
                    _ = try workspace.resolve(url.path, access: .read)
                    return url
                } catch {
                    throw BrowserController.BrowserError.fileOutsideWorkspace(url.path)
                }
            }
        default:
            throw BrowserController.BrowserError.invalidURL(raw)
        }
    }
}

/// Bridges delegate callbacks into BrowserController's @Published state.
@MainActor
extension BrowserController {
    func markStarted(_ url: URL?) {
        isLoading = true
        lastError = nil
        if let url { currentURL = url }
    }

    func markFinished(_ url: URL?, title: String?) {
        isLoading = false
        if let url { currentURL = url }
        if let title { self.title = title }
    }

    func markFailed(_ message: String) {
        isLoading = false
        lastError = message
    }
}
