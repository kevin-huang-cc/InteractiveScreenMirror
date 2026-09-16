import SwiftUI

@main
struct InteractiveScreenMirrorApp: App {
    @StateObject private var client = MirrorClient.shared
    /// Whether real hands are cut out in front of the screens. Space-wide.
    @AppStorage("handsVisible") private var handsVisible = true
    @AppStorage("backdrop") private var backdrop = Backdrop.none.rawValue
    @AppStorage("immersion") private var immersion = 0.6

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(client)
        }
        .defaultSize(width: 600, height: 460)

        // All displays live in one mixed space so none dims the others.
        ImmersiveSpace(id: "screens") {
            ScreensSpace().environmentObject(client)
        }
        // With a backdrop the Crown dials passthrough against our skybox.
        .immersionStyle(selection: .constant(backdrop == Backdrop.none.rawValue
                                                ? .mixed
                                                : .progressive(0.1...1, initialAmount: min(1, max(0.1, immersion)))),
                        in: .mixed, .progressive)
        .upperLimbVisibility(handsVisible ? .visible : .hidden)
    }
}
