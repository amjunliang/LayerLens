import Darwin
import Foundation

/// Queue-owned nonblocking PTY writer. No write can stall terminal output, close or quit.
final class PTYInputWriter {
    private let fd: Int32
    private let queue: DispatchQueue
    private let limit: Int
    private var data = Data()
    private var offset = 0
    private var ready: DispatchSourceWrite?
    private var closed = false
    var onError: (() -> Void)?
    var bufferedBytes: Int { data.count - offset }
    init(fd: Int32, queue: DispatchQueue, limit: Int = 1024 * 1024) {
        self.fd = fd; self.queue = queue; self.limit = limit
        let flags = fcntl(fd, F_GETFL)
        if flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 { closed = true }
    }
    @discardableResult func enqueue(_ input: Data) -> Bool {
        guard !closed, input.count <= limit, bufferedBytes <= limit - input.count else { return false }
        if offset > 0 { data.removeFirst(offset); offset = 0 }
        data.append(input); drain(); return !closed
    }
    func cancel() { closed = true; ready?.cancel(); ready = nil; data = Data(); offset = 0 }
    private func drain() {
        var budget = 64 * 1024
        while !closed && offset < data.count && budget > 0 {
            let count = min(data.count - offset, budget)
            let written = data.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), count) }
            if written > 0 { offset += written; budget -= written; continue }
            if written < 0 && errno == EINTR { continue }
            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { break }
            cancel(); onError?(); return
        }
        if offset == data.count {
            data = Data(); offset = 0; ready?.cancel(); ready = nil
        } else if ready == nil && !closed {
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.drain() }
            ready = source; source.resume()
        }
    }
}
