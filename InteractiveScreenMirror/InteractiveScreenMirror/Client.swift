import Foundation
import Combine
import Network
import CoreMedia
import AVFoundation

final class MirrorClient: ObservableObject {
    @Published var connectionState: String = "idle"
    @Published var sourceAspect: CGFloat = 16.0 / 10.0
    @Published var hasFirstFrame: Bool = false

    private var connection: NWConnection?
    private var browser: NWBrowser?
    private let parser = WireParser()
    private let decoder = VideoDecoder()
    let displayLayer = AVSampleBufferDisplayLayer()

    init() {
        displayLayer.videoGravity = .resizeAspect
        decoder.onSampleBuffer = { [weak self] sb in
            DispatchQueue.main.async {
                guard let self else { return }
                self.displayLayer.enqueue(sb)
                if !self.hasFirstFrame { self.hasFirstFrame = true }
            }
        }
        parser.onMessage = { [weak self] type, payload in
            self?.handle(type: type, payload: payload)
        }
    }

    func connect(host: String, port: UInt16 = 7777) {
        NSLog("[ISM] connect() host=\(host) port=\(port)")
        primeLocalNetworkPermission()
        publishState("connecting")
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let conn = NWConnection(host: nwHost, port: nwPort, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            NSLog("[ISM] NWConnection state -> \(state)")
            guard let self else { return }
            switch state {
            case .ready:
                self.publishState("connected")
                self.receiveLoop()
            case .failed(let e):
                self.publishState("failed: \(e)")
                self.teardown()
            case .waiting(let e):
                self.publishState("waiting: \(e)")
            case .cancelled:
                self.publishState("cancelled")
                self.teardown()
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
        connection = conn
    }

    func sendClick(normalizedX nx: Double, normalizedY ny: Double) {
        guard let conn = connection else { return }
        let payload = try! JSONSerialization.data(withJSONObject: ["x": nx, "y": ny])
        let msg = Wire.encode(.click, payload)
        conn.send(content: msg, completion: .contentProcessed { _ in })
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                NSLog("[ISM] received \(data.count) bytes")
                self.parser.feed(data)
            }
            if let error { NSLog("[ISM] receive error: \(error)") }
            if isComplete || error != nil {
                self.publishState("closed")
                self.teardown()
                return
            }
            self.receiveLoop()
        }
    }

    private func teardown() {
        connection?.cancel()
        connection = nil
        DispatchQueue.main.async {
            self.hasFirstFrame = false
            self.displayLayer.flushAndRemoveImage()
        }
    }

    private func handle(type: WireType, payload: Data) {
        NSLog("[ISM] message type=\(type) len=\(payload.count)")
        switch type {
        case .meta:
            if let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let w = (obj["w"] as? NSNumber)?.doubleValue,
               let h = (obj["h"] as? NSNumber)?.doubleValue, h > 0 {
                let aspect = CGFloat(w / h)
                DispatchQueue.main.async { self.sourceAspect = aspect }
            }
        case .param:
            decoder.handleParameterSets(payload)
        case .frame:
            decoder.handleFrame(payload)
        case .click:
            break
        }
    }

    private func publishState(_ s: String) {
        DispatchQueue.main.async { self.connectionState = s }
    }

    private func primeLocalNetworkPermission() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: "_ism._tcp", domain: nil), using: params)
        b.stateUpdateHandler = { _ in }
        b.start(queue: .global(qos: .utility))
        browser = b
    }
}
