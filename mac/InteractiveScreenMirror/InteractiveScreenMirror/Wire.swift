import Foundation

enum WireType: UInt8 {
    case meta        = 0x01   // Mac -> VP  : JSON [{id,w,h,name}]
    case param       = 0x02   // Mac -> VP  : [4B spsLen][SPS][4B ppsLen][PPS]
    case frame       = 0x03   // Mac -> VP  : AVCC NAL units
    case click       = 0x10   // VP  -> Mac : JSON {x,y}
    case hello       = 0x20   // VP  -> Mac : announces the client endpoint
    case keyframeReq = 0x21   // VP  -> Mac : a frame was lost, resync now
    case setMode     = 0x22   // VP  -> Mac : JSON {w,h} switch this display's resolution
    case active      = 0x23   // VP  -> Mac : JSON {ids:[...]} streams currently shown; others pause
}

/// Datagram layout: [1B type][1B streamID][4B msgID][2B fragIndex][2B fragCount][payload]
enum Wire {
    static let headerSize = 10
    /// Conservative: AWDL carries less than Ethernet's 1500B MTU, and a
    /// fragmented IP datagram loses the whole frame if any shard drops.
    static let maxPayload = 1200

    static func datagrams(_ type: WireType, stream: UInt8, id: UInt32, _ payload: Data) -> [Data] {
        let count = max(1, (payload.count + maxPayload - 1) / maxPayload)
        guard count <= Int(UInt16.max) else { return [] }
        var out: [Data] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let lo = payload.startIndex + i * maxPayload
            let hi = min(lo + maxPayload, payload.endIndex)
            var d = Data(capacity: headerSize + (hi - lo))
            d.append(type.rawValue)
            d.append(stream)
            append(&d, id)
            append(&d, UInt16(i))
            append(&d, UInt16(count))
            d.append(payload[lo..<hi])
            out.append(d)
        }
        return out
    }

    struct Header {
        let type: WireType
        let stream: UInt8
        let id: UInt32
        let fragIndex: Int
        let fragCount: Int
    }

    static func parse(_ d: Data) -> (Header, Data)? {
        guard d.count >= headerSize, let type = WireType(rawValue: d[d.startIndex]) else { return nil }
        let i = d.startIndex
        let idx = Int(u16(d, i + 6)), cnt = Int(u16(d, i + 8))
        guard cnt > 0, idx < cnt else { return nil }
        let h = Header(type: type, stream: d[i + 1], id: u32(d, i + 2), fragIndex: idx, fragCount: cnt)
        return (h, Data(d[(i + headerSize)...]))
    }

    private static func append(_ d: inout Data, _ v: UInt32) {
        var b = v.bigEndian; withUnsafeBytes(of: &b) { d.append(contentsOf: $0) }
    }
    private static func append(_ d: inout Data, _ v: UInt16) {
        var b = v.bigEndian; withUnsafeBytes(of: &b) { d.append(contentsOf: $0) }
    }
    // loadUnaligned: the 1B type prefix puts these on odd offsets.
    private static func u32(_ d: Data, _ i: Int) -> UInt32 {
        d[i..<(i + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
    }
    private static func u16(_ d: Data, _ i: Int) -> UInt16 {
        d[i..<(i + 2)].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).bigEndian }
    }
}

/// Rebuilds fragmented messages, per stream. Lossy by design: UDP frames that
/// never complete are dropped and reported so the caller can ask for a keyframe.
final class Reassembler {
    private struct Pending { var frags: [Data?]; var have: Int }
    private var pending: [UInt64: Pending] = [:]
    private var lastDelivered: [UInt8: UInt32] = [:]

    var onMessage: (Wire.Header, Data) -> Void = { _, _ in }
    var onLoss: (UInt8) -> Void = { _ in }

    private func key(_ stream: UInt8, _ id: UInt32) -> UInt64 {
        (UInt64(stream) << 32) | UInt64(id)
    }

    func feed(_ datagram: Data) {
        guard let (h, body) = Wire.parse(datagram) else { return }

        if h.fragCount == 1 { deliver(h, body); return }
        if h.type == .frame, let last = lastDelivered[h.stream], h.id <= last { return }

        let k = key(h.stream, h.id)
        var p = pending[k] ?? Pending(frags: Array(repeating: nil, count: h.fragCount), have: 0)
        guard p.frags.count == h.fragCount, p.frags[h.fragIndex] == nil else { return }
        p.frags[h.fragIndex] = body
        p.have += 1

        if p.have == p.frags.count {
            pending.removeValue(forKey: k)
            var full = Data()
            for f in p.frags { full.append(f!) }
            deliver(h, full)
        } else {
            pending[k] = p
        }
    }

    private func deliver(_ h: Wire.Header, _ payload: Data) {
        if h.type == .frame {
            if let last = lastDelivered[h.stream], h.id <= last { return }
            lastDelivered[h.stream] = h.id
            evictStale(stream: h.stream, upTo: h.id)
        }
        onMessage(h, payload)
    }

    /// ponytail: fixed window, no timers. A frame still incomplete 4 ids later
    /// is never completing — drop it and resync. Raise if loss is bursty.
    private func evictStale(stream: UInt8, upTo id: UInt32) {
        var lost = false
        for k in pending.keys where UInt8(k >> 32) == stream {
            let pendingID = UInt32(truncatingIfNeeded: k)
            if id > pendingID && id - pendingID >= 4 {
                pending.removeValue(forKey: k)
                lost = true
            }
        }
        if lost { onLoss(stream) }
    }
}
