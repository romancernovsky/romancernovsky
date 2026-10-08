# YT Downloader – iOS app

A native iPhone app (SwiftUI) that downloads YouTube videos or whole playlists in the resolution you choose. It shows progress for each video, lets you retry failed downloads, and lets you play and delete the videos you've saved.

## What it does

| Step | What happens |
|------|--------------|
| 1. Paste link | A video link (`youtube.com/watch?v=…`, `youtu.be/…`, `/shorts/…`) or a playlist link (`…list=…`). |
| 2. Find videos & resolutions | For a playlist, the app reads every video in it. It then asks YouTube which resolutions each video offers. |
| 3. Pick a resolution | You see every resolution found, for example "1080p · 12 of 15". You can untick individual videos. |
| 4. Download | Videos download two at a time. Each one has its own progress bar showing %, MB and resolution. |
| 5. Retry | If a video fails, tap **Retry** (or **Retry failed** for all of them). It continues from where it stopped. |
| ★ Your playlists | Sign in with your YouTube (Google) account and pick from **your own playlists**, including private ones and *Liked videos*. |
| 6. Play / Delete | Finished videos show a thumbnail. Tap to play, or swipe left (or use the ⋯ menu) to delete. |

### Where videos are saved
- **Default:** Files app › *On My iPhone* › *YT Downloader* › **Video**
- **Your Downloads folder:** go to Settings ⚙︎ › *Choose a folder*, pick **Downloads** and tap *Open*. New videos then go to **Downloads › Video**.
  iOS doesn't let an app write to Downloads until you grant that one-time permission, which is why this step is needed.

## How it works (architecture)

```
YTDownloader/
├── App/YTDownloaderApp.swift        App start + the two tabs (Download, Videos)
├── Models/
│   ├── VideoInfo.swift              A video (id, title, thumbnail) and a resolution option
│   └── DownloadItem.swift           One download: status, progress, file name (saved as JSON)
├── Services/
│   ├── GoogleAuth.swift             Sign in with Google (OAuth 2.0 + PKCE), token kept in Keychain
│   ├── YouTubeAPI.swift             Official YouTube Data API: your channel, playlists, playlist videos
│   ├── YouTubeLink.swift            Understands all YouTube link formats
│   ├── PlaylistFetcher.swift        Lists all videos in a playlist (YouTube's internal web API)
│   ├── VideoInspector.swift         Finds the available resolutions (YouTubeKit library)
│   ├── ChunkedDownloader.swift      Downloads in 10 MB pieces → fast, resumable
│   ├── VideoMerger.swift            Joins HD picture + sound into one .mp4 (no quality loss)
│   ├── StorageManager.swift         Video folder, Downloads-folder permission, file names
│   └── DownloadManager.swift        Queue (2 at a time), retry, delete, saves the library
└── Views/                           Screens: Download, Videos list, Player, Settings
```

Background on the technical choices:
- **Separate picture and sound.** For anything above 360p, YouTube sends the picture and the sound as two separate files. The app downloads both and joins them with Apple's AVFoundation in "passthrough" mode, which copies the data without re-encoding. It takes seconds and keeps the original quality.
- **Resolutions.** The app only offers H.264 video with AAC sound, the format iPhone plays natively and saves as a standard `.mp4`. YouTube usually provides this up to **1080p**. 1440p and 4K only come in VP9/AV1 formats, which can't be saved as a normal iPhone MP4 without re-encoding.
- **Download in pieces.** YouTube slows down long single connections. Downloading in 10 MB pieces keeps it fast and lets Retry resume instead of starting over.
- **Extraction.** Stream addresses come from the open-source [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit) library. If YouTube changes its internal API, YouTubeKit falls back to its maintainer's remote helper service. When that happens, update the package in Xcode (*File › Packages › Update to Latest Package Versions*).

## Signing in to YouTube (optional, one-time setup)

