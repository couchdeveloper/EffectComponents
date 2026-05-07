import SwiftUI
import EffectView

@main
struct SimpleEffectViewApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView()
                .tabItem {
                    Label("One", systemImage: "star")
                }
                
                EnvReader(\.movieListViewEnv) { env in
                    MovieListView(env: env)
                }
                .tabItem {
                    Label("Two", systemImage: "circle")
                }
            }
        }
    }
}
