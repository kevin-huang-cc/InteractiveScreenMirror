import Foundation
import Network

let sem = DispatchSemaphore(value: 0)
let re = Reassembler()
var counts: [String: Int] = [:]
var frameBytes: [UInt8: Int] = [:]
var idrSeen: Set<UInt8> = []
var paramSeen: Set<UInt8> = []
var conn: NWConnection?

func containsIDR(_ d: Data) -> Bool {
    var i = d.startIndex
    while i + 4 <= d.endIndex {
        let len = Int(d[i..<(i+4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        i += 4
        guard len > 0, i + len <= d.endIndex else { return false }
        if d[i] & 0x1F == 5 { return true }
        i += len
    }
    return false
}

re.onMessage = { h, payload in
    counts["\(h.type)", default: 0] += 1
    switch h.type {
    case .meta:
        if counts["\(h.type)"] == 1 {
            print("META: \(String(data: payload, encoding: .utf8) ?? "?")")
        }
    case .param:
        if !paramSeen.contains(h.stream) {
            paramSeen.insert(h.stream)
            print("PARAM stream \(h.stream): \(payload.count) bytes")
        }
    case .frame:
        frameBytes[h.stream, default: 0] += payload.count
        if containsIDR(payload), !idrSeen.contains(h.stream) {
            idrSeen.insert(h.stream)
            print("IDR   stream \(h.stream): \(payload.count) bytes")
        }
    default: break
    }
}
re.onLoss = { s in counts["loss(stream \(s))", default: 0] += 1 }

let params = NWParameters.udp
params.includePeerToPeer = true
let browser = NWBrowser(for: .bonjour(type: "_ism._udp", domain: nil), using: params)
browser.browseResultsChangedHandler = { results, _ in
    guard conn == nil, let first = results.first else { return }
    print("found: \(first.endpoint)")
    let c = NWConnection(to: first.endpoint, using: params)
    conn = c
    c.stateUpdateHandler = { st in
        if case .ready = st {
            print("connected, sending hello")
            for d in Wire.datagrams(.hello, stream: 0, id: 1, Data()) {
                c.send(content: d, completion: .idempotent)
            }
        }
    }
    func loop() {
        c.receiveMessage { data, _, _, err in
            if let data, !data.isEmpty { re.feed(data) }
            if err == nil { loop() }
        }
    }
    c.start(queue: .global())
    loop()
}
browser.start(queue: .global())

DispatchQueue.global().asyncAfter(deadline: .now() + 8) { sem.signal() }
sem.wait()
print("\n--- after 8s ---")
for (k, v) in counts.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v)") }
for (s, b) in frameBytes.sorted(by: { $0.key < $1.key }) {
    print("  stream \(s): \(b/1024) KB of frames, IDR seen: \(idrSeen.contains(s)), PARAM seen: \(paramSeen.contains(s))")
}