Signing in lets the app list **your own playlists**, including private ones and *Liked videos*. It uses Google's official sign-in: Google's own page opens in a secure browser sheet, and the app never sees your password. It only asks for **read-only** access to YouTube.

Google requires every app that uses sign-in to have its own free "client ID". You create it once, in about 10 minutes:

1. Go to **https://console.cloud.google.com** and sign in with the Google account that owns your YouTube channel. Create a new project, e.g. "YT Downloader".
2. **APIs & Services › Library**: search for **YouTube Data API v3** and click **Enable**.
3. **Google Auth Platform** (called "OAuth consent screen" in older menus):
   - **Branding**: app name "YT Downloader", your e-mail as support and developer contact.
   - **Audience**: user type **External**. Under **Test users**, add your own Gmail address.
   - **Data access**: add the scope `.../auth/youtube.readonly`.
4. **Clients › Create client**: application type **iOS**. Bundle ID: exactly the bundle identifier you set in Xcode, e.g. `com.yourname.ytdownloader`. Click **Create** and copy the **Client ID** (it ends with `.apps.googleusercontent.com`).
5. In the app, open **Settings ⚙︎ › YouTube account**, paste the client ID, and tap **Sign in to YouTube**.
   Google shows *"Google hasn't verified this app"*. That's expected for a private app; tap **Continue**.
6. Back on the **Download** tab, tap **Download from my playlists**.

Tip: to avoid typing the ID on the phone, paste it into `builtInClientID` in `Services/GoogleAuth.swift` before building.

Good to know:
- While the Google project is in *Testing* mode, Google asks you to sign in again every 7 days. To avoid that, click **Publish app** under *Audience*. It stays private as long as you don't share the client ID.
- Signing in is only used to **list** playlists. The videos are fetched the same way as without signing in, so **private videos can't be downloaded**. Public and unlisted videos in your playlists work.
- When you paste a link to a private playlist while signed in, the app reads it through your account automatically.
- The free YouTube API allowance (10,000 units a day) covers roughly 5,000 playlist pages a day, far more than personal use needs.

## Running it on your iPhone

You need a **Mac with Xcode** (free from the Mac App Store). A free Apple ID is enough; a paid developer account isn't required.

1. Download this repository to the Mac (green **Code** button › *Download ZIP*, or `git clone`).
2. Open `YTDownloader/YTDownloader.xcodeproj` in Xcode. Xcode downloads the YouTubeKit package automatically (watch the progress at the top).
3. Click the **YTDownloader** project (blue icon, top left) › target **YTDownloader** › tab **Signing & Capabilities**:
   - **Team:** choose your Apple ID (*Add an Account…* if it's not listed).
   - **Bundle Identifier:** change `com.example.ytdownloader` to something unique, e.g. `com.yourname.ytdownloader`.
4. Connect the iPhone with a cable and select it in the device menu at the top of Xcode.
5. On the iPhone: *Settings › Privacy & Security › Developer Mode* › On (the phone restarts).
6. Press **▶ Run** in Xcode. The first time, on the iPhone go to *Settings › General › VPN & Device Management* and trust your developer certificate.

With a free Apple ID the app works for 7 days. After that, connect the phone and press Run again. A paid Apple Developer account ($99/year) extends this to a year.

### Automatic build check
Each push runs `.github/workflows/ios-build.yml` on a GitHub macOS machine, which compiles the app to confirm the code builds.

## Known limitations
- **Keep the app open while downloading.** iOS stops ordinary apps from working in the background after about 30 seconds. Downloads that were interrupted resume automatically when you reopen the app.
- **Videos it can't download:** age-restricted, members-only, private and live videos. This is still true after signing in.
- **No App Store release.** Apple doesn't allow YouTube downloaders in the App Store, so this app is for personal installation through Xcode only.

## Legal note
YouTube's Terms of Service don't allow downloading except where YouTube offers a download button or link, and many videos are copyrighted. Use this app for personal use, and only for videos you have the right to save, such as your own uploads, Creative Commons videos, or content whose owner allows it.
