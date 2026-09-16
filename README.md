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
  VTCompressionSession (HEVC, one per stream)      Reassembler (per stream)
        |                                               |
  UDP datagrams, fragmented, stream-tagged   ->    VideoDecoder x N
        |                                               |
  NWListener (Bonjour _ism._udp, peer-to-peer)     VTDecompressionSession -> RealityKit  
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
| `0x02` PARAM | Mac → VP | `[1B codec 'h'|'v'][1B count]{[4B len][bytes]}…` — HEVC VPS/SPS/PPS |
| `0x03` FRAME | Mac → VP | length-prefixed HEVC NAL units, fragmented to 1200B |
| `0x10` CLICK | VP → Mac | JSON `{x,y}` normalized 0..1 |
| `0x20` HELLO | VP → Mac | announces the client endpoint |
| `0x21` KEYFRAMEREQ | VP → Mac | a fragment was lost, resync now |
| `0x22` SETMODE | VP → Mac | JSON `{w,h}` — switch this display's resolution |
| `0x23` ACTIVE | VP → Mac | JSON `{ids:[left→right], main, below:{id: fraction}}` — shown displays and their placement; the Mac tears down the rest, recreates these, arranges the desktop to match, and splits an 80 Mbit/s budget among them |

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

## Curvature, placement and controls

All displays live in one mixed-immersion `ImmersiveSpace`. Volumes were tried
first, but visionOS dims whichever window sits behind another and boxes a
curved screen inside a fixed depth. In the space nothing dims, screens overlap
freely, and the chrome is ours:

- **Grab bar** under each screen: pinch-drag to move. On release the screen
  turns to face you, like a system window.
- **Corner knob**: drag outward to enlarge, inward to shrink.
- **Panel** beside each screen: Curve (wrap angle, 0 = flat, ~1.2 rad matches
  Apple's ultrawide), Zoom, Tilt (0 upright to 90° flat on a desk), resolution
  picker, close.
- Position, yaw, curve, zoom, tilt and open state persist per display in
  `UserDefaults`. A display shown for the first time appears 1.5 m ahead at
  eye height.

Each screen is a cylinder-section mesh textured from the decoder via
`TextureResource.DrawableQueue`. Arc length is held fixed as the angle grows,
so the screen wraps toward you the way Mac Virtual Display does when zoomed.
Taps are mapped back to display coordinates through the exact inverse of the
mesh parameterisation in the screen's own space, so clicks land where you
pinch at any curve or tilt.

How Apple does it (from the visionOS 27 simulator runtime, not source): the
curve is applied by the system compositor, not the app. SpringBoard's
`SFBUISidecarCurveCalculator` interpolates a cylinder radius between a min/max
radius from the window width between a min/max width; RealityKit's
`UICurvatureComponent` bends the window layer onto that cylinder. Apps opt in
through MRUIKit's private `preferredWindowCurvature` on `UIWindowScene`, which
is Apple-only in visionOS 27, hence the mesh here.

## Environments

Apple's environments cannot appear behind a third-party immersive space (they
are MobileAssets behind a private framework), so the app brings its own. The
lobby has an Environment picker: None (passthrough), Presets, or Photo (any
360° panorama from the library, kept in Documents). Presets opens a second row:
Studio (a generated dark gradient) and Matrix (digital rain adapted from
Rezmason/matrix, MIT, see THIRD_PARTY_LICENSES.md: a Metal compute kernel using
the original rain, cursor, glyph-cycling and palette maths plus its MSDF glyph
atlas, drawn on three concentric spheres with different seeds so the rain has
real stereo depth; compiled from source at runtime so no Metal toolchain is
needed).
With a backdrop chosen the space switches to progressive immersion, so the
Digital Crown dials passthrough against the skybox; the level is remembered.

## Main display and arrangement

The desktop arrangement follows the headset. Displays are ordered left to right
by their bearing around you, the one most in front of you is main (menu bar,
Dock, new windows), and any screen sitting more than 0.4 m below the main one,
such as a display laid flat on the desk, goes underneath, centred where its
bearing falls across the main display's width (so a desk screen off to the
right sits under the right part of the main one). Moving
screens around re-sends the layout only when the order changes. Before the
headset connects, the first virtual display is main with the rest to its right;
the built-in screen is parked underneath in either case. The arrangement is session-scoped: when the app quits and the
virtual displays vanish, macOS falls back to the built-in panel as main.

While the headset shows at least one display, the MacBook's built-in panel is
switched off with `CGSConfigureDisplayEnabled` (private, the same call
BetterDisplay uses to "disconnect" a display): it goes black and leaves
Displays settings, so the virtual displays are all macOS has, as with Apple's
Mac Virtual Display. It comes back when no display is shown or the app quits.
The app remembers the panel's id and turns it back on at the next launch if a
previous run was killed with it off; Ctrl-C and SIGTERM restore it before
exiting. If you are stuck without the app, run `swift tools/enable-builtin.swift`
from another display or over SSH, or close and reopen the lid.

## Configuring virtual displays

Edit `ScreenSpec.defaults` in `mac/.../VirtualDisplayManager.swift`. Sizes are
in points; every display is Retina, so the stream carries double:

```swift
static let defaults: [ScreenSpec] = [
    ScreenSpec(name: "ISM Wide",     width: 2560, height: 1080, refreshRate: 60),   // 5120×2160 px
    ScreenSpec(name: "ISM Portrait", width: 1200, height: 1600, refreshRate: 60),   // 2400×3200 px
]
```

Apple's Mac Virtual Display offers 5120×2880 (Standard), 6720×2880 (Wide) and
10240×2880 (Ultrawide), all at 2x. Getting 2x modes out of a virtual display
on macOS 26 needs three things at once (see `tools/hidpi-probe.swift`): the
hiDPI flag, the mode declared in points with the pixel cap at double, and a
declared physical size around 220 DPI. Miss any one and macOS offers 1x only.

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
