import SwiftUI
import RealityKit
import ARKit

/// Every open display as an entity in one mixed immersive space. Volumes
/// dimmed whatever sat behind them and boxed the curve in; here nothing dims,
/// screens overlap freely, and we own the chrome: a grab bar to move, a corner
/// knob to resize, and a floating panel per screen.
struct ScreensSpace: View {
    @EnvironmentObject private var client: MirrorClient
    @State private var rig = Rig()

    /// Per-screen entities plus drag bookkeeping. Reference type so the
    /// RealityView update closure can mutate it freely.
    final class Rig {
        final class Item {
            let root = Entity()
            let screen = ModelEntity()
            let bar = ModelEntity(mesh: .generateBox(width: 0.24, height: 0.012, depth: 0.012, cornerRadius: 0.006),
                                  materials: [SimpleMaterial(color: .white, isMetallic: false)])
            let knob = ModelEntity(mesh: .generateSphere(radius: 0.014),
                                   materials: [SimpleMaterial(color: .white, isMetallic: false)])
            var layoutKey = SIMD3<Float>()   // (width, height, angle) last built
            var dims: SIMD3<Float> { layoutKey }
        }
        var items: [UInt8: Item] = [:]
        var dragStart: (position: SIMD3<Float>, zoom: Float)?
        let session = ARKitSession()
        let world = WorldTrackingProvider()

        /// Head position and forward direction, or nil before tracking settles.
        var head: (position: SIMD3<Float>, forward: SIMD3<Float>)? {
            guard world.state == .running,
                  let a = world.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else { return nil }
            let m = a.originFromAnchorTransform
            return ([m.columns.3.x, m.columns.3.y, m.columns.3.z],
                    -[m.columns.2.x, m.columns.2.y, m.columns.2.z])
        }
    }

