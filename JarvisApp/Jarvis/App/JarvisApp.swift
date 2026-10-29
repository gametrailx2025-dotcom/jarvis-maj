import SwiftUI

@main
struct JarvisApp: App {
    @StateObject private var model = AppModel()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        #if os(macOS)
        .defaultSize(width: 1400, height: 880)
        #endif
    }
}
