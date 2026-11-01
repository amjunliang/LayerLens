//
//  LiveVideo.swift
//  LayerLens
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import Foundation
import IOSurface
import VideoToolbox
import CoreImage

/// 真机与模拟器共用的像素缓冲区 → H.264 编码器, 在采集队列上调用。
/// 0x01 解码配置(avcC), 0x02 关键帧, 0x03 增量帧.
/// 可按比例缩小后编码: 画面显示得比原始分辨率小时, 多出的像素编码、传输、解码都是浪费, 缩放在 GPU 上完成
final class LiveVideoEncoder {
    static let bitRate = 8_000_000
    static let keyFrameInterval = 240

    /// 在 VideoToolbox 的线程回调
    var onOutput: ((UInt8, Data) -> Void)?
    private var session: VTCompressionSession?
    private var width = 0
    private var height = 0
    private var forceKeyFrame = true
    var onError: ((String) -> Void)?
    private let outputLock = NSLock()
    private let frameLock = NSLock()
    private var activeFrame: FrameCompletion?
    private var generation = 0
    private let frameRate: Int
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var poolFormat: OSType = 0

    init(frameRate: Int = 60) { self.frameRate = frameRate }
    /// 缩放用, 输出编码器原生的 YUV 格式, 编码器不必再转换
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?

    /// A failed submission and its callback may both finish; notify the source once.
    private final class FrameCompletion {
        private let lock = NSLock()
        private var action: (() -> Void)?
        init(_ action: @escaping () -> Void) { self.action = action }
        func finish() {
            lock.lock(); let action = self.action; self.action = nil; lock.unlock()
            action?()
        }
    }

    deinit {
        invalidate()
    }

    /// 下一帧强制为关键帧, 用于丢帧后恢复
    func requestKeyFrame() {
        outputLock.lock(); defer { outputLock.unlock() }
        forceKeyFrame = true
    }

    /// scale 为相对原始分辨率的比例, 不大于 1
    func encode(_ surface: IOSurface, scale: Double = 1, completion: @escaping () -> Void = {}) {
        var unmanaged: Unmanaged<CVPixelBuffer>?
        guard CVPixelBufferCreateWithIOSurface(nil, surface, nil, &unmanaged) == kCVReturnSuccess,
              let source = unmanaged?.takeRetainedValue() else { completion(); return }
        encode(source, scale: scale, completion: completion)
    }

