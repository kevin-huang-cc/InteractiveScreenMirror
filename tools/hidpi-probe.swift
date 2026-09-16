// Probe: which descriptor settings make macOS offer 2x modes on a virtual display.
//   swiftc -import-objc-header mac/InteractiveScreenMirror/InteractiveScreenMirror/ISMPrivate.h tools/hidpi-probe.swift -o /tmp/hidpi && /tmp/hidpi
import Foundation
import CoreGraphics
// Does a dense physical size make macOS offer 2x (Retina) modes on a virtual display?
func probe(w: Int, h: Int, modeW: Int? = nil, modeH: Int? = nil, mmPerPx: Double, hiDPI: UInt32) {
    let desc = CGVirtualDisplayDescriptor()
    desc.queue = DispatchQueue.main
    desc.name = "ISM probe"
    desc.maxPixelsWide = UInt32(w); desc.maxPixelsHigh = UInt32(h)
    desc.sizeInMillimeters = CGSize(width: Double(w) * mmPerPx, height: Double(h) * mmPerPx)
    desc.vendorID = 0x1234; desc.productID = 0x5679; desc.serialNum = UInt32.random(in: 1...999_999)
    desc.redPrimary = CGPoint(x: 0.640, y: 0.330); desc.greenPrimary = CGPoint(x: 0.300, y: 0.600)
    desc.bluePrimary = CGPoint(x: 0.150, y: 0.060); desc.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
    desc.terminationHandler = { _, _ in }
    guard let d = CGVirtualDisplay(descriptor: desc) else { print("create failed"); return }
    let s = CGVirtualDisplaySettings()
    s.modes = [CGVirtualDisplayMode(width: UInt32(modeW ?? w), height: UInt32(modeH ?? h), refreshRate: 60)]
    s.hiDPI = hiDPI
    _ = d.apply(s)
    var id: CGDirectDisplayID = 0
    for _ in 0..<60 { id = d.displayID; if id != 0, CGDisplayPixelsWide(id) > 0 { break }; RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    var modes: [CGDisplayMode] = []
    for _ in 0..<60 { if let m = CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode], !m.isEmpty { modes = m; break }; RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    let list = Set(modes.map { "\($0.pixelWidth)x\($0.pixelHeight) px = \($0.width)x\($0.height) pt" }).sorted()
    print("\(w)x\(h) @ \(String(format: "%.0f", 25.4 / mmPerPx)) DPI hiDPI=\(hiDPI): current \(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id)) px / \(Int(CGDisplayBounds(id).width))x\(Int(CGDisplayBounds(id).height)) pt")
    for m in list { print("   ", m) }
    _ = d   // released at scope end → display torn down
}
probe(w: 5120, h: 2160, modeW: 2560, modeH: 1080, mmPerPx: 25.4 / 220, hiDPI: 1)
probe(w: 5120, h: 2160, modeW: 2560, modeH: 1080, mmPerPx: 25.4 / 110, hiDPI: 1)
probe(w: 5120, h: 2160, modeW: 5120, modeH: 2160, mmPerPx: 25.4 / 220, hiDPI: 2)
