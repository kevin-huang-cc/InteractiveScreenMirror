# InteractiveScreenMirror — implementation notes

N virtual monitors on the Mac, each streamed to its own Vision Pro window.
Pinch → click on the right display. Native pipeline, no third-party deps.

**Latency: not yet re-measured** after the move from TCP to UDP. The previous
TCP build measured ~60ms glass-to-glass; Apple's first-party Mac Virtual
Display is ~25–35ms. The changes below should close a good part of that gap,
but the number is a to-do, not a claim.

## Architecture

```
Mac:                                          visionOS:
  CGVirtualDisplay x N  (private CoreGraphics)  NWBrowser _ism._udp (P2P)
        |                                             |
  SCStream per display (queueDepth 3)           NWConnection (UDP)
        |                                             |
  VTCompressionSession per display              Reassembler (per stream)
   (H.264, MaxFrameDelayCount 0, GOP 30)              |
        |                                        VideoDecoder x N
  Wire.datagrams -> fragmented UDP  --------->        |
        |                                        AVSampleBufferDisplayLayer x N
  NWListener (Bonjour, includePeerToPeer)             |
        ^--------- click {stream,x,y} ---------  SpatialTapGesture
```

## What changed from the first TCP version

The original was a single TCP connection carrying one display. Every item
below was a measured or structural latency problem in that design.

| Was | Now | Why |
|-----|-----|-----|
| TCP | UDP | One lost packet head-of-line-blocked every frame behind it. Also removes Nagle, which was never disabled and could add up to 40ms. |
| Router path | `includePeerToPeer` on both ends | The old code set P2P only on a throwaway `NWBrowser` used to prime the permission dialog — the actual video connection went Mac → router → Vision Pro. |
| Manual IP entry | Bonjour `_ism._udp` | Also survives DHCP lease changes. |
| `queueDepth = 5` | `queueDepth = 3` | 5 frames at 60fps is ~83ms of buffer sitting in front of the encoder. 3 is the SCK realtime minimum. |
| `MaxFrameDelayCount` unset | `0` | The encoder was free to hold frames for lookahead. |
| No backpressure | drop when encoder busy | `conn.send` fired and forgot; under congestion frames queued without bound and latency grew monotonically and never recovered. |
| Params sent once | sent with every keyframe | UDP has no retransmit; a client that missed them recovered never. |
| GOP 60 | GOP 30 + keyframe requests | Loss recovers in ≤0.5s even if the request datagram is itself lost. |
| Frames enqueued on main | enqueued on the network queue | `AVSampleBufferDisplayLayer.enqueue` is thread-safe; hopping to main put every frame behind SwiftUI. |
| `removeSubrange` parser | fixed 10B header + index math | The old parser memcpy'd the whole buffer per message. |
| Single stream | streamID in every datagram | Required for multi-display; retrofitting it later would have meant touching both codebases again. |

## Correctness fix worth remembering

`CMBlockBufferCreateWithMemoryBlock` was being handed a pointer from
`UnsafeMutableRawPointer.allocate` while `blockAllocator` was
`kCFAllocatorDefault` — the block buffer would free with an allocator that did
not allocate it. Now the block buffer owns its memory and the frame is copied
in with `CMBlockBufferReplaceDataBytes`.

## Reliability without retransmission

UDP gives up ordering and delivery, so each message type buys back only what
it needs:

- **FRAME** — lossy by design. Incomplete after 4 newer frame ids → dropped,
  and a KEYFRAMEREQ goes out. Stale frames (id ≤ last delivered) are discarded.
- **PARAM / META** — re-sent with every keyframe. Self-healing within one GOP.
- **CLICK** — sent three times with the same id; the Mac dedupes on
  `(stream, id)` with a 256-entry window. Cheaper than an ACK and a lost click
  is very visible.

## Private API: CGVirtualDisplay

No public headers. `ISMPrivate.h` declares the four classes, verified against
the runtime on macOS 26.2 via `tools/probe.m`.

Sharp edges found while wiring it up:

- The `CGVirtualDisplay` object must stay retained. Releasing it tears the
  display down, which is why `VirtualScreen` holds `handle`.
- sRGB primaries and a `whitePoint` must be set or macOS may reject the display.
- `initWithDescriptor:` has no nullability annotation, so Swift imports it as
  optional.
- Swift renames `applySettings:` to `apply(_:)`.
- `hiDPI = 1` doubles the backing store: a 2560x1080 hiDPI display presents as
  1280x540 points.

Re-run `probe` after any macOS update. If selectors drift, creation returns nil
and the app logs a warning rather than crashing.

## Permissions sharp edges

