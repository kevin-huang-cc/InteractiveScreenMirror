import SwiftUI

@main
struct InteractiveScreenMirrorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
