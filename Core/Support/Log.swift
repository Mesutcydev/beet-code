import OSLog

/// Central logging. One subsystem, categories per subsystem-area so
/// Console.app filtering stays useful.
enum Log {
    private static let subsystem = "com.beetcode.app"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let engine = Logger(subsystem: subsystem, category: "engine")
    static let agent = Logger(subsystem: subsystem, category: "agent")
    static let tools = Logger(subsystem: subsystem, category: "tools")
    static let memory = Logger(subsystem: subsystem, category: "memory")
    static let thermal = Logger(subsystem: subsystem, category: "thermal")
    static let downloads = Logger(subsystem: subsystem, category: "downloads")
}