    /// contentSize excludes device encoder padding at the right/bottom edges.
    func encode(_ source: CVPixelBuffer, scale: Double = 1, contentSize: CGSize? = nil,
                completion: @escaping () -> Void = {}) {
        // The source retains its latest frame while this submission is outstanding.
        // Never let VideoToolbox become another unbounded frame queue.
        frameLock.lock(); let busy = activeFrame != nil; frameLock.unlock()
        guard !busy else { completion(); return }
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        let visibleWidth = min(sourceWidth, max(2, Int(contentSize?.width ?? CGFloat(sourceWidth))))
        let visibleHeight = min(sourceHeight, max(2, Int(contentSize?.height ?? CGFloat(sourceHeight))))
        let ratio = min(max(scale, 0.1), 1)
        // H.264 requires even dimensions, including odd-width physical displays.
        let w = max(2, Int(Double(visibleWidth) * ratio / 2) * 2)
        let h = max(2, Int(Double(visibleHeight) * ratio / 2) * 2)
        if session == nil || w != width || h != height {
            guard setup(width: w, height: h) else { completion(); return }
        }
        guard let session else { completion(); return }
        var buffer = source
        if w != sourceWidth || h != sourceHeight {
            guard let adjusted = scaled(source, visibleWidth: visibleWidth, visibleHeight: visibleHeight) else { completion(); return }
            buffer = adjusted
        }
        outputLock.lock()
        let currentGeneration = generation
        let options: CFDictionary? = forceKeyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        forceKeyFrame = false
        outputLock.unlock()
        let frame = FrameCompletion(completion)
        frameLock.lock(); activeFrame = frame; frameLock.unlock()
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: time, duration: .invalid, frameProperties: options, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self else { frame.finish(); return }
            self.outputLock.lock()
            if currentGeneration == self.generation {
                if status == noErr, let sample { self.output(sample) }
                else {
                    self.forceKeyFrame = true
                    LiveLog.write("encode frame failed: \(status)")
                }
            }
            self.outputLock.unlock()
            self.finish(frame)
        }
        if status != noErr {
            requestKeyFrame()
            finish(frame)
            reportError("encode failed: \(status)")
        }
    }

    func invalidate() {
        outputLock.lock(); generation += 1; outputLock.unlock()
        frameLock.lock(); let frame = activeFrame; activeFrame = nil; frameLock.unlock()
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        if let transfer {
            VTPixelTransferSessionInvalidate(transfer)
        }
        transfer = nil
        pool = nil
        frame?.finish()
    }

    private func finish(_ frame: FrameCompletion) {
        frameLock.lock()
        if activeFrame === frame { activeFrame = nil }
        frameLock.unlock()
        frame.finish()
    }

    private func scaled(_ source: CVPixelBuffer, visibleWidth: Int, visibleHeight: Int) -> CVPixelBuffer? {
        let crop = visibleWidth != CVPixelBufferGetWidth(source) || visibleHeight != CVPixelBufferGetHeight(source)
        let format = crop ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if poolFormat != format { pool = nil; poolFormat = format }
        if transfer == nil {
            var created: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created) == noErr, let created else {
                LiveLog.write("pixel transfer create failed")
                return nil
            }
            VTSessionSetProperty(created, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)
            transfer = created
        }
        if pool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        var output: CVPixelBuffer?
        guard let transfer, let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else { return nil }
        if crop {
            // CI uses a bottom-left origin; the visible device image starts at the top-left.
            let rect = CGRect(x: 0, y: CVPixelBufferGetHeight(source) - visibleHeight,
                              width: visibleWidth, height: visibleHeight)
            let image = CIImage(cvPixelBuffer: source).cropped(to: rect)
                .transformed(by: CGAffineTransform(translationX: 0, y: -rect.minY))
                .transformed(by: CGAffineTransform(scaleX: Double(width) / Double(visibleWidth),
                                                  y: Double(height) / Double(visibleHeight)))
            imageContext.render(image, to: output, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: colorSpace)
            return output
        }
        let status = VTPixelTransferSessionTransferImage(transfer, from: source, to: output)
        guard status == noErr else {
            LiveLog.write("pixel transfer failed: \(status)")
            return nil
        }
        return output
    }

    private func setup(width: Int, height: Int) -> Bool {
        invalidate()
        // 低延迟码率控制会在码流中声明最小解码缓冲, 浏览器解码器收到即输出, 否则会滞留多帧
        let specification = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue!] as CFDictionary
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264, encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let created else {
            reportError("encoder create failed: \(status)")
            return false
        }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: kCFBooleanTrue!,
            kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse!,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: Self.bitRate,
            kVTCompressionPropertyKey_ExpectedFrameRate: frameRate,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: Self.keyFrameInterval,
            // 编码速度优先, 编码器不为画质多做分析; 不缓存帧, 每帧编完立即输出
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: kCFBooleanTrue!,
            kVTCompressionPropertyKey_MaxFrameDelayCount: 0,
        ]
        for (key, value) in properties {
            VTSessionSetProperty(created, key: key, value: value as CFTypeRef)
        }
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
        self.width = width
        self.height = height
        requestKeyFrame()
        return true
    }

    private func reportError(_ message: String) {
        LiveLog.write(message)
        onError?(message)
    }

    private func output(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        if isKey, let format = CMSampleBufferGetFormatDescription(sample) {
            let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
            if let config = atoms?["avcC"] as? Data {
                onOutput?(0x01, config)
            }
        }
        var data = Data(count: CMBlockBufferGetDataLength(block))
        let copied = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { return }
        onOutput?(isKey ? 0x02 : 0x03, data)
    }
}

/// Both capture sources use this H.264 WebSocket protocol and recovery policy.
/// All methods and callbacks run on the supplied session queue.
final class LiveVideoBroadcaster {
    static let maxInFlight = 2
    private let queue: DispatchQueue
    private let onKeyFrame: () -> Void
    private var config: Data?
    private var viewers: [ObjectIdentifier: Viewer] = [:]
    private var lastKeyFrameRequest: TimeInterval = 0
    private var keyFrameRequest: DispatchWorkItem?

