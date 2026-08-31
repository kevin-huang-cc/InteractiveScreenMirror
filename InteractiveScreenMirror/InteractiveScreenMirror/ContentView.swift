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
        // StreamState must be observed here, not just read. Reading it inline
        // meant `hasFrame` flipping never invalidated the view, so the
        // "Waiting for display" spinner stayed up over live video.
        StreamSurface(stream: client.state(for: streamID), client: client)
    }
}

private struct StreamSurface: View {
    @ObservedObject var stream: StreamState
    let client: MirrorClient

    var body: some View {
        GeometryReader { geo in
            let size = aspectFit(container: geo.size, aspect: stream.aspect)
            ZStack {
                DisplayLayerView(layer: stream.layer)
                    .frame(width: size.width, height: size.height)
                    .gesture(
                        SpatialTapGesture().onEnded { event in
                            let nx = max(0, min(1, event.location.x / size.width))
                            let ny = max(0, min(1, event.location.y / size.height))
                            client.sendClick(stream: stream.id, nx: Double(nx), ny: Double(ny))
                        }
                    )
                if !stream.hasFrame {
                    ProgressView("Waiting for display \(stream.id + 1)…")
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(UniformResize(aspect: stream.aspect))
            .ornament(attachmentAnchor: .scene(.bottom)) {
                resolutionPicker
            }
        }
    }

    @ViewBuilder private var resolutionPicker: some View {
        if stream.modes.count > 1 {
            Menu {
                ForEach(stream.modes, id: \.self) { mode in
                    Button {
                        client.setMode(stream: stream.id,
                                       width: Int(mode.width), height: Int(mode.height))
                    } label: {
                        if mode == stream.size {
                            Label("\(Int(mode.width)) × \(Int(mode.height))", systemImage: "checkmark")
                        } else {
                            Text("\(Int(mode.width)) × \(Int(mode.height))")
                        }
                    }
                }
            } label: {
                Label(stream.size == .zero
                        ? "Resolution"
                        : "\(Int(stream.size.width)) × \(Int(stream.size.height))",
                      systemImage: "rectangle.inset.filled")
            }
            .menuStyle(.button)
            .padding(.horizontal, 8)
            .glassBackgroundEffect()
        }
    }

    private func aspectFit(container: CGSize, aspect: CGFloat) -> CGSize {
        guard aspect > 0, container.width > 0, container.height > 0 else { return container }
        return container.width / container.height > aspect
            ? CGSize(width: container.height * aspect, height: container.height)
            : CGSize(width: container.width, height: container.width / aspect)
    }
}

/// visionOS resizes windows freeform by default, which lets the user stretch a
/// stream away from its display's aspect ratio. `.uniform` makes the resize
/// handles scale the window while preserving shape.
struct UniformResize: UIViewRepresentable {
    let aspect: CGFloat

    func makeUIView(context: Context) -> UIView { Applier(aspect: aspect) }
    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? Applier)?.apply(aspect: aspect)
    }

    final class Applier: UIView {
        private var aspect: CGFloat
        private var sized = false

        init(aspect: CGFloat) {
            self.aspect = aspect
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply(aspect: aspect)
        }

        func apply(aspect newAspect: CGFloat) {
            aspect = newAspect
            guard let scene = window?.windowScene, aspect > 0 else { return }
            let prefs = UIWindowScene.GeometryPreferences.Vision()
            prefs.resizingRestrictions = .uniform
            // Shape the window to the display once, then let uniform resizing
            // keep it there. Re-sizing on every update would fight the user.
            if !sized {
                sized = true
                let width: CGFloat = 1280
                prefs.size = CGSize(width: width, height: width / aspect)
                prefs.minimumSize = CGSize(width: 400, height: 400 / aspect)
            }
            scene.requestGeometryUpdate(prefs)
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
