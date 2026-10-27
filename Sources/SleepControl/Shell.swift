import Foundation

/// 同步执行一个外部命令，返回退出码与合并后的输出。
enum Shell {
    struct Result {
        let status: Int32
        let output: String
    }

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 120) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            if process.isRunning { process.terminate() }
        }
        timer.resume()
        defer { timer.cancel() }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return Result(status: process.terminationStatus, output: text)
    }
}
