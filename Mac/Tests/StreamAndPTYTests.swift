import Darwin
import Foundation

@main struct StreamAndPTYTests {
    static func main() {
        let queue = DispatchQueue(label: "test.bounded-writers")
        var pending: [(Data, (Bool) -> Void)] = [], sent = Data(), closed = false, generated = 0
        let writer = BoundedStreamWriter(queue: queue, limit: 1024, send: { data, done in pending.append((data, done)) }, close: { closed = true })
        queue.sync {
            writer.startReplay { generated += 1; return generated <= 3 ? Data([UInt8(96 + generated)]) : nil }
            writer.enqueue(Data("d".utf8))
            assert(generated == 1 && pending.count == 1, "Replay must be lazy and only one send may be outstanding")
        }
        for _ in 0..<4 {
            let part = queue.sync { pending.removeFirst() }
            sent.append(part.0); part.1(true)
            queue.sync {}
            assert(queue.sync { pending.count <= 1 })
        }
        assert(sent == Data("abcd".utf8) && !closed)
        queue.sync { writer.enqueue(Data(repeating: 1, count: 900)); assert(writer.bufferedBytes == 900); writer.enqueue(Data(repeating: 2, count: 200)) }
        assert(closed && queue.sync { writer.bufferedBytes } == 0)
        var largeParts: [(Data,(Bool)->Void)] = []
        let chunked = BoundedStreamWriter(queue: queue, limit: 1024 * 1024, send: { largeParts.append(($0,$1)) }, close: {})
        _ = queue.sync { chunked.enqueue(Data(repeating: 7, count: 512 * 1024)) }
        var bytes = 0
        while queue.sync(execute: { !largeParts.isEmpty }) {
            let part = queue.sync { largeParts.removeFirst() }
            assert(part.0.count <= 64 * 1024); bytes += part.0.count
            part.1(true); queue.sync {}
        }
        assert(bytes == 512 * 1024)
        var master: Int32 = -1, slave: Int32 = -1
        assert(openpty(&master, &slave, nil, nil, nil) == 0)
        var attrs = termios(); tcgetattr(slave, &attrs); cfmakeraw(&attrs); tcsetattr(slave, TCSANOW, &attrs)
        _ = fcntl(slave, F_SETFL, fcntl(slave, F_GETFL) | O_NONBLOCK)
        let input = PTYInputWriter(fd: master, queue: queue)
        let payload = Data(repeating: 120, count: 512 * 1024)
        let ready = DispatchSemaphore(value: 0)
        queue.async { assert(input.enqueue(payload)); ready.signal() }
        assert(ready.wait(timeout: .now()+1) == .success, "Large input must return without blocking the terminal queue")
        let probe = DispatchSemaphore(value: 0); queue.async { probe.signal() }
        assert(probe.wait(timeout: .now()+0.2) == .success)
        queue.sync { assert(input.bufferedBytes > 0); assert(!input.enqueue(Data(repeating: 1, count: 1024 * 1024))) }
        var received = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(5)
        while received.count < payload.count && Date() < deadline {
            let count = read(slave, &buffer, buffer.count)
            if count > 0 { received.append(contentsOf: buffer.prefix(count)) } else { Thread.sleep(forTimeInterval: 0.001) }
        }
        assert(received == payload, "Nonblocking writes must preserve order and retry partial writes")
        queue.sync { input.cancel(); assert(input.bufferedBytes == 0); chunked.cancel() }
        close(master); close(slave)
        print("PASS lazy replay ordering, bounded slow-viewer queues, send chunk size, nonblocking large PTY input, partial-write retry and queue cancellation")
    }
}
