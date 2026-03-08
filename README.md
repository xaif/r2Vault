<p align="center">
  <img src="Fiaxe/Assets.xcassets/AppIcon.appiconset/image%20(1).png" width="128" height="128" alt="r2Vault Icon" />
</p>

<h1 align="center">r2Vault</h1>

<p align="center">
  A native Apple client for browsing, managing, and uploading files to Cloudflare R2.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%20%2B%20iOS-blue" />
  <img src="https://img.shields.io/badge/swift-6-orange" />
  <img src="https://img.shields.io/badge/UI-SwiftUI-purple" />
  <img src="https://img.shields.io/github/v/release/xaif/r2Vault?label=latest" />
</p>

---

## Features

**Browse & Navigate**
- Finder-style file browser with breadcrumb navigation
- Icon and List view modes
- Search, sort, and filter files by name, size, date, or kind
- Quick Look preview with spacebar
- Native dashboard views for macOS and iPhone with bucket analytics, upload insights, and file type breakdowns

**Upload**
- Drag-and-drop files and folders directly from Finder
- Concurrent uploads with real-time progress tracking
- Cancel individual uploads or all at once
- Automatic public URL copy to clipboard on upload completion
- Upload history with copy, download, local removal, and delete actions tied to the correct bucket credentials

**Menu Bar Widget**
- Lives in the macOS menu bar — always one click away
- Drop files directly onto the popover to upload instantly
- Live per-file upload progress with cancel buttons
- Recent uploads list with copy link, download, and delete
- Stays open while you work — won't dismiss on focus loss

**Manage**
- Create folders and delete files/folders with confirmation dialogs
- Recursive folder deletion — removes all contents in one action
- Batch delete multiple items with a single confirmation
- Multiple R2 bucket support — switch buckets from the gear menu
- Presigned URL generation for secure sharing
- Per-bucket history/download resolution so switching buckets does not break history actions

**Auto-Update**
- Check for Updates via the app menu (R2 Vault → Check for Updates)
- Automatic in-app download and install of new releases
- Downloaded DMGs are verified against published SHA-256 checksums before install

**Security & Reliability**
- R2 credentials are stored in the system Keychain
- Installer and updater verify release checksums before replacing the app
- Safer staged app replacement avoids delete-first update failures
- Share/import handling avoids simple filename collisions and large in-memory fallbacks
- Custom domain input is normalized to clean `https` URLs before use

## What's New in v1.2.11

- Hardened release installs with published DMG checksum assets and checksum verification in both the installer and in-app updater
- Refined the macOS dashboard so it uses a more native glass/material appearance instead of washing out into a white screen
- Fixed multi-bucket history actions so downloads and deletes continue using the correct credentials after bucket switches
- Improved dashboard refresh correctness, nested folder counting, batch delete reporting, and safer download/share handling

## Screenshot

<p align="center">
  <img src="assets/screenshot.png" width="800" alt="r2Vault — Browse your R2 bucket" />
</p>

## Installation

### Homebrew (Recommended)

```bash
brew install --cask xaif/tap/r2vault
```

### Manual Download

1. Download the latest DMG from [Releases](https://github.com/xaif/r2Vault/releases/latest)
2. Open the DMG and drag **R2Vault** to **Applications**
3. If macOS warns because the app is not notarized, do **one** of the following:

   **Option A — Right-click to Open (easiest):**
   - Right-click (or Control-click) on R2Vault in Applications
   - Select **Open** from the context menu
   - Click **Open** in the dialog that appears
   - You only need to do this once — after that it opens normally

   **Option B — System Settings:**
   - Try to open the app normally (it will be blocked)
   - Go to **System Settings → Privacy & Security**
   - Scroll down and click **Open Anyway** next to the R2Vault message

> **Why is this needed?** r2Vault is free and open source. Apple charges $99/year for app notarization, so macOS treats it as "unidentified". The app is safe — you can [review the source code](https://github.com/xaif/r2Vault) yourself.

### Terminal Installer

If you prefer an automated install, the bundled installer downloads the latest release and verifies its published checksum before installing it:

```bash
curl -fsSL https://raw.githubusercontent.com/xaif/r2Vault/main/install.sh | bash
```

### Build from Source

```bash
git clone https://github.com/xaif/r2Vault.git
cd r2Vault
open Fiaxe.xcodeproj
```

Build and run with ⌘R. Requires modern Xcode and current Apple platform SDKs.

## Getting Started

1. Launch r2Vault — it lives in your **menu bar**
2. Open **Settings** (⌘,) and add your R2 credentials:
   - **Account ID** — found in your Cloudflare dashboard
   - **Access Key ID** & **Secret Access Key** — from an R2 API token
   - **Bucket Name**
   - **Custom Domain** (optional) — for public URL generation

## Tech Stack

| Layer | Technology |
|-------|-----------|
| UI | SwiftUI |
| Architecture | MVVM with `@Observable` |
| Concurrency | Swift async/await, TaskGroup |
| Auth | AWS Signature V4 (CryptoKit) |
| Networking | URLSession |
| Storage | Keychain, UserDefaults |
| Menu Bar | AppKit `NSStatusItem` + `NSPopover` |

## Project Structure

```
Fiaxe/
├── Models/
│   ├── R2Credentials.swift       # Bucket credential model
│   ├── R2Object.swift            # File/folder object model
│   ├── UploadItem.swift          # Upload history item
│   └── UploadTask.swift          # Upload task with progress + cancellation
├── Services/
│   ├── AWSV4Signer.swift         # S3-compatible request signing
│   ├── KeychainService.swift     # Secure credential persistence
│   ├── MenuBarManager.swift      # NSStatusItem + NSPopover management
│   ├── R2BrowseService.swift     # Bucket listing, delete, recursive ops
│   ├── R2UploadService.swift     # File upload with progress streaming
│   ├── ThumbnailCache.swift      # Memory + disk thumbnail cache
│   ├── UpdateService.swift       # GitHub release update checker
│   ├── AppUpdater.swift          # Verified in-app updater for macOS releases
│   ├── UploadHistoryStore.swift  # Upload history persistence
│   └── QuickLookCoordinator.swift
├── ViewModels/
│   └── AppViewModel.swift        # Central app state
└── Views/
    ├── BrowserView.swift         # Main file browser
    ├── MenuBarView.swift         # Menu bar popover UI
    ├── SettingsView.swift        # Credentials & preferences
    ├── UploadQueueView.swift     # Active uploads HUD
    ├── UploadHistoryView.swift   # Past uploads
    └── ...
```

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for the full release history.

## License

This project is open source and available under the [MIT License](LICENSE).
