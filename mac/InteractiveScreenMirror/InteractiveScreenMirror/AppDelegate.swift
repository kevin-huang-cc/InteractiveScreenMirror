import Cocoa
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let displays = VirtualDisplayManager()
    private var capturers: [ScreenCapturer] = []
    private var server: Server!
    /// Streams the headset is showing and how it has them placed.
    private var layout: Server.Layout?
    private var syncTask: Task<Void, Never>?
    /// Total link budget shared by active streams. AWDL sustains this with headroom.
    // ponytail: fixed number. Adapt from keyframe-request rate if loss shows up.
    private let linkBudget = 80_000_000

    func applicationDidFinishLaunching(_ notification: Notification) {
        promptAccessibilityIfNeeded()
        displays.restoreBuiltInIfNeeded()
        installSignalHandlers()

        let screens = displays.createAll(ScreenSpec.defaults)
        guard !screens.isEmpty else {
            NSLog("[ISM] no virtual displays created — check ISMPrivate.h against tools/probe.m")
            return
        }
        // Give macOS a beat to finish registering the displays before rearranging.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.displays.makeFirstMain() }

        server = Server()
        server.onKeyframeRequest = { [weak self] stream in
            self?.capturers.first { $0.streamID == stream }?.requestKeyframe()
        }
        server.onSetMode = { [weak self] stream, w, h in
            self?.changeMode(stream: stream, width: w, height: h)
        }
        server.onActiveStreams = { [weak self] layout in
            Task { @MainActor in
                self?.layout = layout
                self?.syncActive()
            }
        }

        Task {
            for screen in screens { await startCapture(screen) }
            do {
                try server.start(screens: screens)
            } catch {
                NSLog("[ISM] server failed to start: \(error)")
            }
        }
    }

    private func startCapture(_ screen: VirtualScreen) async {
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

    /// Make the Mac match the headset: displays shown there exist here, closed
    /// ones are gone from Displays settings, the built-in panel is off while
    /// anything is shown, and the link budget is split among what remains.
    /// Runs one at a time; a newer ACTIVE simply runs after the current pass.
    private func syncActive() {
        syncTask = Task { @MainActor [prev = syncTask] in
            await prev?.value
            guard let layout else { return }
            let active = Set(layout.ids)
            if active.isEmpty { displays.setBuiltInEnabled(true) }
            for cap in capturers where !active.contains(cap.streamID) {
                await cap.stop()
                capturers.removeAll { $0.streamID == cap.streamID }
                displays.destroy(cap.streamID)
            }
            // Create, arrange, then capture. SCK captures a display by its
            // desktop frame; a new display lands on top of an existing one until
            // arranged, and capturing before that mirrors the wrong content.
            let fresh = active.sorted().filter { displays.screen(for: $0) == nil }.compactMap { displays.ensure($0) }
            if !active.isEmpty {
                displays.arrange(order: layout.ids, main: layout.main, below: layout.below)
                displays.setBuiltInEnabled(false)
            }
            if !fresh.isEmpty {
                try? await Task.sleep(for: .milliseconds(400))
                for s in fresh { await startCapture(s) }
            }
            let cap = capturers.isEmpty ? nil : linkBudget / capturers.count
            capturers.forEach { $0.setBitrateCap(cap) }
            server.updateScreens(displays.screens)
            NSLog("[ISM] active streams \(active.sorted()), per-stream cap \(cap.map { "\($0 / 1_000_000) Mbit/s" } ?? "none")")
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

    func applicationWillTerminate(_ notification: Notification) {
        displays.setBuiltInEnabled(true)
    }

    /// Ctrl-C, kill, logout: give the panel back before dying. (SIGKILL, which
    /// Xcode's Stop uses, cannot be caught; the launch check covers that.)
    private var signals: [DispatchSourceSignal] = []
    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.displays.setBuiltInEnabled(true)
                exit(0)
            }
            src.resume()
            signals.append(src)
        }
    }

    private func promptAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            NSLog("[ISM] Accessibility not granted — clicks will no-op until enabled in System Settings.")
        }
    }
}
