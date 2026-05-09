import SwiftUI
import EffectView

@main
struct EffectViewExampleApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                Counter.ContentView()
                .tabItem {
                    Label("Counter", systemImage: "plus.forwardslash.minus")
                }
                
                Movies.ContentView()
                .tabItem {
                    Label("Movies", systemImage: "film")
                }
            }
        }
    }
}
