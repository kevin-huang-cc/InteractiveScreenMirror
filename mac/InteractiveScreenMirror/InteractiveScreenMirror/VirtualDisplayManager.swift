import Foundation
import CoreGraphics

/// One virtual monitor. Held for the lifetime of the app — releasing the
/// CGVirtualDisplay tears the display down, so `handle` must stay retained.
struct VirtualScreen {
    let streamID: UInt8
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int
    fileprivate let handle: CGVirtualDisplay
}

/// Layout of virtual monitors to create at launch. Edit freely — any aspect
/// ratio works, macOS treats each as a real extended display.
struct ScreenSpec {
    let name: String
    let width: Int
    let height: Int
    /// hiDPI doubles the backing store: a 2560x1080 hiDPI display presents as
    /// 1280x540 points, so text renders at Retina density.
    let hiDPI: Bool

    // ponytail: Vision Pro resolves ~34 pixels/degree, so a window filling ~60
    // degrees is saturated near 2000px wide. Going wider spends bandwidth and
    // encoder time on detail the optics cannot show. Sizes below sit under that.
    static let defaults: [ScreenSpec] = [
        ScreenSpec(name: "ISM Wide",     width: 2560, height: 1080, hiDPI: false),
        ScreenSpec(name: "ISM Portrait", width: 1200, height: 1600, hiDPI: false),
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
                NSLog("[ISM] virtual display '\(spec.name)' failed — skipping")
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
        desc.serialNum = UInt32(streamID) + 1
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
                                               refreshRate: 60)]
        settings.hiDPI = spec.hiDPI ? 1 : 0
        guard display.apply(settings), display.displayID != 0 else { return nil }

        return VirtualScreen(streamID: streamID,
                             displayID: display.displayID,
                             width: spec.width,
                             height: spec.height,
                             handle: display)
    }

    func screen(for streamID: UInt8) -> VirtualScreen? {
        screens.first { $0.streamID == streamID }
    }
}
