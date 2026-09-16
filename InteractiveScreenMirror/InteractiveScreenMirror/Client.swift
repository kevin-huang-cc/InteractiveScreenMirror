import Foundation
import Combine
import Network
import CoreMedia

/// One virtual monitor's worth of state: its own decoder and screen texture.
final class StreamState: ObservableObject, Identifiable {
    let id: UInt8
    @Published var aspect: CGFloat = 16.0 / 9.0
    @Published var hasFrame = false
    /// Current resolution of the Mac-side virtual display.
    @Published var size: CGSize = .zero
    /// Resolutions this display can switch to, widest first.
    @Published var modes: [CGSize] = []
    /// Wrap angle in radians. 0 is flat; Apple's ultrawide is roughly 1.2.
    @Published var curvature: Float = 0.8
    /// Radians about the horizontal axis. 0 upright, π/2 lying flat facing up.
    @Published var tilt: Float = 0
    /// Size multiplier; 1 is a 1.3 m wide screen.
    @Published var zoom: Float = 1
    /// Placement in the immersive space, metres from where the app launched.
    @Published var isOpen = false
    @Published var position = SIMD3<Float>(0, 1.3, -1.5)
    @Published var yaw: Float = 0
    /// False until the screen has been placed once, so it can spawn ahead of you.
    @Published var placed = false
    let screen = ScreenTexture()
    let decoder = VideoDecoder()
    private var saver: AnyCancellable?

    init(id: UInt8) {
        self.id = id
        if let d = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode(Saved.self, from: d) {
            curvature = s.curvature; tilt = s.tilt; zoom = s.zoom
            isOpen = s.isOpen; position = SIMD3(s.pos[0], s.pos[1], s.pos[2]); yaw = s.yaw
            placed = s.placed ?? true
        }
        // objectWillChange fires before the write; by the time the debounce
        // elapses every field is current.
        saver = objectWillChange
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.save() }
    }

    private var key: String { "screen.\(id)" }
    private struct Saved: Codable {
        var curvature: Float, tilt: Float, zoom: Float, isOpen: Bool, pos: [Float], yaw: Float
        var placed: Bool?
    }
    private func save() {
        let s = Saved(curvature: curvature, tilt: tilt, zoom: zoom, isOpen: isOpen,
                      pos: [position.x, position.y, position.z], yaw: yaw, placed: placed)
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: key)
    }
}

final class MirrorClient: ObservableObject {
    static let shared = MirrorClient()

    @Published var connectionState = "searching…"
    @Published var streamIDs: [UInt8] = []
    /// Set by the immersive space itself, so the Crown closing it is seen too.
    @Published var spaceVisible = false

    private var states: [UInt8: StreamState] = [:]
    private var connection: NWConnection?
    private var browser: NWBrowser?
    private let reassembler = Reassembler()
    private let queue = DispatchQueue(label: "ism.client")
    private var clickSeq: UInt32 = 0
    private var sentActive: Set<UInt8>?
    private let statesLock = NSLock()
    private var forwarders: [AnyCancellable] = []

    /// Streams currently shown in the immersive space, in id order.
    var openStreams: [StreamState] {
        streamIDs.map { state(for: $0) }.filter(\.isOpen)
    }

    private init() {
        reassembler.onMessage = { [weak self] h, payload in self?.handle(h, payload) }
        reassembler.onLoss = { [weak self] stream in
            guard let self else { return }
            // A fragment never arrived. Stop decoding until an IDR lands, and
            // ask the Mac for one now rather than waiting out the GOP.
            self.state(for: stream).decoder.requestResync()
            self.send(.keyframeReq, stream: stream, Data())
        }
    }

