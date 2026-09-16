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

    init(width: Int, height: Int, fps: Int) throws {
        var s: VTCompressionSession?
        // Apple Silicon's low-latency rate controller: shorter encode pipeline
        // and steadier output size per frame, which matters more than peak
        // quality for a live desktop.
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue as Any
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &s)
        guard status == noErr, let session = s else {
            throw NSError(domain: "ISM", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionCreate failed"])
        }
        self.session = session

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        // HEVC: H.264 tops out at 4096 wide, and a 2x ultrawide is 5120.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // Without this the encoder may hold frames for lookahead — pure added latency.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 0))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)
        // Backstop only — loss recovery is driven by keyframe requests, so
        // keyframes need not be frequent. Each one is a burst of ~44 datagrams
        // and any single loss costs the whole frame.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps * 2))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        // Text is the worst case for 4:2:0 — sharp edges and high frequency
        // detail. Scale bitrate with pixels; HEVC needs roughly half of H.264.
        nominalBitrate = min(80_000_000, max(12_000_000, width * height * fps / 20))
        setBitrate(nominalBitrate)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    /// What this stream would use alone. The budget caps it when others share the link.
    let nominalBitrate: Int

    /// Safe to call while encoding; the rate controller picks it up on the next frame.
    func setBitrate(_ bitrate: Int) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [NSNumber(value: bitrate * 3 / 2 / 8), NSNumber(value: 1)] as CFArray)
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

    /// Wire PARAM payload: [1B codec 'h'|'v'][1B count]{[4B len][bytes]}…
    /// HEVC carries VPS, SPS, PPS; H.264 would carry two.
    private static func extractParameterSets(_ fd: CMVideoFormatDescription) -> Data? {
        var count = 0
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr, count > 0 else { return nil }
        var out = Data([UInt8(ascii: "v"), UInt8(count)])
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var len = 0
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    fd, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &len,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p = ptr else { return nil }
            var n = UInt32(len).bigEndian
            withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }
            out.append(p, count: len)
        }
        return out
    }
}
