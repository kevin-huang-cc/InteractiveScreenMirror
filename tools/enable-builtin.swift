// Emergency: turn the MacBook's built-in display back on if the app was killed
// while it had the panel disabled.   swift tools/enable-builtin.swift
import CoreGraphics
import Foundation
@_silgen_name("CGSConfigureDisplayEnabled")
func CGSConfigureDisplayEnabled(_ cfg: CGDisplayConfigRef, _ id: CGDirectDisplayID, _ on: Bool) -> CGError
func online() -> [CGDirectDisplayID] {
    var n: UInt32 = 0; CGGetOnlineDisplayList(0, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n)); CGGetOnlineDisplayList(n, &ids, &n); return ids
}
print("online before:", online())
// A disabled display is not listed, so try the ids macOS gives built-in panels
// (1 on every Apple Silicon MacBook seen so far). One transaction per id: a
// bad id fails the whole transaction.
for id: CGDirectDisplayID in [1, 4, 5, 6, 7, 8, 9, 10] {
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { continue }
    _ = CGSConfigureDisplayEnabled(cfg, id, true)
    guard CGCompleteDisplayConfiguration(cfg, .forSession) == .success else { continue }
    Thread.sleep(forTimeInterval: 2)
    let now = online()
    if now.contains(where: { CGDisplayIsBuiltin($0) != 0 }) { print("built-in is back (id \(id)):", now); exit(0) }
}
print("no luck; online:", online(), "— close and reopen the lid or plug in an external display")
