import Foundation
import Network
import CoreGraphics

/// UDP server. One socket carries every stream; video is fragmented and lossy,
/// control messages are made robust by repetition rather than retransmission.
final class Server {
    static let serviceType = "_ism._udp"
    static let port: UInt16 = 7777

    private var listener: NWListener?
    private var client: NWConnection?
    private let queue = DispatchQueue(label: "ism.server")
    private let reassembler = Reassembler()

    private var screens: [VirtualScreen] = []
    private var msgIDs: [UInt8: UInt32] = [:]
    private var seenClicks: Set<UInt64> = []
    private var clickOrder: [UInt64] = []

    var onKeyframeRequest: (UInt8) -> Void = { _ in }

    init() {
        reassembler.onMessage = { [weak self] h, payload in
            self?.handle(h, payload)
        }
    }

    func start(screens: [VirtualScreen]) throws {
        self.screens = screens
        let params = NWParameters.udp
        // AWDL: the direct Mac<->Vision Pro radio path, skipping the router.
        params.includePeerToPeer = true
        // Puts frames in the WiFi video queue (WMM AC_VI) instead of
        // best-effort, so they are not stuck behind bulk traffic.
        params.serviceClass = .interactiveVideo

        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
        l.service = NWListener.Service(name: "InteractiveScreenMirror", type: Self.serviceType)
        l.newConnectionHandler = { [weak self] conn in self?.adopt(conn) }
        l.stateUpdateHandler = { state in NSLog("[ISM] listener \(state)") }
        l.start(queue: queue)
        listener = l
        NSLog("[ISM] advertising \(Self.serviceType) on port \(Self.port), \(screens.count) stream(s)")
    }

    private func adopt(_ conn: NWConnection) {
        queue.async {
            self.client?.cancel()
            self.client = conn
            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state {
                    NSLog("[ISM] client ready: \(conn.endpoint)")
                    self.queue.async { self.sendMeta() }
                }
            }
            conn.start(queue: self.queue)
            self.receiveLoop(conn)
        }
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.queue.async { self.reassembler.feed(data) } }
            if error == nil { self.receiveLoop(conn) }
        }
    }

    // MARK: outbound

    func sendParameterSets(_ stream: UInt8, _ data: Data) {
        queue.async { self.emit(.param, stream: stream, data) }
    }

    func sendFrame(_ stream: UInt8, _ data: Data, isKeyframe: Bool) {
        queue.async {
            // Meta rides along with keyframes so a client that joined late, or
            // missed the original, recovers without asking.
            if isKeyframe { self.sendMeta() }
            self.emit(.frame, stream: stream, data)
        }
    }

    private func sendMeta() {
        let list = screens.map { ["id": Int($0.streamID), "w": $0.width, "h": $0.height] }
        guard let json = try? JSONSerialization.data(withJSONObject: list) else { return }
        emit(.meta, stream: 0, json)
    }

    private func emit(_ type: WireType, stream: UInt8, _ payload: Data) {
        guard let conn = client, conn.state == .ready else { return }
        let id = msgIDs[stream, default: 0] &+ 1
        msgIDs[stream] = id
        for d in Wire.datagrams(type, stream: stream, id: id, payload) {
            conn.send(content: d, completion: .idempotent)
        }
    }

    // MARK: inbound

    private func handle(_ h: Wire.Header, _ payload: Data) {
        switch h.type {
        case .hello:
            sendMeta()
        case .keyframeReq:
            onKeyframeRequest(h.stream)
        case .click:
            // Clients send each click three times; dedupe by (stream, id).
            let key = (UInt64(h.stream) << 32) | UInt64(h.id)
            guard !seenClicks.contains(key) else { return }
            seenClicks.insert(key)
            clickOrder.append(key)
            if clickOrder.count > 256 { seenClicks.remove(clickOrder.removeFirst()) }

            guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let nx = (obj["x"] as? NSNumber)?.doubleValue,
                  let ny = (obj["y"] as? NSNumber)?.doubleValue else { return }
            injectClick(stream: h.stream, nx: nx, ny: ny)
        default:
            break
        }
    }

    private func injectClick(stream: UInt8, nx: Double, ny: Double) {
        guard let screen = screens.first(where: { $0.streamID == stream }) else { return }
        // Global coordinates: each virtual display sits at its own origin in the
        // desktop space, so the click lands on the right monitor.
        let bounds = CGDisplayBounds(screen.displayID)
        let pt = CGPoint(x: bounds.origin.x + nx * bounds.width,
                         y: bounds.origin.y + ny * bounds.height)
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
}
