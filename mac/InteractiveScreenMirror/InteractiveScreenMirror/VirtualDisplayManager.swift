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

/// Layout of virtual monitors to create at launch, in points. Every display
/// is Retina (2x): macOS draws at double density, the same as Apple's Mac
/// Virtual Display, so text is as crisp as the stream allows.
struct ScreenSpec {
    let name: String
    /// Points. Pixels are double.
    let width: Int
    let height: Int
    /// Encode rate. The stream is HEVC at 2x pixels (an ultrawide is 11 Mpx a
    /// frame), which is a lot for one media engine at 90; 60 is the safe default.
    let refreshRate: Double
    var pixelWidth: Int { width * 2 }
    var pixelHeight: Int { height * 2 }

    /// The recipe macOS 26 needs before it offers 2x modes on a virtual
    /// display, found with tools/hidpi-probe: hiDPI on, the mode declared in
    /// POINTS with maxPixels at double, and a physical size around 220 DPI.
    /// Any one missing and the mode list is empty or 1x only.
    static let dpi = 220.0

    static let defaults: [ScreenSpec] = [
        ScreenSpec(name: "ISM Wide",     width: 2560, height: 1080, refreshRate: 60),
        ScreenSpec(name: "ISM Portrait", width: 1200, height: 1600, refreshRate: 60),
    ]
}

final class VirtualDisplayManager {
    private(set) var screens: [VirtualScreen] = []
    /// A disabled display drops off the online list, so the ids are captured
    /// while the panel is on and remembered across launches. If a previous run
    /// was killed with the panel off, the next launch still knows what to turn
    /// back on.
    private let builtIn: [CGDirectDisplayID] = {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        let seen = ids.filter { CGDisplayIsBuiltin($0) != 0 }
        let key = "builtInDisplayIDs"
        if !seen.isEmpty {
            UserDefaults.standard.set(seen.map(Int.init), forKey: key)
            return seen
        }
        let remembered = (UserDefaults.standard.array(forKey: key) as? [Int])?.map(CGDirectDisplayID.init) ?? []
        // Apple Silicon MacBooks have used id 1 for the panel on every machine seen.
        return remembered.isEmpty ? [1] : remembered
    }()
    private(set) var builtInEnabled = true

    /// Launch check: if the panel we know about is not online, a previous run
    /// died with it off. Turn it back on before doing anything else.
    func restoreBuiltInIfNeeded() {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        guard !ids.contains(where: { CGDisplayIsBuiltin($0) != 0 }) else { return }
        NSLog("[ISM] built-in display is off from a previous run, restoring")
        builtInEnabled = false
        setBuiltInEnabled(true)
    }

