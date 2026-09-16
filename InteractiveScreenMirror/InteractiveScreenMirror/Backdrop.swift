import SwiftUI
import RealityKit
import Metal
import MetalKit
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
    static func skybox(_ texture: TextureResource, radius: Float = 60, transparent: Bool = false) -> ModelEntity {
        var m = UnlitMaterial()
        m.color = .init(texture: .init(texture))
        // Alpha from the texture, so rain layers show the ones behind them.
        if transparent { m.blending = .transparent(opacity: 1.0) }
        let e = ModelEntity(mesh: .generateSphere(radius: radius), materials: [m])
        e.scale = [-1, 1, 1]
        e.name = "skybox"
        return e
    }
}

/// A skybox texture redrawn every frame by a Metal compute kernel. The rain is
/// three virtual layers composited in the kernel; each is shifted by the
/// parallax a sphere at its radius would show from the current head position,
/// so near rain slides past far rain as you move even though the mesh is one
/// sphere. (Real stacked transparent spheres rendered as one opaque shell.)
@MainActor final class AnimatedSky {
    /// Two float4s: identical 32-byte layout in Swift and Metal. (A float3
    /// pads differently on each side and tripped Metal's argument validation.)
    private struct Uniforms { var time: SIMD4<Float>; var head: SIMD4<Float> }

    let entity: ModelEntity
    private let queue: TextureResource.DrawableQueue
    private let commands: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let atlas: MTLTexture?
    private let start = CACurrentMediaTime()
    private var origin: SIMD3<Float>?
    // 4K around: with ~160 columns on the near layer that is ~25 px per glyph.
    private static let size = (w: 4096, h: 2048)
    /// Where the shell sits. Stereo puts everything here; parallax says otherwise.
    static let radius: Float = 16

    /// Compiled from source at runtime, so the project needs no Metal
    /// toolchain component. About 100 ms, once per selection.
    init?(kernel: String, source: String, atlas atlasName: String? = nil) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let lib = try? device.makeLibrary(source: source, options: nil),
              let fn = lib.makeFunction(name: kernel),
              let ps = try? device.makeComputePipelineState(function: fn),
              let cq = device.makeCommandQueue() else { return nil }
        pipeline = ps
        commands = cq
        if let atlasName, let url = Bundle.main.url(forResource: atlasName, withExtension: "png") {
            // Raw MSDF values, not colour: no sRGB decode.
            atlas = try? MTKTextureLoader(device: device).newTexture(URL: url, options: [
                .SRGB: false, .origin: MTKTextureLoader.Origin.topLeft,
            ])
        } else {
            atlas = nil
        }
        let desc = TextureResource.DrawableQueue.Descriptor(
            pixelFormat: .bgra8Unorm, width: Self.size.w, height: Self.size.h,
            usage: [.shaderRead, .shaderWrite], mipmapsMode: .none)
        guard let q = try? TextureResource.DrawableQueue(desc) else { return nil }
        q.allowsNextDrawableTimeout = true
        queue = q
        let tex = Backdrop.placeholder()
        tex.replace(withDrawables: q)
        entity = Backdrop.skybox(tex, radius: Self.radius)
    }

    /// One frame. `head` is the device position in scene space, if tracked.
    func render(head: SIMD3<Float>?) {
        guard let drawable = try? queue.nextDrawable(),
              let cmd = commands.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return }
        // Parallax is relative to where the head was when the rain appeared.
        if origin == nil, let head { origin = head }
        let offset = (head ?? .zero) - (origin ?? .zero)
        var u = Uniforms(time: [Float(CACurrentMediaTime() - start), 0, 0, 0],
                         head: [offset.x, offset.y, offset.z, 0])
        enc.setComputePipelineState(pipeline)
        enc.setTexture(drawable.texture, index: 0)
        enc.setTexture(atlas, index: 1)
        enc.setBytes(&u, length: MemoryLayout<Uniforms>.size, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: (Self.size.w + 15) / 16, height: (Self.size.h + 15) / 16, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        cmd.commit()
        drawable.present()
    }
}

/// Digital rain onto the equirect skybox, adapted from Rezmason/matrix (MIT,
/// see THIRD_PARTY_LICENSES.md). Their multi-pass state textures collapse into
/// one stateless kernel: brightness and cursor come straight from the rain
/// function, glyph cycling from a hashed tick. Bloom and effects are skipped.
let matrixRainSource = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms { float4 time; float4 head; };   // .x is time; head.xyz

