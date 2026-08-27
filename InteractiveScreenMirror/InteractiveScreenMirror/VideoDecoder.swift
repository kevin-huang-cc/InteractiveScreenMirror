import Foundation
import CoreMedia
import VideoToolbox

final class VideoDecoder {
    private var formatDescription: CMVideoFormatDescription?
    var onSampleBuffer: (CMSampleBuffer) -> Void = { _ in }

    func handleParameterSets(_ data: Data) {
        // Layout: [4B sps_len][sps][4B pps_len][pps]
        var cursor = 0
        guard let sps = readChunk(data, cursor: &cursor),
              let pps = readChunk(data, cursor: &cursor) else { return }

        var fd: CMVideoFormatDescription?
        sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                let spsPtr = spsRaw.bindMemory(to: UInt8.self).baseAddress!
                let ppsPtr = ppsRaw.bindMemory(to: UInt8.self).baseAddress!
                let pointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                let sizes: [Int] = [sps.count, pps.count]
                pointers.withUnsafeBufferPointer { pp in
                    sizes.withUnsafeBufferPointer { sp in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pp.baseAddress!,
                            parameterSetSizes: sp.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &fd)
                    }
                }
            }
        }
        formatDescription = fd
    }

    func handleFrame(_ data: Data) {
        guard let fd = formatDescription else { return }
        var blockBuffer: CMBlockBuffer?
        let mutable = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 1)
        data.copyBytes(to: mutable.assumingMemoryBound(to: UInt8.self), count: data.count)
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: mutable,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let bb = blockBuffer else {
            mutable.deallocate(); return
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = data.count
        let s2 = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: fd,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard s2 == noErr, let sb = sampleBuffer else { return }

        // Mark display-immediately attachment so the layer doesn't wait for timing.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        onSampleBuffer(sb)
    }

    private func readChunk(_ data: Data, cursor: inout Int) -> Data? {
        guard cursor + 4 <= data.count else { return nil }
        let lenData = data.subdata(in: cursor..<(cursor + 4))
        let len = Int(lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        cursor += 4
        guard cursor + len <= data.count else { return nil }
        let chunk = data.subdata(in: cursor..<(cursor + len))
        cursor += len
        return chunk
    }
}
