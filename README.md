# InteractiveScreenMirror

Stream a Mac display into a visionOS window. Pinch in visionOS → click on the Mac.

MVP scope only: video one-way, click one-way. No drag, no scroll, no keyboard, no audio, no smoothing. Native pipeline — no WebRTC, no third-party deps.

## Architecture

```
Mac:    ScreenCaptureKit → VTCompressionSession (H.264) → TCP server (port 7777)
                                                            ↓
                                                       length-prefixed messages
                                                            ↓
visionOS:                  TCP client → CMSampleBuffer ← AVSampleBufferDisplayLayer
                                          ↑
                                     pinch → click event back over the same socket
```

Wire protocol: `[1-byte type][4-byte BE length][payload]`. Types: `META` (JSON dims), `PARAM` (SPS/PPS), `FRAME` (AVCC NAL units), `CLICK` (JSON normalized x,y).

## Mac app

The Mac side has no Xcode project yet — only sources and an xcodegen spec at `mac/`. To run:

```sh
brew install xcodegen
(cd mac && xcodegen generate)
open mac/InteractiveScreenMirror.xcodeproj
```

Build & run in Xcode. On first launch macOS prompts for **Screen Recording**. You must also grant **Accessibility** manually in System Settings → Privacy & Security → Accessibility — without it, click injection silently no-ops. Note the IP printed in the Xcode console.

## visionOS app

Xcode project lives at `InteractiveScreenMirror/InteractiveScreenMirror/InteractiveScreenMirror.xcodeproj`. Open and run on a real Vision Pro (not simulator — pinch input is hardware-only).

If you previously added the `stasel/WebRTC` Swift package, **remove it** — we no longer use it. File → Package Dependencies → select WebRTC → minus.

Enter the Mac's IP in the field and tap Connect.

## Known sharp edges

- Accessibility permission must be re-granted whenever the app's binary identity changes (i.e. most rebuilds during development). Re-add it in System Settings if clicks stop working.
- Same Wi-Fi only. No NAT traversal, no auth.
- Only one Vision Pro client at a time — a new connection cancels the previous.
- 60fps target, 12 Mbps H.264 baseline. Tune in `VideoEncoder.swift` if needed.

## Layout

```
mac/
  project.yml                # xcodegen spec
  Sources/
    AppDelegate.swift        # lifecycle + permissions
    ScreenCapturer.swift     # SCStream → VideoEncoder
    VideoEncoder.swift       # VTCompressionSession (H.264, AVCC)
    Server.swift             # NWListener TCP, frames out / clicks in
    Wire.swift               # framing protocol
InteractiveScreenMirror/
  InteractiveScreenMirror/
    InteractiveScreenMirror.xcodeproj
    InteractiveScreenMirror/
      InteractiveScreenMirrorApp.swift
      ContentView.swift          # connect form + video surface + SpatialTapGesture
      Client.swift               # NWConnection, parser/decoder wiring
      VideoDecoder.swift         # build CMSampleBuffer from PARAM + FRAME
      Wire.swift                 # mirror of Mac-side framing
```
