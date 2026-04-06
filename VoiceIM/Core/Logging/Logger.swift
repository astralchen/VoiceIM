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
    private let fileURL: URL
    private let fileHandle: FileHandle?

    init(minimumLevel: LogLevel = .info, logDirectory: URL? = nil) {
        self.minimumLevel = minimumLevel

        // 默认日志目录：Documents/Logs/
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

        // 创建日志目录
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 日志文件名：VoiceIM_2026-04-05.log
        let fileName = "VoiceIM_\(DateFormatter.logFileName.string(from: Date())).log"
        self.fileURL = directory.appendingPathComponent(fileName)

        // 创建或打开日志文件
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        self.fileHandle = try? FileHandle(forWritingTo: fileURL)
        self.fileHandle?.seekToEndOfFile()
    }

    deinit {
        try? fileHandle?.close()
    }

    func log(_ message: String, level: LogLevel, file: String, function: String, line: Int) {
        guard level >= minimumLevel else { return }

        let fileName = (file as NSString).lastPathComponent
        let timestamp = DateFormatter.logTimestamp.string(from: Date())
        let logLine = "\(timestamp) \(level.prefix) [\(fileName):\(line)] \(function) - \(message)\n"

        if let data = logLine.data(using: .utf8) {
            fileHandle?.write(data)
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

// MARK: - Global Logger

/// 全局日志实例
nonisolated(unsafe) var logger: Logger = {
    #if DEBUG
    // Debug 模式：控制台 + 文件
    return CompositeLogger(loggers: [
        ConsoleLogger(minimumLevel: .debug),
        FileLogger(minimumLevel: .info)
    ])
    #else
    // Release 模式：仅文件
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
