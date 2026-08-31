import Foundation

func check(_ cond: Bool, _ label: String) {
    print(cond ? "  ok   \(label)" : "  FAIL \(label)")
    if !cond { exit(1) }
}

// 1. single-datagram round trip
var got: [(Wire.Header, Data)] = []
var losses: [UInt8] = []
func fresh() -> Reassembler {
    got = []; losses = []
    let r = Reassembler()
    r.onMessage = { got.append(($0, $1)) }
    r.onLoss = { losses.append($0) }
    return r
}

var r = fresh()
let small = Data("hello".utf8)
let d1 = Wire.datagrams(.click, stream: 3, id: 7, small)
check(d1.count == 1, "small message is one datagram")
d1.forEach { r.feed($0) }
check(got.count == 1 && got[0].1 == small, "small payload round-trips")
check(got[0].0.stream == 3 && got[0].0.id == 7, "stream/id preserved")

// 2. large message fragments and reassembles
r = fresh()
let big = Data((0..<10_000).map { UInt8($0 % 251) })
let dN = Wire.datagrams(.frame, stream: 1, id: 100, big)
check(dN.count == 9, "10000B splits into 9 datagrams (got \(dN.count))")
check(dN.allSatisfy { $0.count <= Wire.headerSize + Wire.maxPayload }, "no datagram exceeds MTU budget")
dN.forEach { r.feed($0) }
check(got.count == 1 && got[0].1 == big, "large payload reassembles byte-exact")

// 3. out-of-order fragments still reassemble
r = fresh()
dN.reversed().forEach { r.feed($0) }
check(got.count == 1 && got[0].1 == big, "out-of-order fragments reassemble")

// 4. duplicate fragments are ignored, not double-counted
r = fresh()
(dN + dN).forEach { r.feed($0) }
check(got.count == 1, "duplicate fragments deliver once")

// 5. a dropped fragment never delivers, and reports loss once a later frame lands
r = fresh()
dN.dropLast().forEach { r.feed($0) }
check(got.isEmpty, "incomplete frame is not delivered")
for i in UInt32(101)...104 {
    Wire.datagrams(.frame, stream: 1, id: i, small).forEach { r.feed($0) }
}
check(losses.contains(1), "loss reported on stream 1")

// 6. stale frame arriving after a newer one is dropped
r = fresh()
Wire.datagrams(.frame, stream: 2, id: 50, small).forEach { r.feed($0) }
Wire.datagrams(.frame, stream: 2, id: 49, small).forEach { r.feed($0) }
check(got.count == 1 && got[0].0.id == 50, "stale frame dropped, newer kept")

// 7. streams are independent
r = fresh()
Wire.datagrams(.frame, stream: 0, id: 9, small).forEach { r.feed($0) }
Wire.datagrams(.frame, stream: 1, id: 9, small).forEach { r.feed($0) }
check(got.count == 2, "same id on different streams both delivered")

// 8. garbage in, no crash
r = fresh()
r.feed(Data([0xFF]))
r.feed(Data())
r.feed(Data([0x03, 0x00, 0,0,0,1, 0,5, 0,2]))   // fragIndex 5 >= fragCount 2
check(got.isEmpty, "malformed datagrams rejected without crashing")

print("\nall wire checks passed")
