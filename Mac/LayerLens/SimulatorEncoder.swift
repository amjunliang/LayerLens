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
/// 0x01 解码配置(avcC), 0x02 关键帧, 0x03 增量帧
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

    deinit {
        invalidate()
    }

    /// 下一帧强制为关键帧, 用于丢帧后恢复
    func requestKeyFrame() {
        forceKeyFrame = true
    }

    func encode(_ surface: IOSurface) {
        let w = IOSurfaceGetWidth(surface)
        let h = IOSurfaceGetHeight(surface)
        if session == nil || w != width || h != height {
            guard setup(width: w, height: h) else { return }
        }
        var unmanaged: Unmanaged<CVPixelBuffer>?
        guard CVPixelBufferCreateWithIOSurface(nil, surface, nil, &unmanaged) == kCVReturnSuccess,
              let buffer = unmanaged?.takeRetainedValue(), let session else { return }
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
