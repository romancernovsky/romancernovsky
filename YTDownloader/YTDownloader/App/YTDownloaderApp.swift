import AVFoundation
import SwiftUI

@main
struct YTDownloaderApp: App {

    init() {
        // Play sound even when the ring/silent switch is set to silent.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {

    enum Tab: Hashable { case download, videos }

    @State private var tab: Tab = .download
    private var manager: DownloadManager { DownloadManager.shared }

    var body: some View {
        TabView(selection: $tab) {
            NewDownloadView(onStarted: { tab = .videos })
                .tabItem { Label("Download", systemImage: "arrow.down.circle") }
                .tag(Tab.download)

            LibraryView()
                .tabItem { Label("Videos", systemImage: "film.stack") }
                .badge(manager.activeCount)
                .tag(Tab.videos)
        }
    }
}
