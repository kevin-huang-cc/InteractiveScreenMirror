import Foundation
import CoreGraphics

/// One virtual monitor. Held for the lifetime of the app — releasing the
/// CGVirtualDisplay tears the display down, so `handle` must stay retained.
struct VirtualScreen {
    let streamID: UInt8
    let displayID: CGDirectDisplayID
    /// Current mode. Changes when the headset picks a different resolution.
    var width: Int
    var height: Int
    let fps: Int
    /// Resolutions this display can switch to, widest first. Filtered to the
    /// native aspect so switching never letterboxes.
    var availableModes: [(width: Int, height: Int)] = []
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
                             availableModes: Self.modes(for: displayID, aspect: Double(spec.width) / Double(spec.height)),
                             handle: display)
    }

    func screen(for streamID: UInt8) -> VirtualScreen? {
        screens.first { $0.streamID == streamID }
    }

    /// Switches a display to one of its advertised modes. Returns the new size.
    @discardableResult
    func setMode(streamID: UInt8, width: Int, height: Int) -> (Int, Int)? {
        guard let idx = screens.firstIndex(where: { $0.streamID == streamID }) else { return nil }
        // Already there — don't reconfigure and restart capture for nothing.
        guard screens[idx].width != width || screens[idx].height != height else { return nil }
        let displayID = screens[idx].displayID
        guard let all = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode],
              let target = all.first(where: {
                  $0.pixelWidth == width && $0.pixelHeight == height
              }) else {
            NSLog("[ISM] stream \(streamID): no mode \(width)x\(height)")
            return nil
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return nil }
        CGConfigureDisplayWithDisplayMode(config, displayID, target, nil)
        guard CGCompleteDisplayConfiguration(config, .permanently) == .success else {
            CGCancelDisplayConfiguration(config)
            return nil
        }
        screens[idx].width = width
        screens[idx].height = height
        NSLog("[ISM] stream \(streamID): switched to \(width)x\(height)")
        return (width, height)
    }

    /// Real modes reported by the display, narrowed to the native aspect ratio
    /// so a resolution change never changes the shape of the window.
    private static func modes(for displayID: CGDirectDisplayID, aspect: Double) -> [(width: Int, height: Int)] {
        // The mode list populates later than the display itself: right after
        // creation CGDisplayCopyAllDisplayModes returns nil even though
        // CGDisplayPixelsWide already reports the right size.
        var all: [CGDisplayMode] = []
        for _ in 0..<40 {
            if let m = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode], !m.isEmpty {
                all = m
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard !all.isEmpty else {
            NSLog("[ISM] display \(displayID): no modes enumerated; resolution switching unavailable")
            return []
        }
        var seen = Set<String>()
        var out: [(width: Int, height: Int)] = []
        for m in all {
            let w = m.pixelWidth, h = m.pixelHeight
            guard w > 0, h > 0, w % 2 == 0, h % 2 == 0 else { continue }
            // H.264 wants even dimensions; keep only the native shape.
            guard abs(Double(w) / Double(h) - aspect) / aspect < 0.01 else { continue }
            let key = "\(w)x\(h)"
            if seen.insert(key).inserted { out.append((w, h)) }
        }
        return out.sorted { $0.width > $1.width }
    }
}