    private final class Viewer {
        let socket: WebSocketConnection
        var inFlight = 0
        var waitingKeyFrame = true
        var recovering = false
        var sentConfig: Data?
        var size: (width: Double, height: Double)?
        init(_ socket: WebSocketConnection) { self.socket = socket }
    }

    init(queue: DispatchQueue, onKeyFrame: @escaping () -> Void) {
        self.queue = queue
        self.onKeyFrame = onKeyFrame
    }

    var isEmpty: Bool { viewers.isEmpty }
    var targetSize: (width: Double, height: Double)? {
        guard !viewers.isEmpty else { return nil }
        var target = (width: 0.0, height: 0.0)
        for viewer in viewers.values {
            guard let size = viewer.size else { return nil }
            target = (max(target.width, size.width), max(target.height, size.height))
        }
        return target
    }

    func add(_ socket: WebSocketConnection) {
        let viewer = Viewer(socket)
        viewers[ObjectIdentifier(socket)] = viewer
        sendConfig(to: viewer)
        requestKeyFrame()
    }

    func remove(_ id: ObjectIdentifier) { viewers[id] = nil }

    func setSize(_ size: (width: Double, height: Double), of id: ObjectIdentifier) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        viewers[id]?.size = size
    }

    func forEachSocket(_ action: (WebSocketConnection) -> Void) {
        for viewer in viewers.values { action(viewer.socket) }
    }

    /// Invalidate configuration after restarting an encoder, preserving live viewers.
    func reset() {
        config = nil
        keyFrameRequest?.cancel(); keyFrameRequest = nil
        lastKeyFrameRequest = 0
        for viewer in viewers.values { viewer.waitingKeyFrame = true; viewer.sentConfig = nil }
    }

    func broadcast(_ type: UInt8, _ data: Data) {
        if type == 0x01 {
            guard data != config else { return }
            config = data
            for viewer in viewers.values {
                viewer.waitingKeyFrame = true
                if !viewer.recovering && viewer.inFlight < Self.maxInFlight { sendConfig(to: viewer) }
                else { viewer.recovering = true }
            }
            return
        }
        let packet = Data([type]) + data
        for viewer in viewers.values {
            // Once a delta is skipped, never send more deltas before a fresh keyframe.
            guard !viewer.recovering else { continue }
            if viewer.inFlight >= Self.maxInFlight {
                viewer.waitingKeyFrame = true
                viewer.recovering = true
                continue
            }
            if type == 0x02 {
                if viewer.sentConfig != config {
                    // Configuration changes also obey the send bound. Keep only
                    // the newest config, then send it with a fresh keyframe.
                    guard viewer.inFlight == 0 else { viewer.recovering = true; continue }
                    sendConfig(to: viewer)
                }
                viewer.waitingKeyFrame = false
            }
            guard !viewer.waitingKeyFrame else { continue }
            send(packet, to: viewer)
        }
    }

    private func sendConfig(to viewer: Viewer) {
        guard let config, viewer.sentConfig != config else { return }
        viewer.sentConfig = config
        send(Data([0x01]) + config, to: viewer)
    }

    private func send(_ packet: Data, to viewer: Viewer) {
        viewer.inFlight += 1
        viewer.socket.sendBinary(packet) { [weak self, weak viewer] success in
            self?.queue.async {
                guard let self, let viewer,
                      self.viewers[ObjectIdentifier(viewer.socket)] === viewer else { return }
                viewer.inFlight = max(0, viewer.inFlight - 1)
                if !success { viewer.socket.close(); return }
                if viewer.recovering && viewer.inFlight == 0 {
                    viewer.recovering = false
                    self.requestKeyFrame()
                }
            }
        }
    }

    func requestKeyFrame() {
        guard !viewers.isEmpty, keyFrameRequest == nil else { return }
        let wait = lastKeyFrameRequest + 0.5 - CFAbsoluteTimeGetCurrent()
        if wait > 0 {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.keyFrameRequest = nil
                self.requestKeyFrame()
            }
            keyFrameRequest = work
            queue.asyncAfter(deadline: .now() + wait, execute: work)
            return
        }
        lastKeyFrameRequest = CFAbsoluteTimeGetCurrent()
        onKeyFrame()
    }
}
