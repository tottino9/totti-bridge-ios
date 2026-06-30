import SwiftUI

@main
struct RokidLyricsIOSApp: App {
    @StateObject private var store: LyricsRuntimeStore

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["ROKID_SCREENSHOT_MODE"] == "1" {
            _store = StateObject(wrappedValue: LyricsRuntimeStore.screenshotPreviewStore())
            return
        }
        #endif
        _store = StateObject(wrappedValue: LyricsRuntimeStore())
    }

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
