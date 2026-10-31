// Standalone checks: compile this file together with LayerLens/LiveVideo.swift.
import Foundation
import VideoToolbox
import IOSurface

// Test transport: completions are held to simulate a stalled WebSocket client.
final class WebSocketConnection {
    var packets: [Data] = []
    var completions: [(Bool) -> Void] = []
    func sendBinary(_ packet: Data, completion: @escaping (Bool) -> Void) {
        packets.append(packet); completions.append(completion)
    }
    func close() {}
}
enum LiveLog { static func write(_ text: String) { print(text) } }

func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

@main enum LiveVideoTests {
    static func main() {
        broadcastRecovery()
        encodeAndCrop()
        print("PASS shared H.264 pipeline checks")
    }

    static func broadcastRecovery() {
        let queue = DispatchQueue(label: "test.broadcast")
        let requested = DispatchSemaphore(value: 0)
        let video = LiveVideoBroadcaster(queue: queue) { requested.signal() }
        let slow = WebSocketConnection(), joined = WebSocketConnection()
        let config = Data([1, 100, 0, 40])
        queue.sync {
            video.add(slow)
            video.broadcast(1, config)
            video.broadcast(2, Data([0x65]))
            for _ in 0..<20 { video.broadcast(3, Data([0x41])) }
            require(slow.packets.count == LiveVideoBroadcaster.maxInFlight, "Unbounded send queue")
            require(slow.packets.map { $0[0] } == [1,2,3,3,3,3], "Unexpected packet order")
        }
        require(requested.wait(timeout: .now() + 1) == .success, "Initial keyframe not requested")
        let completions = queue.sync { slow.completions }
        completions.forEach { $0(true) }
        require(requested.wait(timeout: .now() + 2) == .success, "No keyframe request after draining")
        queue.sync {
            let count = slow.packets.count
            video.broadcast(3, Data([0x41]))
            require(slow.packets.count == count, "Delta sent after a dropped reference")
            video.add(joined)
            video.broadcast(3, Data([0x41]))
            require(joined.packets.count == 1 && joined.packets[0][0] == 1, "New viewer did not wait for keyframe")
            video.broadcast(2, Data([0x65]))
            require(slow.packets.last?[0] == 2 && joined.packets.last?[0] == 2, "Keyframe did not recover viewers")
            video.broadcast(1, Data([1, 100, 0, 41]))
            let count2 = joined.packets.count
            video.broadcast(3, Data([0x41]))
            require(joined.packets.count == count2, "Config change did not wait for keyframe")
            video.remove(ObjectIdentifier(slow)); video.remove(ObjectIdentifier(joined)); video.reset()
        }
        print("PASS bounded sends, slow-client recovery, late join and changed configuration")
    }

    static func encodeAndCrop() {
        var source: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        require(CVPixelBufferCreate(nil, 128, 160, kCVPixelFormatType_32BGRA, attrs, &source) == noErr, "Create source")
        let pixels = source!
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<160 { for x in 0..<128 {
            let p = base + y * stride + x * 4
            let rgb: (UInt8, UInt8, UInt8) = y >= 150 ? (0,255,0) : x >= 117 ? (255,0,255) : y < 75 ? (255,0,0) : (0,0,255)
            p[0] = rgb.2; p[1] = rgb.1; p[2] = rgb.0; p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let encoder = LiveVideoEncoder(frameRate: 30)
        var config = Data(), encoded = Data()
        let ready = DispatchSemaphore(value: 0)
        encoder.onOutput = { type, data in
            if type == 1 { config = data }
            if type == 2 { encoded = data; ready.signal() }
        }
        encoder.encode(pixels, contentSize: CGSize(width: 117, height: 150))
        require(ready.wait(timeout: .now() + 5) == .success, "No cropped H.264 keyframe")
        let decoded = decode(config: config, frame: encoded)
        require(CVPixelBufferGetWidth(decoded) == 116 && CVPixelBufferGetHeight(decoded) == 150, "Odd display dimensions not normalized")
        CVPixelBufferLockBaseAddress(decoded, .readOnly)
        let output = CVPixelBufferGetBaseAddress(decoded)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(decoded)
        for x in [8, 108] {
            let top = output + 8 * row + x * 4
            let bottom = output + 142 * row + x * 4
            require(Int(top[2]) > Int(top[0]) + 100 && top[1] < 70, "Top/red or right padding crop incorrect")
            require(Int(bottom[0]) > Int(bottom[2]) + 100 && bottom[1] < 70, "Bottom/blue or bottom padding crop incorrect")
        }
        CVPixelBufferUnlockBaseAddress(decoded, .readOnly)
        // The same encoder also accepts Simulator IOSurface input and resizes it.
        let surface = unsafeBitCast(CVPixelBufferGetIOSurface(pixels)!.takeUnretainedValue(), to: IOSurface.self)
        encoder.encode(surface, scale: 0.5)
        require(ready.wait(timeout: .now() + 5) == .success, "No resized Simulator keyframe")
        let resized = decode(config: config, frame: encoded)
        require(CVPixelBufferGetWidth(resized) == 64 && CVPixelBufferGetHeight(resized) == 80, "Simulator resize incorrect")
        encoder.invalidate()
        print("PASS H.264 roundtrip: odd-width device crop, padding removal, colors and IOSurface resize")
    }

    static func decode(config: Data, frame: Data) -> CVPixelBuffer {
        let bytes = [UInt8](config)
        var position = 6
        var sets: [NSData] = []
        func readSets(_ count: Int) {
            for _ in 0..<count {
                let length = Int(bytes[position]) * 256 + Int(bytes[position + 1]); position += 2
                sets.append(Data(bytes[position..<(position + length)]) as NSData); position += length
            }
        }
        require(bytes.count >= 7, "Missing AVC config")
        readSets(Int(bytes[5] & 31))
        let pps = Int(bytes[position]); position += 1; readSets(pps)
        var pointers = sets.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        var lengths = sets.map { $0.length }
        var format: CMFormatDescription?
        require(CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count,
            parameterSetPointers: &pointers, parameterSetSizes: &lengths, nalUnitHeaderLength: 4,
            formatDescriptionOut: &format) == noErr, "Create H.264 description")
        var decoder: VTDecompressionSession?
        let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        require(VTDecompressionSessionCreate(allocator: nil, formatDescription: format!, decoderSpecification: nil,
            imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &decoder) == noErr, "Create decoder")
        var block: CMBlockBuffer?
        require(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frame.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: frame.count,
            flags: 0, blockBufferOut: &block) == noErr, "Create block")
        frame.withUnsafeBytes { raw in
            require(CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0,
                                                 dataLength: raw.count) == noErr, "Copy block")
        }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var length = frame.count
        require(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &length, sampleBufferOut: &sample) == noErr, "Create sample")
        let ready = DispatchSemaphore(value: 0)
        var image: CVPixelBuffer?
        require(VTDecompressionSessionDecodeFrame(decoder!, sampleBuffer: sample!, flags: [], infoFlagsOut: nil) {
            status, _, pixels, _, _ in
            if status == noErr { image = pixels }; ready.signal()
        } == noErr, "Decode frame")
        require(ready.wait(timeout: .now() + 5) == .success && image != nil, "Decode output")
        VTDecompressionSessionInvalidate(decoder!)
        return image!
    }
}
