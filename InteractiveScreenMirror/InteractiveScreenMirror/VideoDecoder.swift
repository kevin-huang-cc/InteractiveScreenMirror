import Foundation
import CoreMedia
import VideoToolbox

final class VideoDecoder {
    private var formatDescription: CMVideoFormatDescription?
    private var lastParams: Data?
    private var needsKeyframe = false

    var onSampleBuffer: (CMSampleBuffer) -> Void = { _ in }

    var isReady: Bool { formatDescription != nil }

    /// Called after a frame is lost. Every later P-frame references data we
    /// never received, so decoding them paints visible corruption. Skip until
    /// the next IDR — a brief hold looks far better than breakup.
    func requestResync() { needsKeyframe = true }

    /// Parameter sets arrive with every keyframe over UDP. Rebuilding the format
    /// description each time would churn the decoder, so ignore repeats.
    func handleParameterSets(_ data: Data) {
        guard data != lastParams else { return }
        var cursor = 0
        guard let sps = readChunk(data, cursor: &cursor),
              let pps = readChunk(data, cursor: &cursor) else { return }

        var fd: CMVideoFormatDescription?
        sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let sp = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let pp = ppsRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                let pointers = [sp, pp]
                let sizes = [sps.count, pps.count]
                pointers.withUnsafeBufferPointer { pb in
                    sizes.withUnsafeBufferPointer { sb in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pb.baseAddress!,
                            parameterSetSizes: sb.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &fd)
                    }
                }
            }
        }
        if fd != nil {
            formatDescription = fd
            lastParams = data
        }
    }

    func handleFrame(_ data: Data) {
        guard let fd = formatDescription else { return }
        if needsKeyframe {
            guard Self.containsIDR(data) else { return }
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

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        onSampleBuffer(sb)
    }

    /// Walks the AVCC length-prefixed NAL units looking for an IDR (type 5).
    private static func containsIDR(_ data: Data) -> Bool {
        var i = data.startIndex
        while i + 4 <= data.endIndex {
            let len = Int(data[i..<(i + 4)].withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).bigEndian
            })
            i += 4
            guard len > 0, i + len <= data.endIndex else { return false }
            if data[i] & 0x1F == 5 { return true }
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
