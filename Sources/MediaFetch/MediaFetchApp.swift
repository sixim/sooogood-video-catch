import SwiftUI

@main
struct MediaFetchApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 760, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 860, height: 700)
    }
}
