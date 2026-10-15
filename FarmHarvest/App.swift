import SwiftUI
import WidgetKit

@main
struct FarmHarvestApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    WidgetCenter.shared.reloadAllTimelines()
                }
        }
    }
}
