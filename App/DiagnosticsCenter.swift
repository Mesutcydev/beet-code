import AppKit
import SwiftUI

/// In-app diagnostics: a ring buffer of breadcrumbs (one per notable event)
/// plus a system snapshot. See docs/DIAGNOSTICS-SPEC.md for the contract —
/// metadata only, never message/file contents or secrets.
@MainActor
final class DiagnosticsCenter: ObservableObject {
    static let shared = DiagnosticsCenter()

    struct Breadcrumb: Identifiable, Equatable {
        enum Category: String, CaseIterable {
            case session, engine, tool, approval, `import`, system

            var label: String { rawValue.capitalized }

            var icon: String {
                switch self {
                case .session: "bubble.left.and.bubble.right"
                case .engine: "cpu"
                case .tool: "wrench.and.screwdriver"
                case .approval: "hand.raised"
                case .import: "tray.and.arrow.down"
                case .system: "desktopcomputer"
                }
            }
        }

        enum Level: Int {
            case info, warning, error
        }

        let id = UUID()
        let date: Date
        let category: Category
        let level: Level
        let message: String
        let detail: String?
    }

    @Published private(set) var breadcrumbs: [Breadcrumb] = []

    /// Ring buffer cap — oldest entries evict silently.
    private let capacity = 500

    private init() {}

    func record(_ category: Breadcrumb.Category,
                _ message: String,
                detail: String? = nil,
                level: Breadcrumb.Level = .info) {
        breadcrumbs.append(Breadcrumb(
            date: Date(), category: category, level: level,
            message: message, detail: detail))
        if breadcrumbs.count > capacity {
            breadcrumbs.removeFirst(breadcrumbs.count - capacity)
        }
    }

    func clear() { breadcrumbs.removeAll() }

    var problemCount: Int {
        breadcrumbs.filter { $0.level != .info }.count
    }

    // MARK: System snapshot

    struct SystemInfo {
        let appVersion: String
        let macOSVersion: String
        let physicalMemory: String
        let thermalState: String
        let uptime: String
    }

    var systemInfo: SystemInfo {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let process = ProcessInfo.processInfo
        let thermal: String = switch process.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
        let uptime = Duration.seconds(process.systemUptime)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return SystemInfo(
            appVersion: "\(version) (\(build))",
            macOSVersion: process.operatingSystemVersionString,
            physicalMemory: ByteFormatter.bytes(Int64(process.physicalMemory)),
            thermalState: thermal,
            uptime: uptime)
    }

    // MARK: Export

    /// Plain-text log for bug reports — the system snapshot header plus the
    /// full breadcrumb timeline.
    func exportText() -> String {
        let info = systemInfo
        var lines = [
            "Beet Code diagnostics — exported \(Self.exportStamp.string(from: Date()))",
            "App \(info.appVersion) · \(info.macOSVersion) · \(info.physicalMemory) · thermal: \(info.thermalState) · uptime: \(info.uptime)",
            "",
        ]
        for crumb in breadcrumbs {
            let time = Self.exportTime.string(from: crumb.date)
            let level = crumb.level == .info ? "" : (crumb.level == .warning ? " [warning]" : " [ERROR]")
            var line = "\(time)  \(crumb.category.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(crumb.message)\(level)"
            if let detail = crumb.detail, !detail.isEmpty {
                line += "\n            \(detail)"
            }
            lines.append(line)
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static let exportStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
    private static let exportTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static var suggestedExportName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "beetcode-diagnostics-\(formatter.string(from: Date())).log"
    }
}
