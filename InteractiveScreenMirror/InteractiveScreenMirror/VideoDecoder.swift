import Foundation
import CoreMedia
import VideoToolbox

final class VideoDecoder {
    private var formatDescription: CMVideoFormatDescription?
    private var lastParams: Data?
    private var needsKeyframe = false
    private var session: VTDecompressionSession?
    private var isHEVC = true

    /// Decoded BGRA frames, delivered on VideoToolbox's callback thread.
    var onPixelBuffer: (CVPixelBuffer) -> Void = { _ in }

    var isReady: Bool { formatDescription != nil }

    /// Called after a frame is lost. Every later P-frame references data we
    /// never received, so decoding them paints visible corruption. Skip until
    /// the next IDR — a brief hold looks far better than breakup.
    func requestResync() { needsKeyframe = true }

    /// Parameter sets arrive with every keyframe over UDP. Rebuilding the format
    /// description each time would churn the decoder, so ignore repeats.
    /// Payload: [1B codec 'h'|'v'][1B count]{[4B len][bytes]}…
    func handleParameterSets(_ data: Data) {
        guard data != lastParams, data.count >= 2 else { return }
        let codec = data[data.startIndex], count = Int(data[data.startIndex + 1])
        var cursor = 2
        var sets: [Data] = []
        for _ in 0..<count {
            guard let d = readChunk(data, cursor: &cursor) else { return }
            sets.append(d)
        }
        isHEVC = codec == UInt8(ascii: "v")

        // Copy each set into its own buffer so the pointers stay valid for the call.
        let buffers: [UnsafeMutableBufferPointer<UInt8>] = sets.map { d in
            let b = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(d.count, 1))
            _ = b.initialize(from: d)
            return b
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0.baseAddress!) }
        let sizes = sets.map(\.count)

        var fd: CMVideoFormatDescription?
        pointers.withUnsafeBufferPointer { pb in
            sizes.withUnsafeBufferPointer { sb in
                if isHEVC {
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                        parameterSetPointers: pb.baseAddress!, parameterSetSizes: sb.baseAddress!,
                        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
                } else {
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                        parameterSetPointers: pb.baseAddress!, parameterSetSizes: sb.baseAddress!,
                        nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
                }
            }
        }
        if let fd {
            formatDescription = fd
            lastParams = data
            rebuildSession(fd)
        }
    }

    /// The display layer used to decode for us; a RealityKit texture needs the
    /// raw pixels, so decode here. BGRA so the buffer blits straight into a
    /// Metal drawable without a colour-space pass.
    private func rebuildSession(_ fd: CMVideoFormatDescription) {
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var cb = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, _, image, _, _ in
                guard status == noErr, let image, let refcon else { return }
                Unmanaged<VideoDecoder>.fromOpaque(refcon).takeUnretainedValue().onPixelBuffer(image)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        var s: VTDecompressionSession?
        VTDecompressionSessionCreate(allocator: nil, formatDescription: fd,
                                     decoderSpecification: nil,
                                     imageBufferAttributes: attrs as CFDictionary,
                                     outputCallback: &cb, decompressionSessionOut: &s)
        session = s
    }

    deinit { if let s = session { VTDecompressionSessionInvalidate(s) } }

    func handleFrame(_ data: Data) {
        guard let fd = formatDescription, let session else { return }
        if needsKeyframe {
            guard Self.containsIDR(data, hevc: isHEVC) else { return }
            needsKeyframe = false
        }

        // Let CMBlockBuffer own its allocation, then copy in. The previous
        // version handed it a malloc'd pointer with a mismatched allocator.
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: data.count, blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0, dataLength: data.count,
                flags: 0, blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
              let bb = blockBuffer,
              CMBlockBufferAssureBlockMemory(bb) == kCMBlockBufferNoErr else { return }

        let copied = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: bb,
                                                 offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == kCMBlockBufferNoErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = data.count
        guard CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: fd,
                sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer) == noErr,
              let sb = sampleBuffer else { return }

        // No timestamps and no reordering: the encoder emits I/P only, so the
        // synchronous path returns each frame before the next arrives.
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [],
                                          frameRefcon: nil, infoFlagsOut: nil)
    }

    /// Walks the length-prefixed NAL units looking for an IDR: H.264 type 5,
    /// HEVC types 19–21 (IDR_W_RADL, IDR_N_LP, CRA).
    private static func containsIDR(_ data: Data, hevc: Bool) -> Bool {
        var i = data.startIndex
        while i + 4 <= data.endIndex {
            let len = Int(data[i..<(i + 4)].withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).bigEndian
            })
            i += 4
            guard len > 0, i + len <= data.endIndex else { return false }
            if hevc {
                let t = (data[i] >> 1) & 0x3F
                if (19...21).contains(t) { return true }
            } else if data[i] & 0x1F == 5 {
                return true
            }
            i += len
        }
        return false
    }

    private func readChunk(_ data: Data, cursor: inout Int) -> Data? {
        guard cursor + 4 <= data.count else { return nil }
        let len = Int(data[cursor..<(cursor + 4)].withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).bigEndian
        })
        cursor += 4
        guard len > 0, cursor + len <= data.count else { return nil }
        defer { cursor += len }
        return data.subdata(in: cursor..<(cursor + len))
    }
}
