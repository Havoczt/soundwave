# SoundWave 🌊

SoundWave is a modern, high-performance Android music player and downloader built with Flutter. It offers a Spotify-inspired dark aesthetic, high-fidelity audio playback, and a robust metadata enrichment engine with time-synced lyrics and dynamic theming.

## ✨ Features

### 🎧 Premium Playback Experience
*   **High-Fidelity Engine**: Powered by `just_audio` with support for `.mp3`, `.m4a`, `.aac`, `.wav`, `.ogg`, `.opus`, `.flac`, and `.webm`.
*   **Background Playback**: Full support for Android Media Services with lock screen controls and system notifications.
*   **Dynamic Theming**: Extracts the dominant color palette from your album art to create beautiful, blurred gradients in the "Now Playing" screen (Material You style).
*   **Playback Control**: Precise seek bar, shuffle, repeat modes (Off, All, One), and adjustable playback speed (0.5x to 2.0x).
*   **Sleep Timer**: Fall asleep to your music with integrated timers (5–60 minutes).

### 🔍 Search & Download
*   **YouTube Integration**: Search and download high-quality audio directly from YouTube within the app.
*   **Reliable Download Pipeline**:
    1.  **Primary**: Self-hosted `yt-dlp` backend for maximum reliability and server-side audio normalization.
    2.  **Fallback**: High-speed public Invidious instances.
    3.  **Local Fallback**: Direct stream extraction via `youtube_explode_dart`.
*   **Smart Metadata Cleaning**: Automatically strips download noise (e.g., "Official Video", "y2mate") and intelligently splits titles into Artist/Song names.

### 📜 Synced Lyrics
*   **Real-Time Sync**: View time-synced `.lrc` lyrics that scroll automatically with your music.
*   **Rich Integration**: Leverages **LRCLib** for high-quality synced lyrics and **Lyrics.ovh** as a plain-text fallback.
*   **Interactive Sheet**: Tap to see full lyrics; highlighting and smooth scrolling keep you in the flow.

### 📚 Library Management
*   **Metadata Enrichment**: Automatically fetches missing album art and artist info from iTunes, Last.fm, and MusicBrainz.
*   **Folder Scanning**: Easily import your existing music collection by scanning specific folders (e.g., Music, Downloads).
*   **Playlists & Favorites**: Create custom playlists and maintain a "Liked Songs" library.
*   **Recents**: Quick access to your top 10 recently played tracks.
*   **Tag Editor**: Manually fix metadata directly in-app to trigger fresh art and lyrics lookups.

## 🛠 Setup & Installation

### 📥 Download the APK
You can download the latest release of SoundWave directly from the [GitHub Releases](https://github.com/Havoczt/soundwave/releases) page.

### 🏗️ Building from Source
If you want to build the project yourself, follow these steps:

1.  **Prerequisites**:
    *   Flutter SDK (v3.24.5+)
    *   Android SDK & Java 17
2.  **Clone the Repository**:
    ```bash
    git clone https://github.com/Havoczt/soundwave.git
    cd soundwave
    ```
3.  **Prepare the Project**:
    SoundWave uses a single-file architecture for its core logic. To build, create a standard Flutter project and move `main.dart` into it:
    ```bash
    flutter create --org com.soundwave --project-name soundwave --platforms android app
    cp main.dart app/lib/main.dart
    cd app
    ```
4.  **Add Dependencies**:
    ```bash
    flutter pub add just_audio just_audio_background file_picker path_provider path \
      shared_preferences audio_metadata_reader permission_handler http open_filex \
      youtube_explode_dart:2.5.3 palette_generator
    ```
5.  **Build**:
    ```bash
    flutter build apk --release
    ```

### ⚙️ Build-Time Configuration
SoundWave supports optional environment variables for enhanced functionality:
*   `YT_API_BASE`: Base URL for a self-hosted `yt-dlp` REST API.
*   `YT_API_KEY`: API key for the backend service.

In CI/CD (GitHub Actions), these are passed via `dart_defines.json`.

## 🏗️ Architecture & Stack
*   **Framework**: Flutter (Material 3)
*   **State Management**: `ChangeNotifier` / `ListenableBuilder`
*   **Audio Engine**: `just_audio`
*   **Metadata**: `audio_metadata_reader`
*   **Network**: `http`
*   **Storage**: `shared_preferences` (for library state) and `path_provider` (for local files)

## 🤝 Acknowledgments
*   Lyrics provided by [LRCLib](https://lrclib.net/) and [Lyrics.ovh](https://lyrics.ovh/).
*   Metadata and Art from iTunes Search API, [Last.fm](https://www.last.fm/), and [MusicBrainz](https://musicbrainz.org/).
*   YouTube search powered by [youtube_explode_dart](https://github.com/Hexer10/youtube_explode_dart).

---
Co-Authored-By: Claude Code <noreply@anthropic.com>
🤖 Generated with [Claude Code](https://claude.com/claude-code)
