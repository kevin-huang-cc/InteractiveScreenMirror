# InteractiveScreenMirror

Creates virtual monitors on a Mac and streams each one to its own window on
Apple Vision Pro. Drag any app onto a virtual display and it appears in the
headset as a separate, movable window. Pinch to click.

Native pipeline — ScreenCaptureKit, VideoToolbox, Network.framework. No
third-party dependencies.

## How it works

```
Mac                                              Vision Pro
  CGVirtualDisplay  x N   (private API)            NWBrowser (_ism._udp, P2P)
        |                                               |
  ScreenCaptureKit (one SCStream per display)      NWConnection (UDP)
        |                                               |
  VTCompressionSession (H.264, one per stream)     Reassembler (per stream)
        |                                               |
  UDP datagrams, fragmented, stream-tagged   ->    VideoDecoder x N
        |                                               |
  NWListener (Bonjour _ism._udp, peer-to-peer)     AVSampleBufferDisplayLayer x N
        ^                                               |
        +---- click {stream, x, y} --------------  SpatialTapGesture
```

Clicks carry a stream id, so the Mac injects them at the right coordinates on
the right virtual display.

## Wire protocol

One UDP socket carries every stream. Datagram header is 10 bytes:

```
[1B type][1B streamID][4B msgID][2B fragIndex][2B fragCount][payload...]
```

| Type | Direction | Payload |
|------|-----------|---------|
| `0x01` META | Mac → VP | JSON `[{id,w,h,modes}]` — one entry per virtual display |
| `0x02` PARAM | Mac → VP | `[4B spsLen][SPS][4B ppsLen][PPS]` |
| `0x03` FRAME | Mac → VP | AVCC NAL units, fragmented to 1200B |
| `0x10` CLICK | VP → Mac | JSON `{x,y}` normalized 0..1 |
| `0x20` HELLO | VP → Mac | announces the client endpoint |
| `0x21` KEYFRAMEREQ | VP → Mac | a fragment was lost, resync now |
| `0x22` SETMODE | VP → Mac | JSON `{w,h}` — switch this display's resolution |

UDP has no retransmission, so reliability is bought with repetition instead:
PARAM and META ride along with every keyframe, and clicks and mode changes are
sent three times with the same id (the Mac dedupes — without that, one pick
reconfigures the display and restarts capture three times). Frames that never complete are dropped and
trigger a keyframe request.

## Resolution and window shape

Each stream window carries a resolution picker in a bottom ornament, listing
the modes that display actually reports, filtered to its native aspect ratio so
switching never changes the window's shape. Picking one reconfigures the Mac
display and rebuilds that stream's capture and encoder (a
`VTCompressionSession` is fixed at its creation size).

Stream windows use `UIWindowSceneResizingRestrictionsUniform`, so pinch-resize
scales the window while preserving the display's aspect ratio rather than
letting you stretch it freeform.

## Configuring virtual displays

Edit `ScreenSpec.defaults` in `mac/.../VirtualDisplayManager.swift`:

```swift
static let defaults: [ScreenSpec] = [
    ScreenSpec(name: "ISM Wide",     width: 2560, height: 1080, hiDPI: false),
    ScreenSpec(name: "ISM Portrait", width: 1200, height: 1600, hiDPI: false),
]
```

Any aspect ratio works. Note that Vision Pro resolves roughly 34 pixels per
degree, so a window filling ~60° of view is saturated around 2000px wide —
past that you spend bandwidth and encoder time on detail the optics cannot
resolve.

## Build & run

Set your team on both targets (Signing & Capabilities), then:

```sh
# 1. Mac — must run first, it is the server
open mac/InteractiveScreenMirror/InteractiveScreenMirror.xcodeproj
```

Grant **Screen Recording** (relaunch after), and add the app to
**Accessibility** manually — without it clicks silently no-op. Verify it is
actually serving:

```sh
lsof -nP -iUDP:7777        # the LISTENING log line can lie; this cannot
dns-sd -B _ism._udp local  # should list InteractiveScreenMirror
```

```sh
# 2. visionOS — real device only, pinch input is hardware-only
open InteractiveScreenMirror/InteractiveScreenMirror.xcodeproj
```

Allow the Local Network prompt. The app finds the Mac over Bonjour — no IP to
type. Each virtual display gets an "Open display N" button.

## Private API

`CGVirtualDisplay` and friends are private CoreGraphics classes with no public
headers. `mac/.../ISMPrivate.h` declares them; the declarations were verified
against the Objective-C runtime on macOS 26.2.

After a macOS update, re-run `tools/probe.m` and compare. If the selectors
drift, virtual display creation returns nil and the app logs a warning rather
than crashing. This is personal-use tooling — it is not App Store shippable.

## Checks

```sh
cd tools
swiftc -O -o wirecheck Wire.swift main.swift && ./wirecheck   # framing + reassembly
clang -fobjc-arc -framework Foundation -framework CoreGraphics -o probe probe.m && ./probe
```

## Known limitations

- One-shot click only — no drag, scroll, right-click, or keyboard
- One Vision Pro client at a time
- Same network only — no NAT traversal, no auth, no encryption
- No audio
- H.264; HEVC would compress better and Vision Pro decodes it in hardware
- App Sandbox must stay disabled on the Mac target or `NWListener` fails
