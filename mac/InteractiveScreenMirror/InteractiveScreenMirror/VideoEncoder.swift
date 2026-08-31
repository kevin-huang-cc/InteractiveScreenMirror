import Foundation
import VideoToolbox
import CoreMedia

final class VideoEncoder {
    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var pending = 0
    private var forceNextKeyframe = false

    var onParameterSets: (Data) -> Void = { _ in }
    /// (frame bytes, isKeyframe)
    var onFrame: (Data, Bool) -> Void = { _, _ in }

    init(width: Int, height: Int) throws {
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &s)
        guard status == noErr, let session = s else {
            throw NSError(domain: "ISM", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionCreate failed"])
        }
        self.session = session

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // Without this the encoder may hold frames for lookahead — pure added latency.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 0))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)
        // Shorter GOP: a lost frame resyncs in <= 0.5s even if a keyframe request is dropped.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 30))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 60))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 25_000_000))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [NSNumber(value: 40_000_000 / 8), NSNumber(value: 1)] as CFArray)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    /// True if the encoder is backed up; the caller should drop this frame
    /// rather than queue it. Dropping at capture beats buffering latency.
    var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return pending >= 2
    }

    func requestKeyframe() {
        lock.lock(); forceNextKeyframe = true; lock.unlock()
    }

    func encode(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        lock.lock()
        pending += 1
        let force = forceNextKeyframe
        forceNextKeyframe = false
        lock.unlock()

        let props: CFDictionary? = force
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
            : nil

        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: props, infoFlagsOut: nil,
            outputHandler: { [weak self] status, _, sampleBuffer in
                guard let self else { return }
                self.lock.lock(); self.pending -= 1; self.lock.unlock()
                guard status == noErr, let sb = sampleBuffer else { return }
                self.handleEncoded(sb)
            })
    }

    private func handleEncoded(_ sb: CMSampleBuffer) {
        let key = Self.isKeyframe(sb)
        // Re-send parameter sets with every keyframe: over UDP there is no
        // retransmit, so a client that missed them recovers on the next GOP.
        if key, let fd = CMSampleBufferGetFormatDescription(sb),
           let params = Self.extractParameterSets(fd) {
            onParameterSets(params)
        }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        var len = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &len, dataPointerOut: &ptr) == kCMBlockBufferNoErr,
              let p = ptr else { return }
        onFrame(Data(bytes: p, count: len), key)
    }

    private static func isKeyframe(_ sb: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false),
              CFArrayGetCount(arr) > 0 else { return true }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFDictionary.self)
        // Absence of NotSync means this is a sync (key) frame.
        return !CFDictionaryContainsKey(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
    }

    private static func extractParameterSets(_ fd: CMVideoFormatDescription) -> Data? {
        var spsPtr: UnsafePointer<UInt8>?, ppsPtr: UnsafePointer<UInt8>?
        var spsLen = 0, ppsLen = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fd, parameterSetIndex: 0, parameterSetPointerOut: &spsPtr,
                parameterSetSizeOut: &spsLen, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil) == noErr,
              CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fd, parameterSetIndex: 1, parameterSetPointerOut: &ppsPtr,
                parameterSetSizeOut: &ppsLen, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil) == noErr,
              let sps = spsPtr, let pps = ppsPtr else { return nil }

        var out = Data()
        var a = UInt32(spsLen).bigEndian
        withUnsafeBytes(of: &a) { out.append(contentsOf: $0) }
        out.append(sps, count: spsLen)
        var b = UInt32(ppsLen).bigEndian
        withUnsafeBytes(of: &b) { out.append(contentsOf: $0) }
        out.append(pps, count: ppsLen)
        return out
    }
}
