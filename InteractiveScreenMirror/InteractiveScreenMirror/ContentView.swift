import SwiftUI

/// Lobby window: lists the Mac's virtual monitors and toggles each one in the
/// immersive space.
struct ContentView: View {
    @EnvironmentObject private var client: MirrorClient
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace

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
                    StreamToggle(stream: client.state(for: id)) { show(id) }
                }
                if client.spaceVisible {
                    Button("Hide all displays") { Task { await dismissSpace() } }
                }
            }
        }
        .padding(40)
        .onAppear { client.start() }
        // Screens left open last time come back when the Mac shows up.
        .onChange(of: client.streamIDs) { _, ids in
            if ids.contains(where: { client.state(for: $0).isOpen }) { ensureSpace() }
        }
    }

    private func show(_ id: UInt8) {
        let s = client.state(for: id)
        s.isOpen.toggle()
        if s.isOpen { ensureSpace() }
    }

    private func ensureSpace() {
        guard !client.spaceVisible else { return }
        Task { await openSpace(id: "screens") }
    }
}

private struct StreamToggle: View {
    @ObservedObject var stream: StreamState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(stream.isOpen ? "Hide display \(stream.id + 1)" : "Show display \(stream.id + 1)",
                  systemImage: stream.isOpen ? "display.trianglebadge.exclamationmark" : "display")
                .frame(maxWidth: 320)
        }
    }
}
