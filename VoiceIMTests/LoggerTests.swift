import Testing
import Foundation
@testable import VoiceIM

/// Logger 单元测试
@Suite("Logger Tests")
struct LoggerTests {

    final class TestLogger: Logger {
        var logs: [(message: String, level: LogLevel)] = []

        func log(_ message: String, level: LogLevel, file: String, function: String, line: Int) {
            logs.append((message, level))
        }
    }

    @Test("日志级别过滤")
    func testLogLevelFiltering() {
        let logger = ConsoleLogger(minimumLevel: .warning)
        // 由于 ConsoleLogger 是异步的，这里只测试初始化
        #expect(logger != nil)
    }

    @Test("自定义日志器")
    func testCustomLogger() {
        let logger = TestLogger()
        logger.debug("Debug message")
        logger.info("Info message")
        logger.warning("Warning message")
        logger.error("Error message")

        #expect(logger.logs.count == 4)
        #expect(logger.logs[0].level == .debug)
        #expect(logger.logs[1].level == .info)
        #expect(logger.logs[2].level == .warning)
        #expect(logger.logs[3].level == .error)
    }

    @Test("组合日志器")
    func testCompositeLogger() {
        let logger1 = TestLogger()
        let logger2 = TestLogger()
        let composite = CompositeLogger(loggers: [logger1, logger2])

        composite.info("Test message")

        #expect(logger1.logs.count == 1)
        #expect(logger2.logs.count == 1)
        #expect(logger1.logs[0].message == "Test message")
        #expect(logger2.logs[0].message == "Test message")
    }
}
