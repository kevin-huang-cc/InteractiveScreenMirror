import Foundation
import Network
import CoreGraphics

final class Server {
    private var listener: NWListener?
    private var client: NWConnection?
    private var clientReady = false
    private var pendingParams: Data?
    private let parser = WireParser()
    private let queue = DispatchQueue(label: "ism.server")

    private(set) var sourceWidth: Int = 0
    private(set) var sourceHeight: Int = 0

    init() {
        parser.onMessage = { [weak self] type, payload in
            guard type == .click,
                  let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let nx = (obj["x"] as? NSNumber)?.doubleValue,
                  let ny = (obj["y"] as? NSNumber)?.doubleValue else { return }
            self?.injectClick(nx: nx, ny: ny)
        }
    }

    func start(port: UInt16) throws {
        let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] conn in
            self?.adopt(conn)
        }
        l.start(queue: queue)
        listener = l
    }

    private func adopt(_ conn: NWConnection) {
        queue.async {
            self.client?.cancel()
            self.client = conn
            self.clientReady = false
            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.queue.async {
                    switch state {
                    case .ready:
                        self.clientReady = true
                        NSLog("client connected")
                        self.sendMeta()
                        if let p = self.pendingParams { self.sendRaw(Wire.encode(.param, p)) }
                        self.receiveLoop()
                    case .failed, .cancelled:
                        if self.client === conn {
                            self.clientReady = false
                            self.client = nil
                        }
                    default: break
                    }
                }
            }
            conn.start(queue: self.queue)
        }
    }

    func updateSourceSize(width: Int, height: Int) {
        queue.async {
            self.sourceWidth = width
            self.sourceHeight = height
            self.sendMeta()
        }
    }

    func sendParameterSets(_ data: Data) {
        queue.async {
            self.pendingParams = data
            self.sendRaw(Wire.encode(.param, data))
        }
    }

    func sendFrame(_ data: Data) {
        queue.async {
            self.sendRaw(Wire.encode(.frame, data))
        }
    }

    private func sendMeta() {
        guard sourceWidth > 0 else { return }
        let json = try! JSONSerialization.data(withJSONObject: ["w": sourceWidth, "h": sourceHeight])
        sendRaw(Wire.encode(.meta, json))
    }

    private func sendRaw(_ data: Data) {
        guard clientReady, let conn = client else { return }
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receiveLoop() {
        client?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let data, !data.isEmpty { self.parser.feed(data) }
                if isComplete || error != nil { return }
                self.receiveLoop()
            }
        }
    }

    private func injectClick(nx: Double, ny: Double) {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let pt = CGPoint(x: bounds.origin.x + nx * bounds.width,
                         y: bounds.origin.y + ny * bounds.height)
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,   mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}
