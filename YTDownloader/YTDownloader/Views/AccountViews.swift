import AuthenticationServices
import SwiftUI

/// "Sign in with Google" button. Opens Google's own sign-in page in a secure browser sheet.
struct SignInButton: View {
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var auth: GoogleAuth { GoogleAuth.shared }

    var body: some View {
        Button {
            Task {
                isWorking = true
                defer { isWorking = false }
                do {
                    try await auth.signIn(using: webAuthenticationSession)
                } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                    // User closed the sheet – nothing to report.
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } label: {
            HStack {
                Label("Sign in to YouTube", systemImage: "person.crop.circle.badge.plus")
                if isWorking { Spacer(); ProgressView() }
            }
        }
        .disabled(isWorking || !auth.isConfigured)
        .alert("Sign-in failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

/// Small avatar + channel name of the signed-in account.
struct AccountBadge: View {
    private var auth: GoogleAuth { GoogleAuth.shared }

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: auth.accountImageURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(auth.accountName ?? "Signed in").font(.subheadline.weight(.medium))
                Text("YouTube account").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Sheet listing the signed-in user's own playlists (plus "Liked videos").
struct MyPlaylistsView: View {
    var onPick: (YouTubeAPI.Playlist) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [YouTubeAPI.Playlist] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading your playlists…")
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Couldn't load playlists", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try again") { Task { await load() } }
                    }
                } else if playlists.isEmpty {
                    ContentUnavailableView("No playlists", systemImage: "list.bullet.rectangle",
                                           description: Text("This YouTube account has no playlists yet."))
                } else {
                    List(playlists) { playlist in
                        Button {
                            onPick(playlist)
                            dismiss()
                        } label: {
                            row(playlist)
                        }
                        .foregroundStyle(.primary)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("My playlists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func row(_ playlist: YouTubeAPI.Playlist) -> some View {
        HStack(spacing: 12) {
            Group {
                if let url = playlist.thumbnailURL {
                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
                        Rectangle().fill(.quaternary)
                    }
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: playlist.title == "Liked videos" ? "hand.thumbsup.fill" : "list.bullet")
                            .foregroundStyle(.secondary))
                }
            }
            .frame(width: 80, height: 45)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title).font(.subheadline.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    if let count = playlist.itemCount {
                        Text("\(count) videos")
                    }
                    if let privacy = playlist.privacy {
                        Label(privacy.capitalized, systemImage: privacy == "private" ? "lock.fill" : "globe")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func load() async {
        isLoading = playlists.isEmpty
        errorMessage = nil
        do {
            playlists = try await YouTubeAPI().myPlaylists()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
