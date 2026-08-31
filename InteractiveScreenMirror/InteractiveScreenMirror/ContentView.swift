import SwiftUI
import AVFoundation
import UIKit

/// Lobby window: lists the Mac's virtual monitors, opens one window each.
struct ContentView: View {
    @EnvironmentObject private var client: MirrorClient
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 24) {
            Text("Interactive Screen Mirror").font(.largeTitle)
            Text(client.connectionState).foregroundStyle(.secondary)

            if client.streamIDs.isEmpty {
                ProgressView().padding(.top, 12)
                Text("Looking for a Mac on this network…")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(client.streamIDs, id: \.self) { id in
                    Button {
                        openWindow(id: "stream", value: id)
                    } label: {
                        Label("Open display \(id + 1)", systemImage: "display")
                            .frame(maxWidth: 320)
                    }
                }
            }
        }
        .padding(40)
        .onAppear { client.start() }
    }
}

/// One virtual monitor in its own window. Drag it anywhere in space.
struct StreamView: View {
    let streamID: UInt8
    @EnvironmentObject private var client: MirrorClient

    var body: some View {
        let stream = client.state(for: streamID)
        GeometryReader { geo in
            let size = aspectFit(container: geo.size, aspect: stream.aspect)
            ZStack {
                DisplayLayerView(layer: stream.layer)
                    .frame(width: size.width, height: size.height)
                    .gesture(
                        SpatialTapGesture().onEnded { event in
                            let nx = max(0, min(1, event.location.x / size.width))
                            let ny = max(0, min(1, event.location.y / size.height))
                            client.sendClick(stream: streamID, nx: Double(nx), ny: Double(ny))
                        }
                    )
                if !stream.hasFrame {
                    ProgressView("Waiting for display \(streamID + 1)…")
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func aspectFit(container: CGSize, aspect: CGFloat) -> CGSize {
        guard aspect > 0, container.width > 0, container.height > 0 else { return container }
        return container.width / container.height > aspect
            ? CGSize(width: container.height * aspect, height: container.height)
            : CGSize(width: container.width, height: container.width / aspect)
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
