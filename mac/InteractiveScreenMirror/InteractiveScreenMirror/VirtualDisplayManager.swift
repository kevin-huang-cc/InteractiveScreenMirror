import Foundation
import CoreGraphics

/// One virtual monitor. Held for the lifetime of the app — releasing the
/// CGVirtualDisplay tears the display down, so `handle` must stay retained.
struct VirtualScreen {
    let streamID: UInt8
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int
    let fps: Int
    fileprivate let handle: CGVirtualDisplay
}

/// Layout of virtual monitors to create at launch. Edit freely — any aspect
/// ratio works, macOS treats each as a real extended display.
struct ScreenSpec {
    let name: String
    let width: Int
    let height: Int
    /// Leave false. On macOS 26.2 the hiDPI flag generates no 2x modes for a
    /// virtual display (every mode reports pixels == points), so it only halves
    /// the usable resolution. It also requires the mode to be declared at point
    /// size — setting it with a pixel-size mode makes registration fail
    /// silently, with applySettings still returning true. Verified via
    /// tools/probe.m. Text sharpness comes from resolution and bitrate instead.
    let hiDPI: Bool
    /// Match Vision Pro's 90Hz compositor. At 60 the frames land at an
    /// arbitrary phase against a 90Hz refresh, which reads as judder even
    /// when latency is fine.
    let refreshRate: Double

    // Pixel budget: every stream is a separate hardware encode AND a separate
    // decode on the headset, so this trades directly against smoothness.
    // Raise resolution only until text is sharp; past that you are encoding
    // detail the optics cannot resolve.
    static let defaults: [ScreenSpec] = [
        ScreenSpec(name: "ISM Wide",     width: 2560, height: 1080, hiDPI: false, refreshRate: 90),
        ScreenSpec(name: "ISM Portrait", width: 1200, height: 1600, hiDPI: false, refreshRate: 90),
    ]
}

final class VirtualDisplayManager {
    private(set) var screens: [VirtualScreen] = []

    /// Creates every spec. Returns the ones macOS accepted; a nil result for a
    /// spec is logged and skipped rather than fatal.
    @discardableResult
    func createAll(_ specs: [ScreenSpec]) -> [VirtualScreen] {
        for (i, spec) in specs.enumerated() {
            guard let s = create(spec, streamID: UInt8(i)) else {
                NSLog("[ISM] virtual display '\(spec.name)' failed to register. "
                    + "Check for an older instance still running (pgrep -x InteractiveScreenMirror); "
                    + "if none, re-run tools/probe.m to see if the private API changed.")
                continue
            }
            NSLog("[ISM] virtual display '\(spec.name)' -> displayID=\(s.displayID) \(s.width)x\(s.height)")
            screens.append(s)
        }
        return screens
    }

    private func create(_ spec: ScreenSpec, streamID: UInt8) -> VirtualScreen? {
        let desc = CGVirtualDisplayDescriptor()
        desc.queue = DispatchQueue.main
        desc.name = spec.name
        desc.maxPixelsWide = UInt32(spec.width)
        desc.maxPixelsHigh = UInt32(spec.height)
        // Physical size drives the default point scaling; match the pixel aspect
        // at roughly 100 DPI so macOS picks a sane default resolution.
        desc.sizeInMillimeters = CGSize(width: Double(spec.width) * 0.254,
                                        height: Double(spec.height) * 0.254)
        desc.vendorID = 0x1234
        desc.productID = 0x5678
        // Unique per process. A previous instance still holding displays with
        // the same serial makes registration fail silently — which looks
        // exactly like the private API having broken.
        desc.serialNum = (UInt32(truncatingIfNeeded: ProcessInfo.processInfo.processIdentifier) << 8)
                       | UInt32(streamID)
        // sRGB primaries — without these macOS may reject the display.
        desc.redPrimary   = CGPoint(x: 0.640,  y: 0.330)
        desc.greenPrimary = CGPoint(x: 0.300,  y: 0.600)
        desc.bluePrimary  = CGPoint(x: 0.150,  y: 0.060)
        desc.whitePoint   = CGPoint(x: 0.3127, y: 0.3290)
        desc.terminationHandler = { _, _ in NSLog("[ISM] virtual display terminated") }

        guard let display = CGVirtualDisplay(descriptor: desc) else { return nil }
        let settings = CGVirtualDisplaySettings()
        settings.modes = [CGVirtualDisplayMode(width: UInt32(spec.width),
                                               height: UInt32(spec.height),
                                               refreshRate: spec.refreshRate)]
        settings.hiDPI = spec.hiDPI ? 1 : 0
        // applySettings returns true even when registration fails, and the
        // display id appears asynchronously — so poll rather than trust it.
        guard display.apply(settings) else { return nil }
        var displayID: CGDirectDisplayID = 0
        for _ in 0..<40 {
            displayID = display.displayID
            if displayID != 0, CGDisplayPixelsWide(displayID) > 0 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard displayID != 0, CGDisplayPixelsWide(displayID) > 0 else { return nil }

        return VirtualScreen(streamID: streamID,
                             displayID: displayID,
                             width: spec.width,
                             height: spec.height,
                             fps: Int(spec.refreshRate),
                             handle: display)
    }

    func screen(for streamID: UInt8) -> VirtualScreen? {
        screens.first { $0.streamID == streamID }
    }
}
