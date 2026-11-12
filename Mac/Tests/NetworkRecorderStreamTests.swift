import Foundation
@_silgen_name("ll_real_setup") func setup()
@_silgen_name("ll_real_uncaptured_ok") func unknownIsNotFailure() -> Int32
@_silgen_name("ll_real_stream_ok") func streamCaptured() -> Int32
@main struct NetworkRecorderStreamTests {
    static func main() async throws {
        setup()
        precondition(unknownIsNotFailure() == 1, "An uncaptured result must not be marked as a failed request")
        let url = URL(string: "https://layerlens.test/stream")!
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        precondition(String(data: data, encoding: .utf8) == "swift async payload")
        precondition((response as? HTTPURLResponse)?.statusCode == 200)
        var ok = false
        for _ in 0..<70 {
            if streamCaptured() == 1 { ok = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(ok, "Completed AsyncBytes must retain its status and mark uncaptured body")
        print("PASS real recorder: streaming status retained and missing body marked unavailable")
    }
}
