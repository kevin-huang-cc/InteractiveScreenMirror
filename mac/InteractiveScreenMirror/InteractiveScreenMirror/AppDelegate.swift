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

        Task {
            for screen in screens {
                let cap = ScreenCapturer(streamID: screen.streamID, displayID: screen.displayID)
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

    private func promptAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            NSLog("[ISM] Accessibility not granted — clicks will no-op until enabled in System Settings.")
        }
    }
}
