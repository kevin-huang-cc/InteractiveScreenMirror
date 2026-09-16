import SwiftUI

@main
struct InteractiveScreenMirrorApp: App {
    @StateObject private var client = MirrorClient.shared
    /// Whether real hands are cut out in front of the screens. Space-wide.
    @AppStorage("handsVisible") private var handsVisible = true

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(client)
        }
        .defaultSize(width: 600, height: 460)

        // All displays live in one mixed space so none dims the others.
        ImmersiveSpace(id: "screens") {
            ScreensSpace().environmentObject(client)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .upperLimbVisibility(handsVisible ? .visible : .hidden)
    }
}
