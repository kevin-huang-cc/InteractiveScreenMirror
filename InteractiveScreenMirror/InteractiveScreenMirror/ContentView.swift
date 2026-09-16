import SwiftUI
import PhotosUI

/// Lobby window: lists the Mac's virtual monitors and toggles each one in the
/// immersive space.
struct ContentView: View {
    @EnvironmentObject private var client: MirrorClient
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("backdrop") private var backdrop = Backdrop.none.rawValue
    @AppStorage("backdropVersion") private var backdropVersion = 0
    @State private var photoPick: PhotosPickerItem?
    @State private var showPresets = false

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
                environmentPicker
                if client.spaceVisible {
                    Button("Hide all displays") { Task { await dismissSpace() } }
                }
            }
        }
        .padding(40)
        .onAppear { client.start() }
        // Leaving the app (or closing it) hands the Mac its own screen back.
        .onChange(of: scenePhase) { _, phase in client.suspended = phase != .active }
        // Screens left open last time come back when the Mac shows up.
        .onChange(of: client.streamIDs) { _, ids in
            if ids.contains(where: { client.state(for: $0).isOpen }) { ensureSpace() }
        }
    }

    /// None, a preset (opens a second row), or a 360° photo from the library.
    private var environmentPicker: some View {
        let current = Backdrop(rawValue: backdrop) ?? .none
        return VStack(spacing: 10) {
            HStack {
                choice("None", selected: current == .none) { backdrop = Backdrop.none.rawValue; showPresets = false }
                choice("Presets", selected: current.isPreset) { showPresets.toggle() }
                choice("Photo", selected: current == .photo) { backdrop = Backdrop.photo.rawValue; showPresets = false }
                PhotosPicker(selection: $photoPick, matching: .panoramas) {
                    Image(systemName: "photo.badge.plus")
                }
                .buttonBorderShape(.circle)
            }
            if showPresets {
                HStack {
                    ForEach(Backdrop.presets, id: \.rawValue) { p in
                        choice(p.label, selected: current == p) { backdrop = p.rawValue }
                    }
                }
            }
        }
        .onAppear { showPresets = current.isPreset }
        .onChange(of: photoPick) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    try? data.write(to: Backdrop.photoURL, options: .atomic)
                    backdropVersion += 1
                    backdrop = Backdrop.photo.rawValue
                    showPresets = false
                }
                photoPick = nil
            }
        }
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .tint(selected ? .accentColor : nil)
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
