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