| Permission | Where | Notes |
|------------|-------|-------|
| Screen Recording | macOS Privacy & Security | Auto-prompts on first `SCStream`; requires relaunch after granting |
| Accessibility | macOS Privacy & Security | Required for `CGEvent` click injection. **Re-grant on most rebuilds** — the DerivedData path carries a hash and the grant silently detaches when it changes |
| Local Network | visionOS Privacy & Security | Needs **both** `NSLocalNetworkUsageDescription` and `NSBonjourServices` in Info.plist. With only the latter, access is denied silently with no error |

App Sandbox must be **disabled** on the Mac target or `NWListener.bind()` fails
with EPERM.

## Findings on hiDPI and refresh rate

Measured on macOS 26.2 with `tools/probe.m` and one-config-per-process tests:

- **90Hz virtual displays work.** `CGDisplayModeGetRefreshRate` confirms 90Hz.
  This matters: Vision Pro's compositor runs at 90Hz, and 60fps content lands
  at an arbitrary phase against it, which reads as judder even when latency is
  fine.
- **`hiDPI = 1` is useless here.** It generates no 2x modes for a virtual
  display — enumerating `CGDisplayCopyAllDisplayModes` shows every mode with
  `pixels == points`. It only halves usable resolution. It also requires the
  mode to be declared at *point* size; passing a pixel-size mode makes
  registration fail while `applySettings` still returns `true`.
- **`applySettings` returning true means nothing.** The display id appears
  asynchronously and can stay 0 or unregistered. Poll `displayID` and
  `CGDisplayPixelsWide` before trusting it.
- **Duplicate serials collide silently.** Two processes creating displays with
  the same vendor/product/serial: the second fails with no error, looking
  exactly like the private API having broken. Serial now includes the pid.
- Creating and destroying virtual displays rapidly in a loop **segfaults**.
  Space them out.

## Resolution switching

- `CGDisplayCopyAllDisplayModes` returns **nil** for a freshly created virtual
  display, even after `CGDisplayPixelsWide` reports the correct size. The mode
  list populates later than the display, so poll for it.
- Advertised modes are filtered to the display's native aspect (within 1%) and
  to even dimensions, which H.264 wants.
- Switching uses `CGBeginDisplayConfiguration` /
  `CGConfigureDisplayWithDisplayMode`, then tears down and rebuilds that
  stream's `ScreenCapturer` — `SCStream`'s config is fixed at start and a
  `VTCompressionSession` is fixed at its creation size.
- Repeated commands must be deduped. Clients send three copies of clicks and
  mode changes; without deduping, one resolution pick reconfigured the display
  and restarted capture three times.

## Window resizing

visionOS windows are freeform by default. `UIWindowScene.GeometryPreferences.Vision`
with `resizingRestrictions = .uniform` makes pinch-resize preserve aspect ratio.
Applied per stream window via a `UIViewRepresentable` that reaches its
`windowScene` in `didMoveToWindow`. The initial size is set once — re-sizing on
every update fights the user.

## Open questions

- **Is AWDL actually being used?** `dns-sd -B _ism._udp local` shows the service
  on lo0/en0/bridge100 but not awdl0 when nothing is browsing. macOS brings
  AWDL up on demand, so this may only appear once a Vision Pro connects with
  P2P enabled. Unverified. Check `netstat -I awdl0` byte counters while
  streaming — if they stay flat, traffic is going via the router.
- **Why is text soft?** hiDPI turned out to be a dead end, so the remaining
  candidates are H.264 4:2:0 chroma subsampling (text edges are its worst
  case), bitrate, and any resampling between the 2560px-wide stream and the
  window's rendered size in the headset. Untested.
- **How many streams before it hurts?** M4 Pro encode and Vision Pro decode
  both have ceilings. Guess is 3–4 comfortable, 6+ painful. Untested.
- **HEVC** — better compression, hardware-decoded on Vision Pro. Parameter set
  extraction differs (VPS/SPS/PPS), so it is not a one-line change.

## Lessons learned

- `@main` on a bare `NSApplicationDelegate` doesn't bootstrap AppKit — use an
  explicit `main.swift`.
- `find -type f` does not match symlinks. Counting files that way will tell you
  a `node_modules` tree is empty when it holds hundreds of them.
- `Data.withUnsafeBytes { $0.load(as: UInt32.self) }` crashes on misaligned
  reads. Always `loadUnaligned(as:)` on network buffers — the 1-byte type
  prefix guarantees odd offsets.
- The `LISTENING` log line can lie. Verify with `lsof`.
- Xcode projects at objectVersion 77 use synchronized file groups: new source
  files in the folder are picked up with no pbxproj edit.
- `stasel/WebRTC` and most prebuilt WebRTC frameworks ship no visionOS slice.
