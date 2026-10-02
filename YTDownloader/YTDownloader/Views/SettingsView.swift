import SwiftUI
import UniformTypeIdentifiers

/// Where to save videos, plus a short explanation of what the app can and cannot do.
struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var showFolderPicker = false
    @State private var errorMessage: String?

    private var storage: StorageManager { StorageManager.shared }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(storage.locationDescription, systemImage: "folder.fill")

                    Button {
                        showFolderPicker = true
                    } label: {
                        Label("Choose a folder (e.g. Downloads)…", systemImage: "folder.badge.plus")
                    }

                    if storage.customFolderBookmark != nil {
                        Button {
                            storage.useAppFolder()
                        } label: {
                            Label("Use the app's own folder", systemImage: "iphone")
                        }
                    }
                } header: {
                    Text("Save new videos to")
                } footer: {
                    Text("iPhone apps may only write to folders you allow. Tap “Choose a folder”, open “On My iPhone” or “iCloud Drive”, select “Downloads” and tap Open. A “Video” folder is created inside it. Videos already downloaded stay where they are.")
                }

                Section("Good to know") {
                    Text("Resolutions offered are the ones YouTube provides in the iPhone-compatible MP4 format. That is usually up to 1080p. Higher resolutions use formats that can't be saved as standard MP4 files.")
                    Text("Keep the app open while downloading. iOS pauses downloads a short while after you leave the app; they continue automatically when you return, or you can tap Retry.")
                    Text("Only download videos you have the right to save, such as your own uploads or videos the creator allows to be downloaded.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    do {
                        try storage.useCustomFolder(url)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .alert("Could not use this folder", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}
