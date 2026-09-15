import SwiftUI

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

/// One virtual monitor in its own volume. Drag it anywhere in space.
struct StreamView: View {
    let streamID: UInt8
    @EnvironmentObject private var client: MirrorClient

    var body: some View {
        // StreamState must be observed here, not just read. Reading it inline
        // meant `hasFrame` flipping never invalidated the view, so the
        // "Waiting for display" spinner stayed up over live video.
        StreamVolume(stream: client.state(for: streamID), client: client)
    }
}

/// Sizes the volume from the zoom slider: volumes have no system zoom gesture,
/// so the content declares its size in metres and the window follows.
private struct StreamVolume: View {
    @ObservedObject var stream: StreamState
    let client: MirrorClient
    @PhysicalMetric(from: .meters) private var meter: CGFloat = 1

    var body: some View {
        let w = 1.3 * meter * stream.zoom
        let h = w / stream.aspect
        CurvedStreamView(stream: stream, client: client)
            .volumeBaseplateVisibility(.hidden)
            .frame(width: w, height: h)
            // Depth = height so the screen fits when tilted flat; the curve's
            // bow needs less than that.
            .frame(depth: h)
    }
}
