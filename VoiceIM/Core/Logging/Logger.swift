import Foundation

/// 日志级别
enum LogLevel: Int, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var prefix: String {
        switch self {
        case .debug:   return "[DEBUG]"
        case .info:    return "[INFO]"
        case .warning: return "[WARN]"
        case .error:   return "[ERROR]"
        }
    }
}

/// 日志协议
protocol Logger {
    /// 最低日志级别（低于此级别的日志不会输出）
    var minimumLevel: LogLevel { get set }

    /// 记录日志
    func log(_ message: String, level: LogLevel, file: String, function: String, line: Int)
}

extension Logger {
    /// 记录 debug 日志
    func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .debug, file: file, function: function, line: line)
    }

    /// 记录 info 日志
    func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .info, file: file, function: function, line: line)
    }

    /// 记录 warning 日志
    func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .warning, file: file, function: function, line: line)
    }

    /// 记录 error 日志
    func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .error, file: file, function: function, line: line)
    }
}

// MARK: - ConsoleLogger

/// 控制台日志输出
final class ConsoleLogger: Logger {
    var minimumLevel: LogLevel

    init(minimumLevel: LogLevel = .debug) {
        self.minimumLevel = minimumLevel
    }

    func log(_ message: String, level: LogLevel, file: String, function: String, line: Int) {
        guard level >= minimumLevel else { return }

        let fileName = (file as NSString).lastPathComponent
        let timestamp = DateFormatter.logTimestamp.string(from: Date())
        print("\(timestamp) \(level.prefix) [\(fileName):\(line)] \(function) - \(message)")
    }
}

// MARK: - FileLogger

/// 文件日志输出
final class FileLogger: Logger {
    var minimumLevel: LogLevel

    private let maxFileSize: UInt64 = 5 * 1024 * 1024
    private let maxFileCount = 3
    private let logDirectory: URL
    private let baseFileName: String

    private var fileHandle: FileHandle?

    private var currentLogURL: URL {
        logDirectory.appendingPathComponent("\(baseFileName).log")
    }

    init(minimumLevel: LogLevel = .info, logDirectory: URL? = nil) {
        self.minimumLevel = minimumLevel

        let directory: URL
        if let logDirectory = logDirectory {
            directory = logDirectory
        } else {
            guard let documentsURL = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask).first else {
                fatalError("Failed to get documents directory")
            }
            directory = documentsURL.appendingPathComponent("Logs", isDirectory: true)
        }
        self.logDirectory = directory

        self.baseFileName = "VoiceIM_\(DateFormatter.logFileName.string(from: Date()))"

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        cleanupOldLogs()

        if !FileManager.default.fileExists(atPath: currentLogURL.path) {
            FileManager.default.createFile(atPath: currentLogURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: currentLogURL)
        fileHandle?.seekToEndOfFile()
    }

    deinit {
        try? fileHandle?.close()
    }

    func log(_ message: String, level: LogLevel, file: String, function: String, line: Int) {
        guard level >= minimumLevel else { return }

        let sanitized = LogSanitizer.sanitize(message)
        let fileName = (file as NSString).lastPathComponent
        let timestamp = DateFormatter.logTimestamp.string(from: Date())
        let logLine = "\(timestamp) \(level.prefix) [\(fileName):\(line)] \(function) - \(sanitized)\n"

        guard let data = logLine.data(using: .utf8) else { return }

        rotateIfNeeded(pendingWriteLength: UInt64(data.count))

        fileHandle?.write(data)
    }

