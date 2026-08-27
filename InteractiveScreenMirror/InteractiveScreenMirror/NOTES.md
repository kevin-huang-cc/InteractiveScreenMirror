# InteractiveScreenMirror

Mac display → Vision Pro window. Pinch in Vision Pro → click on Mac. Native pipeline, no third-party deps.

Measured latency: ~60ms glass-to-glass on a typical home Wi-Fi (vs Apple's first-party Mac Virtual Display at ~25–35ms over AWDL).

## Architecture

```
Mac:                                                    visionOS:
  ScreenCaptureKit (SCStream, BGRA → YUV)                 NWConnection (TCP client)
        ↓                                                    ↓
  VTCompressionSession (H.264 Main, 40 Mbps avg,          WireParser (length-prefixed framing)
   60 Mbps peak, 60fps, GOP=60)                              ↓
        ↓                                                  VideoDecoder
  Length-prefixed wire protocol                              ↓ (CMSampleBufferCreateReady)
        ↓                                                  AVSampleBufferDisplayLayer
  NWListener (TCP, port 7777)         ←──────────────  SpatialTapGesture
        ↓                                                    ↑
  CGEvent.post (mouse down/up)        ←──── click JSON ──────┘
```

Single TCP connection carries everything: video frames Mac → Vision Pro, click events Vision Pro → Mac.

## Wire protocol

Each message: `[1-byte type][4-byte big-endian length][payload]`.

| Type | Direction | Payload |
|------|-----------|---------|
| `0x01` META | Mac → Vision Pro | JSON `{"w":..., "h":...}` — display dimensions for aspect-fit |
| `0x02` PARAM | Mac → Vision Pro | `[4B sps_len][SPS][4B pps_len][PPS]` — H.264 parameter sets |
| `0x03` FRAME | Mac → Vision Pro | AVCC-formatted NAL units (4-byte length prefixes) |
| `0x10` CLICK | Vision Pro → Mac | JSON `{"x":nx, "y":ny}` — normalized 0..1 coordinates |

Length fields are read with `loadUnaligned(as:)` because the 1-byte type prefix puts the UInt32 on an odd offset.

## Tech stack

**Mac (`mac/InteractiveScreenMirror/`)** — AppKit, macOS 14+
- `main.swift` — explicit `NSApplication.shared.run()` bootstrap (avoids the `@main` AppKit pitfall on bare `NSApplicationDelegate`)
- `AppDelegate.swift` — wires capture → encoder → server, requests Accessibility permission
- `ScreenCapturer.swift` — `SCStream` at 60fps, YUV 4:2:0 BiPlanar, full main display
- `VideoEncoder.swift` — `VTCompressionSession`, hardware H.264, real-time mode, no frame reordering
- `Server.swift` — `NWListener` on TCP/7777, gates sends on `.ready` state, caches PARAM for late joiners, injects clicks via `CGEvent`
- `Wire.swift` — framing protocol

**visionOS (`InteractiveScreenMirror/InteractiveScreenMirror/`)** — SwiftUI + UIKit interop, visionOS 1.2+
- `InteractiveScreenMirrorApp.swift` — single `WindowGroup`, no `ImmersiveSpace`
- `ContentView.swift` — connect form ↔ video surface, `SpatialTapGesture` for clicks, `aspectFit` to letterbox
- `Client.swift` — `NWConnection` to Mac, primes Local Network permission via a no-op `NWBrowser`, tears down cleanly on disconnect
- `VideoDecoder.swift` — builds `CMSampleBuffer` from PARAM + FRAME, marks `kCMSampleAttachmentKey_DisplayImmediately`
- `Wire.swift` — mirror of Mac framing
- The `AVSampleBufferDisplayLayer` is hosted via a `UIViewRepresentable` so SwiftUI can size + clip it

## Permissions sharp edges

| Permission | Where | Notes |
|------------|-------|-------|
| Screen Recording | macOS System Settings → Privacy & Security | Auto-prompts on first `SCStream` use; requires app relaunch after granting |
| Accessibility | macOS System Settings → Privacy & Security | Required for `CGEvent` click injection. **Re-grant required on most rebuilds** because the binary identity changes |
| Local Network | visionOS Settings → Privacy & Security | Triggered by the dummy `NWBrowser` for `_ism._tcp`. Requires `NSLocalNetworkUsageDescription` + `NSBonjourServices` in Info.plist |

App Sandbox must be **disabled** on the Mac target — otherwise `NWListener.bind()` fails with EPERM.

## Known limitations (intentional, MVP scope)

- One-shot click only — no drag, no scroll, no right-click, no modifier keys, no keyboard
- Single-monitor capture (main display) — multi-display would need a picker UI
- One Vision Pro client at a time (newest connection cancels previous)
- Same Wi-Fi only — no NAT traversal, no auth
- Audio is not captured or sent
- Manual IP entry — no Bonjour-based auto-discovery
- Free Apple Developer profile caps Vision Pro to 3 sideloaded apps and re-signs every 7 days

## Why we are slower than Apple's Mac Virtual Display

| Factor | Apple | This project |
|--------|-------|--------------|
| Transport | AWDL (peer-to-peer Wi-Fi, ~1 Gbps clean channel) | Regular Wi-Fi via your router |
| Codec hints | Private VideoToolbox tunings (foveated regions, gaze-aware re-encoding) | Public APIs only |
| Input path | Continuity (privileged, no Accessibility prompt) | `CGEvent` (requires user-granted Accessibility) |
| Latency | 25–35ms | ~60ms |

AWDL is kernel-level and not exposed to third-party apps; there is no entitlement to request it. The remaining gap of 10–20ms is mostly the AWDL advantage; the rest is private encoder tuning we can't replicate.

## Future improvement paths

Ordered by effort vs payoff:

**Easy wins (hours):**
- HEVC instead of H.264 — better compression for high-motion content. Change codec type to `kCMVideoCodecType_HEVC` in `VideoEncoder.swift`. Vision Pro decodes HEVC in hardware.
- Shorter GOP (`MaxKeyFrameInterval = 30` or `15`) for faster recovery during Mission Control / Spaces transitions
- Pinch-and-drag — track gesture phase in `SpatialTapGesture` (or switch to `DragGesture`), send `mouseDown` / `mouseDragged` / `mouseUp` events
- Right-click via long-press
- Scroll via two-finger drag → `CGEvent` scroll wheel events
- Keyboard input — overlay an invisible `TextField`, capture changes, forward as `CGEvent` key events

**Medium (a day or two):**
- Bonjour-based auto-discovery — Mac advertises `_ism._tcp`, Vision Pro browses and shows a picker. We already advertise the service name via the dummy browser; just need to actually register on Mac and consume the browse results on Vision Pro.
- Adaptive quality — drop captured frames when the encoder backs up; reduce resolution during heavy transitions
- Cursor smoothing on the Vision Pro side — debounce/predict gaze drift before sending click coordinates
- Multi-display support — extend META to enumerate displays, let user pick

**Larger (a week or more):**
- Audio capture + playback — `SCStream` already supports audio; needs an `AVSampleBufferAudioRenderer` or `AVAudioEngine` on Vision Pro
- Hand-tracking-driven cursor — full 3D ray cast from index fingertip, more responsive than gaze+pinch for power use. Requires `ARKitSession` + `HandTrackingProvider`.
- Encryption + pairing — at minimum TLS via `NWParameters.tls`, pairing via QR code
- Multiple virtual monitors — render multiple display-layers in 3D space using RealityKit, switch from `WindowGroup` to `ImmersiveSpace`

**Probably not worth pursuing:**
- AWDL access — kernel-level, not exposed, no public path. The OWL research project ports the protocol but you can't ship apps that use it on iOS/visionOS. Tune the network you have instead.
- Foveated encoding — would require integrating gaze tracking into the wire protocol and re-encoding regions. Limited payoff without AWDL bandwidth headroom.

## Build & run

```sh
# Mac (one-time)
cd mac/InteractiveScreenMirror
open InteractiveScreenMirror.xcodeproj
# In Xcode: target → Build Settings → set "Enable App Sandbox" to NO
# ⌘R, grant Screen Recording, then add to Accessibility manually

# visionOS
cd ../../InteractiveScreenMirror/InteractiveScreenMirror
open InteractiveScreenMirror.xcodeproj
# ⌘R on real device, allow Local Network prompt
# Type Mac IP printed in Mac console, tap Connect
```

## Lessons learned

- `@main` on a bare `NSApplicationDelegate` doesn't bootstrap AppKit — use explicit `main.swift`.
- visionOS Local Network privacy prompt only fires reliably when there's a Bonjour browser running, even if you only do direct IP TCP.
- `Data.withUnsafeBytes { $0.load(as: UInt32.self) }` will crash with "load from misaligned raw pointer" if the offset isn't 4-aligned. Always use `loadUnaligned(as:)` when reading from network buffers.
- macOS App Sandbox is on by default for new Xcode projects and silently blocks `NWListener.bind()` with EPERM. The "LISTENING" log can lie — verify with `lsof -nP -iTCP:7777 -sTCP:LISTEN`.
- `stasel/WebRTC` (and most prebuilt WebRTC frameworks) ship iOS + macOS slices only — no visionOS slice. We dropped WebRTC for direct VideoToolbox + TCP.