    var body: some View {
        RealityView { _, _ in
            Task { try? await rig.session.run([rig.world]) }
        } update: { content, attachments in
            sync(content, attachments)
        } attachments: {
            ForEach(client.openStreams) { stream in
                Attachment(id: stream.id) {
                    ScreenPanel(stream: stream, client: client)
                }
            }
        }
        .onAppear { client.spaceVisible = true }
        .onDisappear { client.spaceVisible = false }
        .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { value in
            guard let (id, role) = Self.parse(value.entity.name), role == "screen",
                  let item = rig.items[id] else { return }
            let p = value.convert(value.location3D, from: .local, to: item.screen)
            let d = item.dims
            let (nx, ny) = Screen.uv(of: p, width: d.x, height: d.y, angle: d.z)
            client.sendClick(stream: id, nx: nx, ny: ny)
        })
        .gesture(DragGesture().targetedToAnyEntity()
            .onChanged { value in
                guard let (id, role) = Self.parse(value.entity.name),
                      let item = rig.items[id] else { return }
                let stream = client.state(for: id)
                if rig.dragStart == nil { rig.dragStart = (stream.position, stream.zoom) }
                guard let start = rig.dragStart else { return }
                let t = value.convert(value.translation3D, from: .local, to: .scene)
                switch role {
                case "bar":
                    // Write through to the model so an update mid-drag can't snap it back.
                    stream.position = start.position + t
                case "knob":
                    // Pull the corner outward to grow. 0.65 m of drag doubles a 1× screen.
                    let out = simd_dot(t, item.root.orientation.act([1, -1, 0]) / sqrt(2))
                    stream.zoom = min(3, max(0.4, start.zoom + out / 0.65))
                default: break
                }
            }
            .onEnded { value in
                defer { rig.dragStart = nil }
                guard let (id, role) = Self.parse(value.entity.name), role == "bar" else { return }
                let stream = client.state(for: id)
                // Like system windows, turn to face you once you let go.
                if let head = rig.head {
                    let d = head.position - stream.position
                    stream.yaw = atan2(d.x, d.z)
                }
            })
    }

    private static func parse(_ name: String) -> (UInt8, String)? {
        let parts = name.split(separator: "-")
        guard parts.count == 2, let id = UInt8(parts[1]) else { return nil }
        return (id, String(parts[0]))
    }

    /// Reconcile entities with the set of open streams and their settings.
    private func sync(_ content: RealityViewContent, _ attachments: RealityViewAttachments) {
        let open = client.openStreams
        for (id, item) in rig.items where !open.contains(where: { $0.id == id }) {
            item.root.removeFromParent()
            rig.items[id] = nil
        }
        for stream in open {
            let item = rig.items[stream.id] ?? make(stream, in: content)
            item.root.position = stream.position
            item.root.orientation = simd_quatf(angle: stream.yaw, axis: [0, 1, 0])
            // Negative: rotating the top edge away from you lays it flat, face up.
            item.screen.orientation = simd_quatf(angle: -stream.tilt, axis: [1, 0, 0])
            layout(stream, item)
            if let panel = attachments.entity(for: stream.id) {
                item.root.addChild(panel)
                panel.position = [-(item.dims.x / 2 + 0.2), 0, 0.02]
                panel.orientation = simd_quatf(angle: 0.35, axis: [0, 1, 0])
                panel.scale = .init(repeating: 1.5)   // attachments default to 1360 pt/m
            }
        }
    }

    private func make(_ stream: StreamState, in content: RealityViewContent) -> Rig.Item {
        let item = Rig.Item()
        // First time this display is shown: 1.5 m ahead, at eye height, facing you.
        if !stream.placed, let head = rig.head {
            var f = head.forward; f.y = 0; f = simd_normalize(f)
            stream.position = head.position + f * 1.5
            stream.yaw = atan2(-f.x, -f.z)
            stream.placed = true
        }
        var m = UnlitMaterial()
        m.color = .init(texture: .init(stream.screen.texture))
        item.screen.model = ModelComponent(mesh: .generatePlane(width: 0.01, height: 0.01), materials: [m])
        item.screen.name = "screen-\(stream.id)"
        item.bar.name = "bar-\(stream.id)"
        item.knob.name = "knob-\(stream.id)"
        for e in [item.screen, item.bar, item.knob] as [ModelEntity] {
            e.components.set(InputTargetComponent())
            e.components.set(HoverEffectComponent())
            item.root.addChild(e)
        }
        item.bar.generateCollisionShapes(recursive: false)
        item.knob.generateCollisionShapes(recursive: false)
        content.add(item.root)
        rig.items[stream.id] = item
        return item
    }

    /// Fixed arc length, so a bigger angle wraps the screen toward you.
    private func layout(_ stream: StreamState, _ item: Rig.Item) {
        let w = 1.3 * stream.zoom, h = w / Float(stream.aspect)
        let key = SIMD3(w, h, stream.curvature)
        guard key != item.layoutKey else { return }
        item.layoutKey = key
        let mesh = Screen.mesh(width: w, height: h, angle: stream.curvature)
        item.screen.model?.mesh = mesh
        item.bar.position = [0, -h / 2 - 0.05, 0]
        item.knob.position = [w / 2 + 0.03, -h / 2 - 0.03, 0]
        let screen = item.screen
        Task { @MainActor in
            if let shape = try? await ShapeResource.generateStaticMesh(from: mesh) {
                screen.components.set(CollisionComponent(shapes: [shape]))
            }
        }
    }
}

/// Floating controls beside each screen.
struct ScreenPanel: View {
    @ObservedObject var stream: StreamState
    let client: MirrorClient

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Display \(stream.id + 1)").font(.headline)
                Spacer()
                Button { stream.isOpen = false } label: { Image(systemName: "xmark") }
                    .buttonBorderShape(.circle)
            }
            Label("Curve", systemImage: "rectangle.portrait.arrowtriangle.2.outward")
            Slider(value: $stream.curvature, in: 0...2.4)
            Label("Zoom", systemImage: "plus.magnifyingglass")
            Slider(value: $stream.zoom, in: 0.4...3)
            Label("Tilt", systemImage: "rotate.3d")
            Slider(value: $stream.tilt, in: 0...(.pi / 2))
            if !stream.hasFrame { ProgressView("Waiting for display…") }
            resolutionPicker
        }
        .frame(width: 240)
        .padding(16)
        .glassBackgroundEffect()
    }

    @ViewBuilder private var resolutionPicker: some View {
        if stream.modes.count > 1 {
            Menu {
                ForEach(stream.modes, id: \.self) { mode in
                    Button {
                        client.setMode(stream: stream.id, width: Int(mode.width), height: Int(mode.height))
                    } label: {
                        if mode == stream.size {
                            Label("\(Int(mode.width)) × \(Int(mode.height))", systemImage: "checkmark")
                        } else {
                            Text("\(Int(mode.width)) × \(Int(mode.height))")
                        }
                    }
                }
            } label: {
                Label(stream.size == .zero ? "Resolution"
                        : "\(Int(stream.size.width)) × \(Int(stream.size.height))",
                      systemImage: "rectangle.inset.filled")
            }
            .menuStyle(.button)
        }
    }
}
