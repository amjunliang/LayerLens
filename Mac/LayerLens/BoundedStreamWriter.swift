import Foundation

/// Owned by one queue. A slow viewer is disconnected, rather than retaining unbounded data.
/// Durable recorders can replay on reconnect. Initial replay is generated only as sends drain.
final class BoundedStreamWriter {
    private let queue: DispatchQueue
    private let limit: Int
    private let send: (Data, @escaping (Bool) -> Void) -> Void
    private let close: () -> Void
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var replay: (() -> Data?)?
    private var active: Data?
    private var offset = 0
    private var sending = false
    private(set) var closed = false
    var bufferedBytes: Int { pendingBytes + (active?.count ?? 0) }

    init(queue: DispatchQueue, limit: Int = 8 * 1024 * 1024,
         send: @escaping (Data, @escaping (Bool) -> Void) -> Void, close: @escaping () -> Void) {
        self.queue = queue; self.limit = limit; self.send = send; self.close = close
    }
    func startReplay(_ replay: @escaping () -> Data?) { guard !closed else { return }; self.replay = replay; pump() }
    @discardableResult func enqueue(_ data: Data) -> Bool {
        guard !closed else { return false }
        guard data.count <= limit, bufferedBytes <= limit - data.count else { cancel(); return false }
        pending.append(data); pendingBytes += data.count; pump(); return true
    }
    func cancel() {
        guard !closed else { return }
        closed = true; pending = []; pendingBytes = 0; replay = nil; active = nil; close()
    }
    private func pump() {
        guard !closed, !sending else { return }
        if active == nil {
            if let next = replay?() { active = next }
            else {
                replay = nil
                if !pending.isEmpty { active = pending.removeFirst(); pendingBytes -= active!.count }
            }
            offset = 0
        }
        guard let active else { return }
        guard active.count + pendingBytes <= limit else { cancel(); return }
        let end = min(offset + 64 * 1024, active.count)
        let data = active.subdata(in: offset..<end)
        sending = true
        send(data) { [weak self] success in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, !self.closed else { return }
                self.sending = false
                guard success else { self.cancel(); return }
                self.offset = end
                if end == active.count { self.active = nil }
                self.pump()
            }
        }
    }
}