constant float PI = 3.14159265359;
constant float FALL_SPEED = 0.3;          // config.js defaults follow
constant float RAINDROP_LENGTH = 0.75;
constant float CYCLE_RATE = 1.8;          // cycleSpeed 0.03 × 60 fps
constant float GLYPH_COUNT = 57.0;        // matrixcode atlas
constant float GRID = 8.0;
constant float PX_RANGE = 4.0;
constant float ATLAS = 512.0;
constant float BASE_CONTRAST = 1.1;
constant float BASE_BRIGHTNESS = -0.5;
constant float DITHER = 0.05;
// Ours: the web version is tuned for a monitor. Wrapped around you it glares.
constant float CURSOR_INTENSITY = 1.2;    // web default 2
constant float DIM = 0.45;                // overall brightness
// Virtual layers, near to far: radius (m), columns around, brightness, focus.
// Depth cues per layer: parallax (radius), size (columns), fall speed on screen
// (∝ 1/radius), atmosphere (dim + fog), and focus (MSDF edge softness).
constant int LAYERS = 3;
constant float4 LAYER[LAYERS] = { float4(8.0, 160.0, 1.0, 1.0),
                                  float4(14.0, 240.0, 0.6, 0.55),
                                  float4(24.0, 320.0, 0.35, 0.3) };
constant float3 FOG = float3(0.0);               // far layers fade toward black
// ponytail: flip to -1 if head motion shifts the rain the wrong way (sphere UV handedness).
constant float PARALLAX_SIGN = 1.0;

static float randomFloat(float2 uv) {
    const float a = 12.9898, b = 78.233, c = 43758.5453;
    float dt = dot(uv, float2(a, b)), sn = fmod(dt, PI);
    return fract(sin(sn) * c);
}

static float wobble(float x) {
    return x + 0.3 * sin(1.4142135623730951 * x) + 0.2 * sin(2.23606797749979 * x);
}

// Why glyphs in a column light together and brighten toward the bottom,
// and why the bright run is cut into raindrops. glyphPos.y counts upward.
static float rainBrightness(float simTime, float2 glyphPos, float seed, float speedScale) {
    float columnTimeOffset = randomFloat(float2(glyphPos.x, seed)) * 1000.0;
    float columnSpeedOffset = randomFloat(float2(glyphPos.x + 0.1, seed)) * 0.5 + 0.5;
    float columnTime = columnTimeOffset + simTime * FALL_SPEED * speedScale * columnSpeedOffset;
    float rainTime = wobble((glyphPos.y * 0.01 + columnTime) / RAINDROP_LENGTH);
    return 1.0 - fract(rainTime);
}

static float3 hsl(float h, float s, float l) {
    float c = (1.0 - abs(2.0 * l - 1.0)) * s;
    float hp = h * 6.0;
    float x = c * (1.0 - abs(fmod(hp, 2.0) - 1.0));
    float3 rgb = hp < 1.0 ? float3(c, x, 0) : hp < 2.0 ? float3(x, c, 0) : hp < 3.0 ? float3(0, c, x)
               : hp < 4.0 ? float3(0, x, c) : hp < 5.0 ? float3(x, 0, c) : float3(c, 0, x);
    return rgb + (l - c / 2.0);
}

// Default palette: hue 0.3, sat 0.9, lightness tracking brightness up to 0.8.
static float3 palette(float b) { return hsl(0.3, 0.9, clamp(b, 0.0, 0.8)); }

static float median3(float3 i) { return max(min(i.r, i.g), min(max(i.r, i.g), i.b)); }

// Equirect ↔ direction. Only needs to be self-consistent.
static float3 dirFromUV(float2 uv) {
    float phi = (uv.x - 0.5) * 2.0 * PI, theta = (0.5 - uv.y) * PI;
    return float3(cos(theta) * sin(phi), sin(theta), -cos(theta) * cos(phi));
}
static float2 uvFromDir(float3 d) {
    return float2(atan2(d.x, -d.z) / (2.0 * PI) + 0.5, 0.5 - asin(clamp(d.y, -1.0, 1.0)) / PI);
}

// Where the ray from the (offset) head through this texel hits a sphere of
// radius r around the origin. That is the layer's own equirect coordinate.
static float2 parallaxUV(float2 uv, float3 head, float r) {
    float3 d = dirFromUV(uv);
    float b = dot(head, d);
    float t = -b + sqrt(max(b * b - dot(head, head) + r * r, 0.0));
    return uvFromDir(normalize(head + t * d));
}

