import SwiftUI
import RealityKit
import Metal
import CoreVideo
import CoreGraphics

/// Decoded frames → RealityKit texture. One per stream.
///
/// Apple's Mac Virtual Display gets its curve from the system compositor
/// (SpringBoard's SFBUISidecarCurveCalculator picks a cylinder radius from the
/// window width; RealityKit's UICurvatureComponent bends the layer). Third
/// parties can't opt in — `preferredWindowCurvature` is MRUIKit-private — so we
/// draw the cylinder ourselves and get an adjustable angle for free.
final class ScreenTexture {
    let texture: TextureResource
    private var queue: TextureResource.DrawableQueue?
    private var size = CGSize.zero
    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var commands = device.makeCommandQueue()!
    private var cache: CVMetalTextureCache?

    init() {
        // 2×2 black placeholder; the drawable queue replaces it on the first frame.
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        texture = try! TextureResource(image: ctx.makeImage()!, options: .init(semantic: .color))
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    /// Called on the decoder thread.
    func push(_ pb: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if queue == nil || size != CGSize(width: w, height: h) {
            // ponytail: bgra8Unorm_srgb so sampling linearises the sRGB video bytes.
            // If colours look washed out or crushed, this format is the knob.
            let desc = TextureResource.DrawableQueue.Descriptor(
                pixelFormat: .bgra8Unorm_srgb, width: w, height: h,
                usage: [.shaderRead, .renderTarget], mipmapsMode: .none)
            guard let q = try? TextureResource.DrawableQueue(desc) else { return }
            q.allowsNextDrawableTimeout = true
            queue = q
            size = CGSize(width: w, height: h)
            DispatchQueue.main.async { self.texture.replace(withDrawables: q) }
        }
        guard let q = queue, let cache, let drawable = try? q.nextDrawable() else { return }

        var cvTex: CVMetalTexture?
        // Blit requires identical formats, so view the BGRA buffer as sRGB too.
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm_srgb, w, h, 0, &cvTex)
        guard let cvTex, let src = CVMetalTextureGetTexture(cvTex),
              let cmd = commands.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else { return }
        blit.copy(from: src, to: drawable.texture)
        blit.endEncoding()
        cmd.commit()
        drawable.present()
    }
}

/// Cylinder section `width` metres of arc by `height` metres, bowing toward +z
/// (the viewer) by `angle` radians of wrap. `angle == 0` is a flat quad.
/// Centred so the middle of the sagitta sits at z = 0.
enum Screen {
    static let segments = 64

    static func radius(width: Float, angle: Float) -> Float { angle > 0.001 ? width / angle : 0 }

    static func sagitta(width: Float, angle: Float) -> Float {
        let r = radius(width: width, angle: angle)
        return r > 0 ? r * (1 - cos(angle / 2)) : 0
    }

    static func mesh(width: Float, height: Float, angle: Float) -> MeshResource {
        let r = radius(width: width, angle: angle)
        let sag = sagitta(width: width, angle: angle)
        var pos: [SIMD3<Float>] = [], uv: [SIMD2<Float>] = [], idx: [UInt32] = []
        for i in 0...segments {
            let u = Float(i) / Float(segments)
            var x = (u - 0.5) * width, z: Float = 0
            if r > 0 {
                let t = (u - 0.5) * angle
                x = r * sin(t)
                z = r * (1 - cos(t)) - sag / 2
            }
            // RealityKit samples drawable textures with v = 0 at the bottom.
            pos.append([x, height / 2, z]);  uv.append([u, 1])
            pos.append([x, -height / 2, z]); uv.append([u, 0])
        }
        for i in 0..<segments {
            let a = UInt32(i * 2)
            idx += [a, a + 1, a + 2, a + 1, a + 3, a + 2]
        }
        var d = MeshDescriptor(name: "screen")
        d.positions = .init(pos)
        d.textureCoordinates = .init(uv)
        d.primitives = .triangles(idx)
        return try! MeshResource.generate(from: [d])
    }

