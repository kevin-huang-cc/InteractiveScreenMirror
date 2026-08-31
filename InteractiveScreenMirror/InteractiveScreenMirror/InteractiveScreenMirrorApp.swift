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
        .defaultSize(width: 1280, height: 540)
    }
}
