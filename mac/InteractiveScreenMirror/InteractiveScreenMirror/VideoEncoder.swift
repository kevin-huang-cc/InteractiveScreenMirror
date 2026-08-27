import Foundation
import VideoToolbox
import CoreMedia

final class VideoEncoder {
    private var session: VTCompressionSession?
    private let width: Int32
    private let height: Int32
    var onParameterSets: (Data) -> Void = { _ in }
    var onFrame: (Data) -> Void = { _ in }
    private var sentParams = false

    init(width: Int, height: Int) throws {
        self.width = Int32(width)
        self.height = Int32(height)

        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: self.width, height: self.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil,
            compressionSessionOut: &s)
        guard status == noErr, let session = s else {
            throw NSError(domain: "ISM", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionCreate failed"])
        }
        self.session = session

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 60))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 60))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 40_000_000))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [NSNumber(value: 60_000_000 / 8), NSNumber(value: 1)] as CFArray)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil,
            outputHandler: { [weak self] status, _, sampleBuffer in
                guard status == noErr, let sb = sampleBuffer else { return }
                self?.handleEncoded(sb)
            })
    }

    private func handleEncoded(_ sb: CMSampleBuffer) {
        if !sentParams, let fd = CMSampleBufferGetFormatDescription(sb) {
            if let params = Self.extractParameterSets(fd) {
                onParameterSets(params)
                sentParams = true
            }
        }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        var totalLen = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        let s = CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLen, dataPointerOut: &dataPtr)
        guard s == kCMBlockBufferNoErr, let p = dataPtr else { return }
        let data = Data(bytes: p, count: totalLen)
        onFrame(data)
    }

    private static func extractParameterSets(_ fd: CMVideoFormatDescription) -> Data? {
        var spsPtr: UnsafePointer<UInt8>?
        var spsLen = 0
        var nalHeaderLen: Int32 = 0
        var ppsPtr: UnsafePointer<UInt8>?
        var ppsLen = 0
        let s1 = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0,
            parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsLen,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: &nalHeaderLen)
        let s2 = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsLen,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        guard s1 == noErr, s2 == noErr, let sps = spsPtr, let pps = ppsPtr else { return nil }

        var out = Data()
        var spsLen32 = UInt32(spsLen).bigEndian
        withUnsafeBytes(of: &spsLen32) { out.append(contentsOf: $0) }
        out.append(sps, count: spsLen)
        var ppsLen32 = UInt32(ppsLen).bigEndian
        withUnsafeBytes(of: &ppsLen32) { out.append(contentsOf: $0) }
        out.append(pps, count: ppsLen)
        return out
    }
}
