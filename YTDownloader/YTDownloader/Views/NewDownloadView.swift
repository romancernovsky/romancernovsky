import SwiftUI
import UIKit

/// Tab 1: paste a link, pick a resolution, start downloading.
struct NewDownloadView: View {

    /// Called after downloads were queued, so the app can switch to the Videos tab.
    var onStarted: () -> Void

    @State private var model = NewDownloadModel()
    @State private var showSettings = false
    @State private var showMyPlaylists = false
    @FocusState private var linkFocused: Bool

    private var storage: StorageManager { StorageManager.shared }

    var body: some View {
        NavigationStack {
            Form {
                linkSection
                accountSection

                switch model.phase {
                case .idle:
                    EmptyView()
                case .working(let message):
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(message).foregroundStyle(.secondary)
                        }
                        Button("Cancel", role: .cancel) { model.cancel() }
                    }
                case .failed(let message):
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                case .ready:
                    resolutionSection
                    videosSection
                    downloadSection
                }

                Section {
                    Label(storage.locationDescription, systemImage: "folder")
                        .font(.footnote)
                } header: {
                    Text("Saved to")
                } footer: {
                    Text("You can change the folder (for example to Downloads) in Settings ⚙︎.")
                }
            }
            .navigationTitle("Download")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showMyPlaylists) {
                MyPlaylistsView { playlist in model.startLookup(ownPlaylist: playlist) }
            }
        }
    }

    // MARK: - Sections

    private var linkSection: some View {
        Section {
            TextField("https://www.youtube.com/watch?v=…", text: $model.link, axis: .vertical)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($linkFocused)
                .lineLimit(1...3)
                .submitLabel(.search)
                .onSubmit(find)

            HStack {
                Button {
                    if let text = UIPasteboard.general.string { model.link = text }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                Spacer()
                if !model.link.isEmpty {
                    Button(role: .destructive) { model.reset() } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                }
            }
            .buttonStyle(.borderless)

            Button(action: find) {
                Label("Find videos & resolutions", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
            }
            .disabled(model.link.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
        } header: {
            Text("YouTube link")
        } footer: {
            Text("Paste a link to a single video or to a playlist.")
        }
    }

    private var accountSection: some View {
        Section {
            if GoogleAuth.shared.isSignedIn {
                AccountBadge()
                Button {
                    linkFocused = false
                    showMyPlaylists = true
                } label: {
                    Label("Download from my playlists", systemImage: "list.bullet.rectangle.portrait")
                }
                .disabled(isWorking)
            } else if GoogleAuth.shared.isConfigured {
                SignInButton()
            } else {
                Button { showSettings = true } label: {
                    Label("Set up YouTube sign-in…", systemImage: "person.crop.circle.badge.questionmark")
                }
            }
        } header: {
            Text("Your YouTube")
        } footer: {
            if !GoogleAuth.shared.isSignedIn {
                Text("Sign in to pick from your own playlists, including private ones and Liked videos.")
            }
        }
    }

    private var resolutionSection: some View {
        Section {
            ForEach(model.options) { option in
                Button {
                    model.selectedHeight = option.height
                } label: {
                    HStack {
                        Text(option.label).fontWeight(.semibold)
                        if let hint = qualityHint(option.height) {
                            Text(hint).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.rows.count > 1 {
                            Text("\(option.availableCount) of \(model.rows.count)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Image(systemName: model.selectedHeight == option.height ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model.selectedHeight == option.height ? Color.accentColor : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .foregroundStyle(.primary)
            }
        } header: {
            Text("Resolution")
        } footer: {
            if model.rows.count > 1 {
                Text("“12 of 15” means 12 videos have exactly this resolution. The others are downloaded in their closest lower resolution.")
            }
        }
    }

    private var videosSection: some View {
        Section {
            ForEach(model.rows) { row in
                Button { model.toggle(row) } label: {
                    HStack(spacing: 12) {
                        if model.rows.count > 1 {
                            Image(systemName: row.selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(row.selected ? Color.accentColor : .secondary)
                        }
                        ThumbnailView(localFile: nil, remoteURL: row.video.thumbnailURL)
                            .frame(width: 80, height: 45)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.video.title).font(.subheadline).lineLimit(2)
                            if let error = row.error {
                                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                            } else if let best = row.heights?.max() {
                                Text("Up to \(best)p").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .foregroundStyle(.primary)
                .disabled(row.error != nil)
            }
        } header: {
            HStack {
                Text(headerTitle).lineLimit(1)
                Spacer()
                if model.rows.count > 1 {
                    Button(model.allSelected ? "Select none" : "Select all") { model.toggleAll() }
                        .font(.caption)
                        .textCase(nil)
                }
            }
        }
    }

    private var downloadSection: some View {
        Section {
            Button(action: startDownload) {
                Label(downloadTitle, systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
                    .fontWeight(.bold)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .disabled(model.selectedVideos.isEmpty || model.selectedHeight == nil)
        }
    }

    // MARK: - Actions & helpers

    private var isWorking: Bool {
        if case .working = model.phase { return true }
        return false
    }

    private var headerTitle: String {
        let count = model.rows.count
        let title = model.collectionTitle ?? (model.isPlaylist ? "Playlist" : "Video")
        return count > 1 ? "\(title) · \(count) videos" : title
    }

    private var downloadTitle: String {
        let count = model.selectedVideos.count
        let resolution = model.selectedHeight.map { " in \($0)p" } ?? ""
        return count == 1 ? "Download video\(resolution)" : "Download \(count) videos\(resolution)"
    }

    private func qualityHint(_ height: Int) -> String? {
        switch height {
        case 2160...: return "4K"
        case 1440..<2160: return "QHD"
        case 1080..<1440: return "Full HD"
        case 720..<1080: return "HD"
        default: return nil
        }
    }

    private func find() {
        linkFocused = false
        model.startLookup()
    }

    private func startDownload() {
        guard let height = model.selectedHeight else { return }
        DownloadManager.shared.enqueue(model.selectedVideos, height: height)
        model.reset()
        onStarted()
    }
}
