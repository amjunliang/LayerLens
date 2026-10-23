//
//  SimulatorEncoder.swift
//  LayerLens
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import Foundation
import IOSurface
import VideoToolbox

/// 把模拟器屏幕 IOSurface 编码为 H.264 (AVCC), 输出与网页约定的帧类型:
/// 0x01 解码配置(avcC), 0x02 关键帧, 0x03 增量帧.
/// 可按比例缩小后编码: 画面显示得比原始分辨率小时, 多出的像素编码、传输、解码都是浪费, 缩放在 GPU 上完成
final class SimulatorEncoder {
    static let bitRate = 8_000_000
    static let keyFrameInterval = 240

    /// 在 VideoToolbox 的线程回调
    var onOutput: ((UInt8, Data) -> Void)?
    private var session: VTCompressionSession?
    private var width = 0
    private var height = 0
    private var forceKeyFrame = true
    private var lastConfig: Data?
    /// 缩放用, 输出编码器原生的 YUV 格式, 编码器不必再转换
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?

    deinit {
        invalidate()
    }

    /// 下一帧强制为关键帧, 用于丢帧后恢复
    func requestKeyFrame() {
        forceKeyFrame = true
    }

    /// scale 为相对原始分辨率的比例, 不大于 1
    func encode(_ surface: IOSurface, scale: Double = 1) {
        let sourceWidth = IOSurfaceGetWidth(surface)
        let sourceHeight = IOSurfaceGetHeight(surface)
        let ratio = min(max(scale, 0.1), 1)
        // H.264 要求宽高为偶数
        let w = ratio < 1 ? Int(Double(sourceWidth) * ratio / 2) * 2 : sourceWidth
        let h = ratio < 1 ? Int(Double(sourceHeight) * ratio / 2) * 2 : sourceHeight
        if session == nil || w != width || h != height {
            guard setup(width: w, height: h) else { return }
        }
        var unmanaged: Unmanaged<CVPixelBuffer>?
        guard CVPixelBufferCreateWithIOSurface(nil, surface, nil, &unmanaged) == kCVReturnSuccess,
              let source = unmanaged?.takeRetainedValue(), let session else { return }
        var buffer = source
        if w != sourceWidth || h != sourceHeight {
            guard let scaled = scaled(source) else { return }
            buffer = scaled
        }
        let options: CFDictionary? = forceKeyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        forceKeyFrame = false
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: time, duration: .invalid, frameProperties: options, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample else {
                LiveLog.write("encode frame failed: \(status)")
                return
            }
            self?.output(sample)
        }
        if status != noErr {
            LiveLog.write("encode failed: \(status)")
        }
    }

    func invalidate() {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        if let transfer {
            VTPixelTransferSessionInvalidate(transfer)
        }
        transfer = nil
        pool = nil
    }

    private func scaled(_ source: CVPixelBuffer) -> CVPixelBuffer? {
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
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        var output: CVPixelBuffer?
        guard let transfer, let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else { return nil }
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
            LiveLog.write("encoder create failed: \(status)")
            return false
        }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: kCFBooleanTrue!,
            kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse!,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: Self.bitRate,
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
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
        forceKeyFrame = true
        lastConfig = nil
        return true
    }

    private func output(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        if isKey, let format = CMSampleBufferGetFormatDescription(sample) {
            let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
            if let config = atoms?["avcC"] as? Data, config != lastConfig {
                lastConfig = config
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
