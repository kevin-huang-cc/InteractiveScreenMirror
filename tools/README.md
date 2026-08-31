# tools

`probe.m` — dumps the private `CGVirtualDisplay*` Objective-C interfaces from the
runtime. Run this first after a macOS update; if the selectors in
`ISMPrivate.h` no longer match, virtual displays will fail to create.

```sh
clang -fobjc-arc -framework Foundation -framework CoreGraphics -o probe probe.m && ./probe
```

`Wire.swift` + `main.swift` — self-check for the UDP framing and reassembly
(fragmentation, out-of-order, drop detection, stream isolation).

```sh
swiftc -O -o wirecheck Wire.swift main.swift && ./wirecheck
```

`probeclient.swift` — headless UDP client. Discovers the Mac over Bonjour,
connects, and reports whether META, PARAM and an IDR actually arrive per
stream. Use it to tell a Mac-side problem from a visionOS-side one without
putting the headset on.

```sh
mkdir -p pc && cp Wire.swift pc/ && cp probeclient.swift pc/main.swift
cd pc && swiftc -O -o probeclient Wire.swift main.swift && ./probeclient
```

Note ScreenCaptureKit is damage-driven: an empty virtual display produces
almost no frames, which is expected and not a fault.
