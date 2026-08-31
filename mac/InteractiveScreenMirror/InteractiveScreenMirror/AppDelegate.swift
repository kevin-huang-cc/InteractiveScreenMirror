import Cocoa
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let displays = VirtualDisplayManager()
    private var capturers: [ScreenCapturer] = []
    private var server: Server!

    func applicationDidFinishLaunching(_ notification: Notification) {
        promptAccessibilityIfNeeded()

        let screens = displays.createAll(ScreenSpec.defaults)
        guard !screens.isEmpty else {
            NSLog("[ISM] no virtual displays created — check ISMPrivate.h against tools/probe.m")
            return
        }

        server = Server()
        server.onKeyframeRequest = { [weak self] stream in
            self?.capturers.first { $0.streamID == stream }?.requestKeyframe()
        }
        server.onSetMode = { [weak self] stream, w, h in
            self?.changeMode(stream: stream, width: w, height: h)
        }

        Task {
            for screen in screens {
                let cap = ScreenCapturer(streamID: screen.streamID, displayID: screen.displayID, fps: screen.fps)
                cap.onParameterSets = { [weak self] id, data in self?.server.sendParameterSets(id, data) }
                cap.onFrame = { [weak self] id, data, key in self?.server.sendFrame(id, data, isKeyframe: key) }
                do {
                    try await cap.start()
                    capturers.append(cap)
                    NSLog("[ISM] capturing stream \(screen.streamID) (\(screen.width)x\(screen.height))")
                } catch {
                    NSLog("[ISM] capture failed for stream \(screen.streamID): \(error)")
                }
            }
            do {
                try server.start(screens: screens)
            } catch {
                NSLog("[ISM] server failed to start: \(error)")
            }
        }
    }

    /// A VTCompressionSession is fixed at its creation size and SCStream's
    /// config is set at start, so a resolution change means rebuilding the
    /// whole capture path for that stream.
    private func changeMode(stream: UInt8, width: Int, height: Int) {
        Task { @MainActor in
            guard displays.setMode(streamID: stream, width: width, height: height) != nil,
                  let screen = displays.screen(for: stream) else { return }

            if let idx = capturers.firstIndex(where: { $0.streamID == stream }) {
                let old = capturers.remove(at: idx)
                await old.stop()
            }
            let cap = ScreenCapturer(streamID: stream, displayID: screen.displayID, fps: screen.fps)
            cap.onParameterSets = { [weak self] id, data in self?.server.sendParameterSets(id, data) }
            cap.onFrame = { [weak self] id, data, key in self?.server.sendFrame(id, data, isKeyframe: key) }
            do {
                try await cap.start()
                capturers.append(cap)
                server.updateScreens(displays.screens)
                NSLog("[ISM] stream \(stream): capture restarted at \(width)x\(height)")
            } catch {
                NSLog("[ISM] stream \(stream): restart failed: \(error)")
            }
        }
    }

    private func promptAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            NSLog("[ISM] Accessibility not granted — clicks will no-op until enabled in System Settings.")
        }
    }
}
