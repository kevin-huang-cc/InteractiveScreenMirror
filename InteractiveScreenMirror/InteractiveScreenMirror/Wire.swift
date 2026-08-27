import Foundation

enum WireType: UInt8 {
    case meta  = 0x01
    case param = 0x02
    case frame = 0x03
    case click = 0x10
}

enum Wire {
    static func encode(_ type: WireType, _ payload: Data) -> Data {
        var out = Data(capacity: 5 + payload.count)
        out.append(type.rawValue)
        var len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}

final class WireParser {
    private var buf = Data()
    var onMessage: (WireType, Data) -> Void = { _, _ in }

    func feed(_ data: Data) {
        buf.append(data)
        while buf.count >= 5 {
            let type = buf[buf.startIndex]
            let lenBytes = buf[(buf.startIndex + 1)..<(buf.startIndex + 5)]
            let len = lenBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            let total = 5 + Int(len)
            guard buf.count >= total else { return }
            let payload = buf.subdata(in: (buf.startIndex + 5)..<(buf.startIndex + total))
            buf.removeSubrange(buf.startIndex..<(buf.startIndex + total))
            if let t = WireType(rawValue: type) {
                onMessage(t, payload)
            }
        }
    }
}
