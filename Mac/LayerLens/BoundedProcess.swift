import Foundation

/// 只结束本次启动的查询进程, 不操作 CoreSimulator / CoreDevice 的共享服务。
enum BoundedProcess {
    private static let registryLock = NSLock()
    private static var processes: [Int32: Process] = [:]
    private static var stopping = false
    static var activeCount: Int { registryLock.lock(); defer { registryLock.unlock() }; return processes.count }

    /// 主程序退出时同步结束我们自己的查询, 防止退出早于超时定时器而遗留进程。
    static func stopAll() {
        registryLock.lock(); stopping = true; let running = Array(processes.values); registryLock.unlock()
        running.filter { $0.isRunning }.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(0.5)
        while running.contains(where: { $0.isRunning }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        for process in running where process.isRunning { kill(process.processIdentifier, SIGKILL) }
        running.forEach { $0.waitUntilExit() }
    }
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> Data? {
        guard let result = capture(path, arguments, timeout: timeout, includeError: false),
              !result.timedOut, result.status == 0 else { return nil }
        return result.data
    }
    struct Result {
        let data: Data
        let status: Int32
        let timedOut: Bool
    }
    /// 合并错误输出, 避免两个管道互相等待; 保留退出状态供调用方解释错误。
    static func capture(_ path: String, _ arguments: [String], timeout: TimeInterval, includeError: Bool = true,
                        environment: [String: String]? = nil, directory: URL? = nil, hardTimeout: Bool = false) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = includeError ? pipe : FileHandle.nullDevice
        registryLock.lock()
        guard !stopping else { registryLock.unlock(); return nil }
        do { try process.run() } catch { registryLock.unlock(); return nil }
        processes[process.processIdentifier] = process
        registryLock.unlock()
        defer { registryLock.lock(); processes[process.processIdentifier] = nil; registryLock.unlock() }
        let lock = NSLock()
        var timedOut = false
        let timer = DispatchWorkItem {
            lock.lock(); timedOut = process.isRunning; let stop = timedOut; lock.unlock()
            guard stop else { return }
            if hardTimeout {
                kill(process.processIdentifier, SIGKILL)
                return
            }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data: Data
        if hardTimeout {
            let fd = pipe.fileHandleForReading.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 { output.append(buffer, count: count) }
                else if count == 0 { break }
                else if errno == EINTR { continue }
                else if errno == EAGAIN || errno == EWOULDBLOCK {
                    if !process.isRunning { break }
                    Thread.sleep(forTimeInterval: 0.01)
                } else { break }
            }
            data = output
        } else {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
        }
        process.waitUntilExit()
        timer.cancel()
        lock.lock(); let failed = timedOut; lock.unlock()
        return Result(data: data, status: process.terminationStatus, timedOut: failed)
    }
}
