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
    /// Cached per stream so a client connecting after the initial IDR can start
    /// decoding immediately instead of waiting for the next keyframe.
    private var lastParams: [UInt8: Data] = [:]
    // Clients repeat clicks and mode changes three times because UDP has no
    // retransmit, so every repeated command needs deduping — a mode change
    // applied three times reconfigures the display and restarts capture three
    // times over.
    private var seenCommands: Set<UInt64> = []
    private var commandOrder: [UInt64] = []

    var onKeyframeRequest: (UInt8) -> Void = { _ in }
    var onSetMode: (UInt8, Int, Int) -> Void = { _, _, _ in }

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
        queue.async {
            self.lastParams[stream] = data
            self.emit(.param, stream: stream, data)
        }
    }

    func sendFrame(_ stream: UInt8, _ data: Data, isKeyframe: Bool) {
        queue.async {
            // Meta rides along with keyframes so a client that joined late, or
            // missed the original, recovers without asking.
            if isKeyframe { self.sendMeta() }
            self.emit(.frame, stream: stream, data)
        }
    }

    /// Called after a resolution change so the headset can resize its window.
    func updateScreens(_ screens: [VirtualScreen]) {
        queue.async {
            self.screens = screens
            self.sendMeta()
        }
    }

    private func sendMeta() {
        let list: [[String: Any]] = screens.map {
            ["id": Int($0.streamID), "w": $0.width, "h": $0.height,
             "modes": $0.availableModes.map { [$0.width, $0.height] }]
        }
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
            // A new client has no reference frame and no parameter sets. Under
            // low-latency rate control the encoder emits an IDR at startup and
            // then only on request, so ask for one explicitly rather than
            // waiting out a GOP that may never come.
            sendMeta()
            for (stream, params) in lastParams { emit(.param, stream: stream, params) }
            for screen in screens { onKeyframeRequest(screen.streamID) }
        case .keyframeReq:
            onKeyframeRequest(h.stream)
        case .setMode:
            guard isNewCommand(h) else { return }
            guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let w = (obj["w"] as? NSNumber)?.intValue,
                  let hh = (obj["h"] as? NSNumber)?.intValue else { return }
            onSetMode(h.stream, w, hh)
        case .click:
            guard isNewCommand(h) else { return }
            guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let nx = (obj["x"] as? NSNumber)?.doubleValue,
                  let ny = (obj["y"] as? NSNumber)?.doubleValue else { return }
            injectClick(stream: h.stream, nx: nx, ny: ny)
        default:
            break
        }
    }

    /// True the first time a (stream, id) pair is seen. Bounded history.
    private func isNewCommand(_ h: Wire.Header) -> Bool {
        let key = (UInt64(h.stream) << 32) | UInt64(h.id)
        guard !seenCommands.contains(key) else { return false }
        seenCommands.insert(key)
        commandOrder.append(key)
        if commandOrder.count > 256 { seenCommands.remove(commandOrder.removeFirst()) }
        return true
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