    private func rotateIfNeeded(pendingWriteLength: UInt64) {
        let path = currentLogURL.path
        let currentSize: UInt64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? NSNumber {
            currentSize = size.uint64Value
        } else {
            currentSize = 0
        }

        guard currentSize + pendingWriteLength >= maxFileSize else { return }

        try? fileHandle?.close()
        fileHandle = nil

        let fm = FileManager.default
        let basePath = path
        let oldestPath = "\(basePath).\(maxFileCount - 1)"
        if fm.fileExists(atPath: oldestPath) {
            try? fm.removeItem(atPath: oldestPath)
        }
        var n = maxFileCount - 2
        while n >= 1 {
            let fromPath = "\(basePath).\(n)"
            let toPath = "\(basePath).\(n + 1)"
            if fm.fileExists(atPath: fromPath) {
                if fm.fileExists(atPath: toPath) {
                    try? fm.removeItem(atPath: toPath)
                }
                try? fm.moveItem(atPath: fromPath, toPath: toPath)
            }
            n -= 1
        }
        if fm.fileExists(atPath: basePath) {
            let toPath = "\(basePath).1"
            if fm.fileExists(atPath: toPath) {
                try? fm.removeItem(atPath: toPath)
            }
            try? fm.moveItem(atPath: basePath, toPath: toPath)
        }

        FileManager.default.createFile(atPath: basePath, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: currentLogURL)
        fileHandle?.seekToEndOfFile()

        cleanupOldLogs()
    }

    private func cleanupOldLogs() {
        let basePath = currentLogURL.path
        let fm = FileManager.default
        var index = maxFileCount
        while fm.fileExists(atPath: "\(basePath).\(index)") {
            try? fm.removeItem(atPath: "\(basePath).\(index)")
            index += 1
        }
    }
}

// MARK: - CompositeLogger

/// 组合日志输出（同时输出到多个目标）
final class CompositeLogger: Logger {
    var minimumLevel: LogLevel {
        get { loggers.first?.minimumLevel ?? .debug }
        set {
            for i in 0..<loggers.count {
                loggers[i].minimumLevel = newValue
            }
        }
    }

    private var loggers: [Logger]

    init(loggers: [Logger]) {
        self.loggers = loggers
    }

    func log(_ message: String, level: LogLevel, file: String, function: String, line: Int) {
        loggers.forEach { $0.log(message, level: level, file: file, function: function, line: line) }
    }
}

// MARK: - 日志脱敏

enum LogSanitizer {
    private static let urlPattern = try! NSRegularExpression(
        pattern: "https?://[^\\s]+", options: []
    )
    private static let uuidPattern = try! NSRegularExpression(
        pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
        options: []
    )
    private static let phonePattern = try! NSRegularExpression(
        pattern: "1[3-9]\\d{9}", options: []
    )
    private static let emailPattern = try! NSRegularExpression(
        pattern: "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}",
        options: []
    )

    static func sanitize(_ message: String) -> String {
        #if DEBUG
        return message
        #else
        var result = message
        let range = NSRange(result.startIndex..., in: result)
        result = urlPattern.stringByReplacingMatches(
            in: result, range: range, withTemplate: "[URL_REDACTED]"
        )
        let range2 = NSRange(result.startIndex..., in: result)
        result = uuidPattern.stringByReplacingMatches(
            in: result, range: range2, withTemplate: "[ID]"
        )
        let range3 = NSRange(result.startIndex..., in: result)
        result = phonePattern.stringByReplacingMatches(
            in: result, range: range3, withTemplate: "[PHONE_REDACTED]"
        )
        let range4 = NSRange(result.startIndex..., in: result)
        result = emailPattern.stringByReplacingMatches(
            in: result, range: range4, withTemplate: "[EMAIL_REDACTED]"
        )
        return result
        #endif
    }
}

// MARK: - Global Logger

/// 全局日志实例
nonisolated(unsafe) var logger: Logger = {
    #if DEBUG
    return CompositeLogger(loggers: [
        ConsoleLogger(minimumLevel: .debug),
        FileLogger(minimumLevel: .info)
    ])
    #else
    return FileLogger(minimumLevel: .warning)
    #endif
}()

// MARK: - DateFormatter Extensions

private extension DateFormatter {
    /// 日志时间戳格式：2026-04-05 12:34:56.789
    static let logTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// 日志文件名格式：2026-04-05
    static let logFileName: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
