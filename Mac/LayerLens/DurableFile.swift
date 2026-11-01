import Foundation

/// The caller may acknowledge remote data only after this operation succeeds.
enum DurableFile {
    static func write(_ data: Data, to url: URL, synchronize: Bool = true) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if synchronize {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.synchronize()
        }
    }
}
