import SwiftUI

@main
struct RokidLyricsIOSApp: App {
    @StateObject private var store = LyricsRuntimeStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .onOpenURL { url in
                    store.handleOpenURL(url)
                }
        }
    }
}