    /// Exact inverse of `mesh`: a point on the surface → normalised (x, y) in 0…1.
    static func uv(of p: SIMD3<Float>, width: Float, height: Float, angle: Float) -> (Double, Double) {
        let r = radius(width: width, angle: angle)
        let u: Float
        if r > 0 {
            let sag = sagitta(width: width, angle: angle)
            u = atan2(p.x, r - (p.z + sag / 2)) / angle + 0.5
        } else {
            u = p.x / width + 0.5
        }
        let v = 0.5 - p.y / height
        return (Double(max(0, min(1, u))), Double(max(0, min(1, v))))
    }
}

/// One virtual monitor as a curved screen inside a volumetric window.
struct CurvedStreamView: View {
    @ObservedObject var stream: StreamState
    let client: MirrorClient
    /// Reference type so RealityView's update closure can mutate it without
    /// touching SwiftUI state mid-render.
    final class Rig {
        let entity = ModelEntity()
        var layoutKey = SIMD3<Float>()   // (width, height, angle) last built
        var dims: SIMD3<Float> { layoutKey }
    }
    @State private var rig = Rig()

    var body: some View {
        GeometryReader3D { proxy in
            RealityView { content in
                var m = UnlitMaterial()
                m.color = .init(texture: .init(stream.screen.texture))
                rig.entity.model = ModelComponent(mesh: .generatePlane(width: 0.01, height: 0.01), materials: [m])
                rig.entity.components.set(InputTargetComponent())
                content.add(rig.entity)
            } update: { content in
                let box = content.convert(proxy.frame(in: .local), from: .local, to: .scene)
                layout(in: box.extents)
            }
            .gesture(SpatialTapGesture().targetedToEntity(rig.entity).onEnded { value in
                // Entity space, so tilt and placement fall out of the maths.
                let p = value.convert(value.location3D, from: .local, to: rig.entity)
                let d = rig.dims
                let (nx, ny) = Screen.uv(of: p, width: d.x, height: d.y, angle: d.z)
                client.sendClick(stream: stream.id, nx: nx, ny: ny)
            })
        }
        .overlay {
            if !stream.hasFrame { ProgressView("Waiting for display \(stream.id + 1)…") }
        }
        .ornament(attachmentAnchor: .scene(.leading), contentAlignment: .trailing) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Curve", systemImage: "rectangle.portrait.arrowtriangle.2.outward")
                Slider(value: $stream.curvature, in: 0...2.4)
                Label("Zoom", systemImage: "plus.magnifyingglass")
                Slider(value: $stream.zoom, in: 0.5...2.5)
                Label("Tilt", systemImage: "rotate.3d")
                Slider(value: $stream.tilt, in: 0...(.pi / 2))
                resolutionPicker
            }
            .frame(width: 200)
            .padding(16)
            .glassBackgroundEffect()
        }
    }

    /// Fit the display's aspect into the volume; keep arc length fixed so the
    /// screen wraps inward as the angle grows (what Apple's does as you zoom).
    private func layout(in extents: SIMD3<Float>) {
        guard extents.x > 0, extents.y > 0 else { return }
        // Negative: rotating the top edge away from the viewer lays it flat, face up.
        rig.entity.orientation = simd_quatf(angle: -stream.tilt, axis: [1, 0, 0])
        let aspect = Float(stream.aspect)
        let w = min(extents.x, extents.y * aspect), h = w / aspect
        var angle = stream.curvature
        // Don't bow past the volume's depth or the front gets clipped.
        while angle > 0, Screen.sagitta(width: w, angle: angle) > extents.z * 0.95 { angle *= 0.9 }
        let key = SIMD3(w, h, angle)
        guard key != rig.layoutKey else { return }
        rig.layoutKey = key
        let mesh = Screen.mesh(width: w, height: h, angle: angle)
        rig.entity.model?.mesh = mesh
        let entity = rig.entity
        Task { @MainActor in
            if let shape = try? await ShapeResource.generateStaticMesh(from: mesh) {
                entity.components.set(CollisionComponent(shapes: [shape]))
            }
        }
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
