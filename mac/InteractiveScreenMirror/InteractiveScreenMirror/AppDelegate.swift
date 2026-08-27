import Cocoa
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var capturer: ScreenCapturer!
    private var server: Server!

    func applicationDidFinishLaunching(_ notification: Notification) {
        promptAccessibilityIfNeeded()

        server = Server()
        capturer = ScreenCapturer()
        capturer.onParameterSets = { [weak self] in self?.server.sendParameterSets($0) }
        capturer.onFrame = { [weak self] in self?.server.sendFrame($0) }

        Task {
            do {
                try await capturer.start()
                server.updateSourceSize(width: capturer.sourceWidth, height: capturer.sourceHeight)
                try server.start(port: 7777)
                logLocalAddresses()
            } catch {
                NSLog("startup failed: \(error)")
            }
        }
    }

    private func promptAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if !trusted {
            NSLog("Accessibility not granted yet — clicks will no-op until you enable it in System Settings.")
        }
    }

    private func logLocalAddresses() {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let addr = ptr.pointee.ifa_addr.pointee
            guard addr.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            NSLog("LISTENING on \(name): \(String(cString: host)):7777")
        }
    }
}