// One rain layer: colour and coverage at this texel.
static float4 rainLayer(float2 uv, float time, float cols, float seed, float dim, float focus,
                        float speedScale, float W, texture2d<float, access::sample> atlas, float2 gid) {
    float ROWS = cols * 0.5;                          // 2:1 texture → square cells
    float2 cellF = uv * float2(cols, ROWS);
    float2 cell = floor(cellF);
    float2 glyphPos = float2(cell.x, ROWS - 1.0 - cell.y);   // y up, like gl_FragCoord
    float2 screenPos = (glyphPos + 0.5) / float2(cols, ROWS) + seed;

    // Raindrop pass
    float b = rainBrightness(time, glyphPos, seed, speedScale);
    float bBelow = rainBrightness(time, glyphPos + float2(0.0, -1.0), seed, speedScale);
    bool cursor = b > bBelow;

    // Symbol pass: each cell re-rolls its glyph CYCLE_RATE times a second, offset per cell
    float phase = randomFloat(screenPos + 0.5);
    float tick = floor(time * CYCLE_RATE + phase);
    float symbol = floor(GLYPH_COUNT * randomFloat(screenPos + tick * 0.123));

    // MSDF glyph lookup. Rows are stored top-down already; x flips because the
    // inside-out sphere mirrors the texture and the film's glyphs are drawn
    // mirrored in the atlas, so the two cancel and read the normal way round.
    float2 f = fract(cellF);
    float2 g = float2(1.0 - f.x, f.y);
    float sx = fmod(symbol, GRID);
    float sy = GRID - floor(symbol / GRID) - 1.0;
    float2 atlasUV = (g + float2(sx, sy)) / GRID;
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float sd = median3(atlas.sample(smp, atlasUV).rgb);
    // Analytic fwidth. `focus` < 1 widens the edge ramp: cheap depth of field.
    // The ramp is a smoothstep around the 0.5 isoline that always reaches
    // zero for texels far from the glyph, so soft never means a grey cell.
    float screenPxRange = max(PX_RANGE / ATLAS * GRID * W / cols, 1.0) * focus;
    float halfWidth = min(0.5, 0.5 / screenPxRange);
    float sym = smoothstep(0.5 - halfWidth, 0.5 + halfWidth, sd);

    // Rain pass brightness, then the palette pass
    float base = b * BASE_CONTRAST + BASE_BRIGHTNESS;
    float texR = cursor ? 0.0 : base * sym;
    float texG = cursor ? base * sym : 0.0;
    float d = randomFloat(gid + fract(time)) * DITHER / 3.0;
    float3 cursorColor = hsl(0.242, 1.0, 0.73);
    float3 color = (palette(texR - d) + min(cursorColor * CURSOR_INTENSITY * (texG - d), float3(1.0))) * DIM * dim;
    // Atmosphere: the dimmer the layer, the more it sinks toward the fog colour.
    color = mix(FOG * sym, color, dim);
    return float4(color, saturate(max3(color.r, color.g, color.b) * 2.0));
}

kernel void matrixRain(texture2d<float, access::write> out [[texture(0)]],
                       texture2d<float, access::sample> atlas [[texture(1)]],
                       constant Uniforms &u [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    uint W = out.get_width(), H = out.get_height();
    if (gid.x >= W || gid.y >= H) return;
    float2 uv = float2(gid) / float2(W, H);           // v = 0 at the zenith

    float lat = (0.5 - uv.y) * PI;
    float band = smoothstep(1.35, 0.9, abs(lat));     // poles fade out

    float3 head = u.head.xyz * float3(PARALLAX_SIGN, 1.0, 1.0);
    float time = u.time.x;
    float3 color = 0.0;
    // Far to near, each layer over the ones behind it.
    for (int i = LAYERS - 1; i >= 0; i--) {
        float4 L = LAYER[i];
        float2 luv = parallaxUV(uv, head, L.x);
        float speedScale = LAYER[0].x / L.x;          // same metres/s → slower on screen when far
        float4 c = rainLayer(luv, time, L.y, 10.0 * float(i + 1), L.z, L.w, speedScale, float(W), atlas, float2(gid));
        color = color * (1.0 - c.a) + c.rgb;
    }
    out.write(float4(color * band, 1.0), gid);
}
"""#