    func state(for id: UInt8) -> StreamState {
        statesLock.lock(); defer { statesLock.unlock() }
        if let s = states[id] { return s }
        let s = StreamState(id: id)
        states[id] = s
        // One RealityView draws every screen, so any stream change must
        // invalidate the client it observes.
        forwarders.append(s.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                self?.objectWillChange.send()
                self?.syncActive()
            }
        })
        s.decoder.onPixelBuffer = { [weak s] pb in
            // Blit on the decoder thread; staying off main keeps frames out of
            // SwiftUI's queue.
            s?.screen.push(pb)
            if s?.hasFrame == false {
                DispatchQueue.main.async { s?.hasFrame = true }
            }
        }
        return s
    }

    /// Browses for the Mac over Bonjour, including the peer-to-peer (AWDL)
    /// interface — the same direct radio path Apple's own mirroring uses.
    func start() {
        guard browser == nil else { return }
        let params = NWParameters.udp
        params.includePeerToPeer = true
        params.serviceClass = .interactiveVideo

        let b = NWBrowser(for: .bonjour(type: "_ism._udp", domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connection == nil, let first = results.first else { return }
            self.connect(to: first.endpoint, params: params)
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state {
                DispatchQueue.main.async { self?.connectionState = "browse failed: \(e)" }
            }
        }
        b.start(queue: queue)
        browser = b
    }

    private func connect(to endpoint: NWEndpoint, params: NWParameters) {
        publish("connecting…")
        let conn = NWConnection(to: endpoint, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.publish("connected")
                self.send(.hello, stream: 0, Data())
                self.sentActive = nil
                DispatchQueue.main.async { self.syncActive() }
                self.receiveLoop(conn)
            case .failed(let e):
                self.publish("failed: \(e)")
                self.connection = nil
            case .cancelled:
                self.connection = nil
            default: break
            }
        }
        connection = conn
        conn.start(queue: queue)
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.reassembler.feed(data) }
            if error == nil { self.receiveLoop(conn) }
        }
    }

    func sendClick(stream: UInt8, nx: Double, ny: Double) {
        guard let payload = try? JSONSerialization.data(withJSONObject: ["x": nx, "y": ny]) else { return }
        clickSeq &+= 1
        let seq = clickSeq
        // ponytail: UDP has no retransmit and a lost click is very visible.
        // Three copies with the same id; the Mac dedupes. Cheaper than an ACK.
        for _ in 0..<3 {
            emit(.click, stream: stream, id: seq, payload)
        }
    }

    /// Asks the Mac to switch a virtual display's resolution. Sent three times
    /// like clicks: UDP has no retransmit and a dropped request looks like the
    /// picker silently doing nothing.
    func setMode(stream: UInt8, width: Int, height: Int) {
        guard let payload = try? JSONSerialization.data(withJSONObject: ["w": width, "h": height]) else { return }
        clickSeq &+= 1
        let seq = clickSeq
        for _ in 0..<3 { emit(.setMode, stream: stream, id: seq, payload) }
    }

    /// Tells the Mac which displays are shown so it can pause the rest and
    /// split bandwidth among the visible ones. Sent on every change, three
    /// times like the other commands.
    private func syncActive() {
        let ids = Set(streamIDs.filter { state(for: $0).isOpen })
        guard ids != sentActive,
              let payload = try? JSONSerialization.data(withJSONObject: ["ids": ids.sorted().map(Int.init)]) else { return }
        sentActive = ids
        clickSeq &+= 1
        let seq = clickSeq
        for _ in 0..<3 { emit(.active, stream: 0, id: seq, payload) }
    }

    private func send(_ type: WireType, stream: UInt8, _ payload: Data) {
        clickSeq &+= 1
        emit(type, stream: stream, id: clickSeq, payload)
    }

    private func emit(_ type: WireType, stream: UInt8, id: UInt32, _ payload: Data) {
        guard let conn = connection, conn.state == .ready else { return }
        for d in Wire.datagrams(type, stream: stream, id: id, payload) {
            conn.send(content: d, completion: .idempotent)
        }
    }

    private func handle(_ h: Wire.Header, _ payload: Data) {
        switch h.type {
        case .meta:
            guard let list = try? JSONSerialization.jsonObject(with: payload) as? [[String: Any]] else { return }
            DispatchQueue.main.async {
                for entry in list {
                    guard let id = (entry["id"] as? NSNumber)?.uint8Value,
                          let w = (entry["w"] as? NSNumber)?.doubleValue,
                          let hh = (entry["h"] as? NSNumber)?.doubleValue, hh > 0 else { continue }
                    let s = self.state(for: id)
                    s.aspect = CGFloat(w / hh)
                    s.size = CGSize(width: w, height: hh)
                    if let raw = entry["modes"] as? [[NSNumber]] {
                        s.modes = raw.compactMap {
                            $0.count == 2 ? CGSize(width: $0[0].doubleValue, height: $0[1].doubleValue) : nil
                        }
                    }
                    if !self.streamIDs.contains(id) { self.streamIDs.append(id); self.streamIDs.sort() }
                }
            }
        case .param:
            state(for: h.stream).decoder.handleParameterSets(payload)
        case .frame:
            let s = state(for: h.stream)
            guard s.decoder.isReady else { return }
            s.decoder.handleFrame(payload)
        default:
            break
        }
    }

    private func publish(_ s: String) {
        DispatchQueue.main.async { self.connectionState = s }
    }
}
