import SwiftUI
import RealityKit
import Metal
import CoreGraphics
import QuartzCore

/// Our own environments. Apple's are downloaded MobileAssets behind a private
/// framework and cannot be shown behind a third-party immersive space, so we
/// wrap the user in a textured sphere instead: a generated studio gradient, or
/// any 360° photo from the library.
enum Backdrop: String, CaseIterable {
    case none, studio, matrix, photo

    /// Built-in looks, shown in the Presets row.
    static let presets: [Backdrop] = [.studio, .matrix]
    var isPreset: Bool { Self.presets.contains(self) }

    /// Where the picked panorama is kept between launches.
    static let photoURL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("backdrop.jpg")

    var label: String {
        switch self {
        case .none: "None"
        case .studio: "Studio"
        case .matrix: "Matrix"
        case .photo: "Photo"
        }
    }

    /// nil for `.none`, for animated presets (see `AnimatedSky`), or if the
    /// photo is missing.
    func texture() -> TextureResource? {
        let image: CGImage?
        switch self {
        case .none, .matrix: return nil
        case .studio: image = Self.studioImage()
        case .photo:
            guard let src = CGImageSourceCreateWithURL(Self.photoURL as CFURL, nil) else { return nil }
            image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        guard let image else { return nil }
        return try? TextureResource(image: image, options: .init(semantic: .color))
    }

    /// Dark grey above a faint horizon, near-black below. Easy on text.
    private static func studioImage() -> CGImage? {
        let w = 64, h = 512
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let colors = [CGColor(gray: 0.16, alpha: 1), CGColor(gray: 0.10, alpha: 1),
                      CGColor(gray: 0.06, alpha: 1), CGColor(gray: 0.02, alpha: 1)] as CFArray
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                 locations: [0, 0.48, 0.52, 1]) else { return nil }
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(h)), end: .zero, options: [])
        return ctx.makeImage()
    }

    /// 2×2 black texture a drawable queue can take over.
    static func placeholder() -> TextureResource {
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return try! TextureResource(image: ctx.makeImage()!, options: .init(semantic: .color))
    }

    /// Sphere the viewer sits inside. Negative x scale turns the faces inward.
    // ponytail: the flip mirrors the panorama left-to-right. Custom mesh if that matters.
    static func skybox(_ texture: TextureResource) -> ModelEntity {
        var m = UnlitMaterial()
        m.color = .init(texture: .init(texture))
        let e = ModelEntity(mesh: .generateSphere(radius: 60), materials: [m])
        e.scale = [-1, 1, 1]
        e.name = "skybox"
        return e
    }
}

/// A skybox texture redrawn every frame by a Metal compute kernel.
@MainActor final class AnimatedSky {
    let texture: TextureResource
    private let queue: TextureResource.DrawableQueue
    private let commands: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let start = CACurrentMediaTime()
    private static let size = (w: 2048, h: 1024)

    /// Compiled from source at runtime, so the project needs no Metal
    /// toolchain component. About 100 ms, once per selection.
    init?(kernel: String, source: String) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let lib = try? device.makeLibrary(source: source, options: nil),
              let fn = lib.makeFunction(name: kernel),
              let ps = try? device.makeComputePipelineState(function: fn),
              let cq = device.makeCommandQueue() else { return nil }
        pipeline = ps
        commands = cq
        let desc = TextureResource.DrawableQueue.Descriptor(
            pixelFormat: .bgra8Unorm, width: Self.size.w, height: Self.size.h,
            usage: [.shaderRead, .shaderWrite], mipmapsMode: .none)
        guard let q = try? TextureResource.DrawableQueue(desc) else { return nil }
        q.allowsNextDrawableTimeout = true
        queue = q
        texture = Backdrop.placeholder()
        texture.replace(withDrawables: q)
    }

    /// One frame. Cheap enough to run at 90 Hz: 2M pixels of arithmetic.
    func render() {
        guard let drawable = try? queue.nextDrawable(),
              let cmd = commands.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return }
        var t = Float(CACurrentMediaTime() - start)
        enc.setComputePipelineState(pipeline)
        enc.setTexture(drawable.texture, index: 0)
        enc.setBytes(&t, length: MemoryLayout<Float>.size, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.dispatchThreadgroups(MTLSize(width: (Self.size.w + 15) / 16, height: (Self.size.h + 15) / 16, depth: 1),
                                 threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        drawable.present()
    }
}

/// Digital rain onto the equirect skybox. See the comments in the kernel.
let matrixRainSource = #"""
#include <metal_stdlib>
using namespace metal;

// Digital rain onto an equirectangular skybox. The classic recipe: fixed
// columns, each with its own speed and phase; a bright head glyph with an
// exponential trail above it; glyph shapes that flicker over time. Everything
// is hashed from the cell coordinates so there is no state between frames.

static float hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

kernel void matrixRain(texture2d<float, access::write> out [[texture(0)]],
                       constant float &time [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    uint W = out.get_width(), H = out.get_height();
    if (gid.x >= W || gid.y >= H) return;
    float2 uv = float2(gid) / float2(W, H);          // u around you, v = 0 at the zenith

    // Rain lives on a band around the horizon; poles fade to black so the
    // equirect pinch at the top and bottom never shows.
    float lat = (0.5 - uv.y) * M_PI_F;
    float band = smoothstep(1.35, 0.9, abs(lat));

    const float cols = 160.0;
    const float rows = cols * 0.5;                    // 2:1 texture → square cells
    float col = floor(uv.x * cols);
    float row = floor(uv.y * rows);

    float speed = 0.12 + hash(float2(col, 7.0)) * 0.30;   // texture heights per second
    float phase = hash(float2(col, 3.0));
    float head = fract(time * speed + phase);         // v of the head, falling
    float behind = fract(head - row / rows);          // how far above the head this cell is
    float trail = 0.20 + hash(float2(col, 11.0)) * 0.30;
    float b = behind < trail ? pow(1.0 - behind / trail, 1.6) : 0.0;

    // Glyph: a 5×7 random bit pattern that re-rolls a few times a second.
    float2 cell = float2(col, row);
    float flick = floor(time * (1.0 + hash(cell) * 3.0));
    float shape = hash(cell + flick * 0.37);
    float2 f = fract(uv * float2(cols, rows));
    float2 gp = (f - 0.15) / 0.7;                     // glyph fills the middle 70% of the cell
    float px = 0.0;
    if (all(gp >= 0.0) && all(gp < 1.0)) {
        float2 pix = floor(gp * float2(5.0, 7.0));
        px = step(0.55, hash(pix + shape * 100.0));
    }

    float3 green = float3(0.25, 1.0, 0.35);
    float headGlow = smoothstep(0.85, 1.0, b);
    float3 color = mix(green, float3(0.85, 1.0, 0.9), headGlow) * b * px * band;
    color += float3(0.0, 0.010, 0.003) * band;        // faint ambient so it is not a void
    out.write(float4(color, 1.0), gid);
}
"""#