    /// Blanks or restores the MacBook's own panel. Off, it vanishes from
    /// Displays settings and the virtual displays are all macOS has, exactly
    /// like Apple's Mac Virtual Display. Session-scoped, so a reboot always
    /// brings it back; so does closing and reopening the lid.
    func setBuiltInEnabled(_ enabled: Bool) {
        guard enabled != builtInEnabled, !builtIn.isEmpty,
              enabled || !screens.isEmpty else { return }   // never leave zero displays
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return }
        for id in builtIn { CGSConfigureDisplayEnabled(cfg, id, enabled) }
        let r = CGCompleteDisplayConfiguration(cfg, .forSession)
        if r == .success { builtInEnabled = enabled }
        NSLog("[ISM] built-in display \(enabled ? "on" : "off"): \(r == .success ? "ok" : "\(r)")")
    }

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

    /// Lays the desktop out the way the headset shows it. `order` is left to
    /// right; `main` sits at the origin (menu bar, Dock); `below` screens go
    /// under the main one, each centred at the given fraction of its width.
    /// Anything not ours is parked underneath. Session-scoped, so it reverts
    /// when the virtual displays disappear.
    func arrange(order: [UInt8], main: UInt8?, below: [UInt8: Double]) {
        let byID = Dictionary(uniqueKeysWithValues: screens.map { ($0.streamID, $0) })
        let top = order.compactMap { byID[$0] }.filter { below[$0.streamID] == nil }
        let bottom = order.compactMap { byID[$0] }.filter { below[$0.streamID] != nil }
        guard let first = top.first ?? bottom.first else { return }
        let mainScreen = main.flatMap { byID[$0] } ?? first
        func width(_ s: VirtualScreen) -> Int32 { Int32(CGDisplayBounds(s.displayID).width) }
        func height(_ s: VirtualScreen) -> Int32 { Int32(CGDisplayBounds(s.displayID).height) }

        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return }
        // Top row, shifted so the main display starts at x = 0.
        var x: Int32 = 0, mainX: Int32 = 0
        for s in top {
            if s.streamID == mainScreen.streamID { mainX = x }
            x += width(s)
        }
        x = -mainX
        for s in top { CGConfigureDisplayOrigin(cfg, s.displayID, x, 0); x += width(s) }
        // Second row under the main display, each where the headset sees it,
        // clamped so it still touches the main display (macOS needs adjacency).
        let rowY = top.isEmpty ? 0 : height(mainScreen)
        let mainW = width(mainScreen)
        for s in bottom {
            let frac = below[s.streamID] ?? 0.5
            var bx = Int32((Double(mainW) * frac).rounded()) - width(s) / 2
            bx = max(-width(s) + 64, min(mainW - 64, bx))
            CGConfigureDisplayOrigin(cfg, s.displayID, bx, rowY)
        }
        // Everything that is not ours goes below all of that.
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        var bx: Int32 = 0
        let othersY = rowY + (bottom.map(height).max() ?? 0)
        for id in ids where !screens.contains(where: { $0.displayID == id }) {
            CGConfigureDisplayOrigin(cfg, id, bx, othersY)
            bx += Int32(CGDisplayBounds(id).width)
        }
        let r = CGCompleteDisplayConfiguration(cfg, .forSession)
        NSLog("[ISM] arranged \(order) main=\(mainScreen.streamID) below=\(below): \(r == .success ? "ok" : "\(r)")")
    }

    /// Launch default before the headset has said anything: first display main,
    /// the rest to its right.
    func makeFirstMain() {
        arrange(order: screens.map(\.streamID), main: screens.first?.streamID, below: [:])
    }

    private func create(_ spec: ScreenSpec, streamID: UInt8) -> VirtualScreen? {
        let desc = CGVirtualDisplayDescriptor()
        desc.queue = DispatchQueue.main
        desc.name = spec.name
        desc.maxPixelsWide = UInt32(spec.pixelWidth)
        desc.maxPixelsHigh = UInt32(spec.pixelHeight)
        // Dense physical size: this is what makes macOS treat it as Retina.
        let mmPerPx = 25.4 / ScreenSpec.dpi
        desc.sizeInMillimeters = CGSize(width: Double(spec.pixelWidth) * mmPerPx,
                                        height: Double(spec.pixelHeight) * mmPerPx)
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
        settings.modes = [CGVirtualDisplayMode(width: UInt32(spec.width),       // points
                                               height: UInt32(spec.height),
                                               refreshRate: spec.refreshRate)]
        settings.hiDPI = 1
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

        // macOS comes up in the 1x mode; switch to the 2x one.
        let modes = Self.modes(for: displayID, aspect: Double(spec.width) / Double(spec.height))
        var screen = VirtualScreen(streamID: streamID, displayID: displayID,
                                   width: spec.width, height: spec.height, fps: Int(spec.refreshRate),
                                   availableModes: modes, handle: display)
        if Self.apply(displayID: displayID, pixelWidth: spec.pixelWidth, pixelHeight: spec.pixelHeight) {
            screen.width = spec.pixelWidth
            screen.height = spec.pixelHeight
        }
        return screen
    }

    func screen(for streamID: UInt8) -> VirtualScreen? {
        screens.first { $0.streamID == streamID }
    }

    /// Registers the display for a stream if it is not up. Closing a display on
    /// the headset tears the virtual display down, so showing it again means
    /// creating it again.
    @discardableResult
    func ensure(_ streamID: UInt8) -> VirtualScreen? {
        if let s = screen(for: streamID) { return s }
        guard Int(streamID) < ScreenSpec.defaults.count,
              let s = create(ScreenSpec.defaults[Int(streamID)], streamID: streamID) else { return nil }
        screens.append(s)
        screens.sort { $0.streamID < $1.streamID }
        NSLog("[ISM] virtual display '\(s.streamID)' up -> displayID=\(s.displayID)")
        return s
    }

    /// Releasing the handle is what removes the display; macOS moves its
    /// windows to whatever is left.
    func destroy(_ streamID: UInt8) {
        guard let idx = screens.firstIndex(where: { $0.streamID == streamID }) else { return }
        screens.remove(at: idx)
        NSLog("[ISM] virtual display \(streamID) torn down")
    }

    /// Switches a display to one of its advertised modes. Returns the new size.
    @discardableResult
    func setMode(streamID: UInt8, width: Int, height: Int) -> (Int, Int)? {
        guard let idx = screens.firstIndex(where: { $0.streamID == streamID }) else { return nil }
        // Already there — don't reconfigure and restart capture for nothing.
        guard screens[idx].width != width || screens[idx].height != height else { return nil }
        guard Self.apply(displayID: screens[idx].displayID, pixelWidth: width, pixelHeight: height) else {
            NSLog("[ISM] stream \(streamID): no mode \(width)x\(height)")
            return nil
        }
        screens[idx].width = width
        screens[idx].height = height
        NSLog("[ISM] stream \(streamID): switched to \(width)x\(height)")
        return (width, height)
    }

    /// Switches to the 2x mode with these pixel dimensions.
    private static func apply(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int) -> Bool {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let all = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode],
              let target = all.first(where: {
                  $0.pixelWidth == pixelWidth && $0.pixelHeight == pixelHeight && $0.width * 2 == $0.pixelWidth
              }) else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(config, displayID, target, nil)
        guard CGCompleteDisplayConfiguration(config, .permanently) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return true
    }

    /// Real modes reported by the display, narrowed to the native aspect ratio
    /// so a resolution change never changes the shape of the window.
    private static func modes(for displayID: CGDirectDisplayID, aspect: Double) -> [(width: Int, height: Int)] {
        // The mode list populates later than the display itself: right after
        // creation CGDisplayCopyAllDisplayModes returns nil even though
        // CGDisplayPixelsWide already reports the right size.
        var all: [CGDisplayMode] = []
        for _ in 0..<40 {
            let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
            if let m = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode], !m.isEmpty {
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
        // Only 2x modes (pixels = 2 × points): the 1x duplicates of the same
        // pixel size would look identical on the headset but halve macOS's UI.
        for m in all where m.pixelWidth == m.width * 2 {
            let w = m.pixelWidth, h = m.pixelHeight
            guard w > 0, h > 0, w % 2 == 0, h % 2 == 0 else { continue }
            guard abs(Double(w) / Double(h) - aspect) / aspect < 0.01 else { continue }
            let key = "\(w)x\(h)"
            if seen.insert(key).inserted { out.append((w, h)) }
        }
        return out.sorted { $0.width > $1.width }
    }
}
