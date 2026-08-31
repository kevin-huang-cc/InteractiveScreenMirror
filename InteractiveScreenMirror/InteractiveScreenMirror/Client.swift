import Foundation
import Combine
import Network
import CoreMedia
import AVFoundation

/// One virtual monitor's worth of state: its own decoder and display layer.
final class StreamState: ObservableObject, Identifiable {
    let id: UInt8
    @Published var aspect: CGFloat = 16.0 / 9.0
    @Published var hasFrame = false
    /// Current resolution of the Mac-side virtual display.
    @Published var size: CGSize = .zero
    /// Resolutions this display can switch to, widest first.
    @Published var modes: [CGSize] = []
    let layer = AVSampleBufferDisplayLayer()
    let decoder = VideoDecoder()

    init(id: UInt8) {
        self.id = id
        layer.videoGravity = .resizeAspect
    }
}

final class MirrorClient: ObservableObject {
    static let shared = MirrorClient()

    @Published var connectionState = "searching…"
    @Published var streamIDs: [UInt8] = []

    private var states: [UInt8: StreamState] = [:]
    private var connection: NWConnection?
    private var browser: NWBrowser?
    private let reassembler = Reassembler()
    private let queue = DispatchQueue(label: "ism.client")
    private var clickSeq: UInt32 = 0
    private let statesLock = NSLock()

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
        s.decoder.onSampleBuffer = { [weak s] sb in
            // AVSampleBufferDisplayLayer.enqueue is thread-safe; staying off the
            // main thread keeps frames out of SwiftUI's queue.
            s?.layer.enqueue(sb)
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
