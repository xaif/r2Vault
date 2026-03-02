<p align="center">
  <img src="Fiaxe/Assets.xcassets/AppIcon.appiconset/image%20(1).png" width="128" height="128" alt="r2Vault Icon" />
</p>

<h1 align="center">r2Vault</h1>

<p align="center">
  A native macOS client for browsing, managing, and uploading files to Cloudflare R2.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS-blue" />
  <img src="https://img.shields.io/badge/swift-5.9+-orange" />
  <img src="https://img.shields.io/badge/UI-SwiftUI-purple" />
</p>

---

## Features

**Browse & Navigate**
- Finder-style file browser with breadcrumb navigation
- Icon and List view modes
- Search, sort, and filter files by name, size, date, or kind
- Quick Look preview with spacebar

**Upload**
- Drag-and-drop files and folders directly from Finder
- Concurrent uploads with real-time progress tracking
- Automatic URL copy to clipboard on success
- Upload history with clickable links

**Manage**
- Create and delete folders
- Batch delete with confirmation
- Multiple R2 bucket support with saved credentials
- Presigned URL generation for secure sharing

## Screenshot

<p align="center">
  <img src="assets/screenshot.png" width="800" alt="r2Vault — Browse your R2 bucket" />
</p>

## Getting Started

### Prerequisites

- macOS 15.0+
- Xcode 16+
- A [Cloudflare R2](https://developers.cloudflare.com/r2/) bucket with API credentials

### Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/xaif/r2Vault.git
   cd r2Vault
   ```

2. Open the project in Xcode:
   ```bash
   open Fiaxe.xcodeproj
   ```

3. Build and run (⌘R)

### Configuration

1. Launch the app and open **Settings** (⌘,)
2. Add your R2 credentials:
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
| Storage | UserDefaults, FileManager |

## Project Structure

```
Fiaxe/
├── Models/
│   ├── R2Credentials.swift     # Bucket credential model
│   ├── R2Object.swift          # File/folder object model
│   ├── UploadItem.swift        # Upload item representation
│   └── UploadTask.swift        # Upload task with progress
├── Services/
│   ├── AWSV4Signer.swift       # S3-compatible request signing
│   ├── KeychainService.swift   # Credential persistence
│   ├── R2BrowseService.swift   # Bucket listing & management
│   ├── R2UploadService.swift   # File upload with progress
│   ├── ThumbnailCache.swift    # Memory + disk thumbnail cache
│   ├── UploadHistoryStore.swift# Upload history persistence
│   └── QuickLookCoordinator.swift
├── ViewModels/
│   └── AppViewModel.swift      # Central app state
└── Views/
    ├── BrowserView.swift       # Main file browser
    ├── SettingsView.swift      # Credentials & preferences
    ├── UploadQueueView.swift   # Active uploads
    ├── UploadHistoryView.swift # Past uploads
    └── ...
```

## License

This project is open source and available under the [MIT License](LICENSE).
