import Foundation

enum ByteFormatter {
    static func bytes(_ value: Int64) -> String {
        format(Double(value))
    }

    static func bytes(_ value: UInt64) -> String {
        format(Double(value))
    }

    static func speed(bytesPerSecond: Double) -> String {
        "\(format(bytesPerSecond))/s"
    }

    private static func format(_ value: Double) -> String {
        guard value > 0 else { return "0 KB" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(value.rounded()))
    }
}
