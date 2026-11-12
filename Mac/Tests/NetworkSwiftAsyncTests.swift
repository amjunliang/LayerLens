import Foundation
@_silgen_name("ll_async_setup") func llSetup()
@_silgen_name("ll_async_count") func llCount() -> Int32
@_silgen_name("ll_async_status") func llStatus() -> Int32
@_silgen_name("ll_async_error") func llError() -> Int32
@_silgen_name("ll_async_streamed") func llStreamed() -> Int32
@_silgen_name("ll_async_upload") func llUpload() -> Int32
@_silgen_name("ll_async_upload_file") func llUploadFile() -> Int32
@_silgen_name("ll_async_body") func llBody() -> Int32
@main struct NetworkSwiftAsyncTests {
    static func main() async throws {
        llSetup()
        let request = URLRequest(url: URL(string: "https://layerlens.test/async")!)
        let (data, response) = try await URLSession.shared.data(for: request)
        precondition(String(data: data, encoding: .utf8) == "swift async payload")
        precondition((response as? HTTPURLResponse)?.statusCode == 200)
        precondition(llCount() == 1 && llStatus() == 200 && llBody() == 1, "Swift async response must be captured once with status and body")
        let (byURL, _) = try await URLSession.shared.data(from: request.url!)
        precondition(byURL == data && llCount() == 2 && llStatus() == 200 && llBody() == 1, "data(from:) must capture its response")
        let callbackData: Data? = await withCheckedContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, _, _ in continuation.resume(returning: data) }.resume()
        }
        precondition(callbackData == data && llCount() == 3, "Completion-handler requests must be captured exactly once")
        do {
            _ = try await URLSession.shared.data(from: URL(string: "https://layerlens.test/failure")!)
            preconditionFailure("The request must fail")
        } catch {
            precondition(llCount() == 4 && llError() == NSURLErrorTimedOut, "Swift async network errors must be captured")
        }
        let (uploadResponse, _) = try await URLSession.shared.upload(for: request, from: Data("upload bytes".utf8))
        precondition(uploadResponse == data && llCount() == 5 && llStatus() == 200 && llBody() == 1 && llUpload() == 1, "Async upload must capture body and response")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("upload bytes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let (_, uploadFileResponse) = try await URLSession.shared.upload(for: request, fromFile: file)
        precondition((uploadFileResponse as? HTTPURLResponse)?.statusCode == 200 && llCount() == 6 && llUploadFile() == 1, "Async file upload must capture completion and file source")
        let (downloaded, downloadResponse) = try await URLSession.shared.download(from: request.url!)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        precondition((downloadResponse as? HTTPURLResponse)?.statusCode == 200 && llCount() == 7, "Async download must capture completion")
        let (bytes, bytesResponse) = try await URLSession.shared.bytes(for: request)
        var streamData = Data()
        for try await byte in bytes { streamData.append(byte) }
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(streamData == data && (bytesResponse as? HTTPURLResponse)?.statusCode == 200, "Streaming must remain unchanged")
        precondition(llCount() == 7 || (llCount() == 8 && llStreamed() == data.count), "AsyncBytes must not disrupt completion callbacks")
        print("PASS Swift async data, upload, download, streaming behavior, error and completion-handler compatibility")
    }
}
