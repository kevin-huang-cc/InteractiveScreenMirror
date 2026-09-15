import SwiftUI

@main
struct InteractiveScreenMirrorApp: App {
    @StateObject private var client = MirrorClient.shared

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(client)
        }
        .defaultSize(width: 600, height: 460)

        // One window per virtual monitor, opened on demand.
        WindowGroup(id: "stream", for: UInt8.self) { $streamID in
            if let streamID {
                StreamView(streamID: streamID).environmentObject(client)
            }
        }
        .windowStyle(.volumetric)
        .windowResizability(.contentSize)
        // Depth is headroom for the curve: a 1.2 m screen at 2.4 rad bows ~0.4 m.
        .defaultSize(width: 1.3, height: 0.8, depth: 0.5, in: .meters)
    }
}
