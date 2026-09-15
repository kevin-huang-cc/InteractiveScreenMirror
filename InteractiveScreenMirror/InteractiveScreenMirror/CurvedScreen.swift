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
