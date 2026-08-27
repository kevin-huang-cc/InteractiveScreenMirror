import SwiftUI
import AVFoundation
import UIKit

struct ContentView: View {
    @StateObject private var client = MirrorClient()
    @State private var host: String = ""

    var body: some View {
        if client.hasFirstFrame {
            videoSurface
        } else {
            connectForm
        }
    }

    private var connectForm: some View {
        VStack(spacing: 20) {
            Text("Connect to Mac").font(.title)
            TextField("Mac IP (e.g. 192.168.1.42)", text: $host)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            Button("Connect") {
                client.connect(host: host)
            }
            .disabled(host.isEmpty)
            Text(client.connectionState).foregroundStyle(.secondary)
        }
        .padding(40)
    }

    private var videoSurface: some View {
        GeometryReader { geo in
            let viewSize = aspectFit(container: geo.size, aspect: client.sourceAspect)
            ZStack {
                DisplayLayerView(layer: client.displayLayer)
                    .frame(width: viewSize.width, height: viewSize.height)
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { event in
                                let p = event.location
                                let nx = max(0, min(1, p.x / viewSize.width))
                                let ny = max(0, min(1, p.y / viewSize.height))
                                client.sendClick(normalizedX: Double(nx), normalizedY: Double(ny))
                            }
                    )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func aspectFit(container: CGSize, aspect: CGFloat) -> CGSize {
        let containerAspect = container.width / container.height
        if containerAspect > aspect {
            return CGSize(width: container.height * aspect, height: container.height)
        } else {
            return CGSize(width: container.width, height: container.width / aspect)
        }
    }
}

struct DisplayLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> UIView {
        let v = HostView()
        v.backgroundColor = .black
        v.layer.addSublayer(layer)
        v.hostedLayer = layer
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class HostView: UIView {
        weak var hostedLayer: AVSampleBufferDisplayLayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            hostedLayer?.frame = bounds
        }
    }
}
