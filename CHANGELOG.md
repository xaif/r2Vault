# Changelog

All notable changes to R2 Vault are documented here.

## [v1.2.10] - 2026-03-07

### Fixed
- Restored the intended iOS dashboard appearance after recent macOS-only dashboard styling changes leaked onto iPhone
- Kept the refreshed macOS dashboard styling while bringing iOS cards, grouped surfaces, and background treatment back to the proper mobile design

## [v1.2.9] - 2026-03-07

### Added
- iPhone Live Activity upload experience with a cleaner, more compact status design and better visual hierarchy
- In-preview file actions for iPhone and macOS, including download, copy URL, and delete
- Faster media/document preview paths with streamed video playback, dedicated PDF viewing, and improved image preview handling

### Changed
- iOS now opens on Files by default, while keeping Dashboard available in the main tab layout
- Search behavior now works recursively within the current folder subtree instead of only the current visible level
- Dashboard visuals were refreshed across iOS and macOS with stronger card styling, responsive layouts, and cleaner analytics sections
- Upload Insights summary cards now match the primary dashboard stat-card treatment

### Fixed
- iOS downloads no longer cancel just because the app is backgrounded or minimized
- Folder navigation races, stale-folder flashes, and repeated loading states during browser navigation
- Dashboard timeline, alignment, and bucket-scoped upload insight issues
- Preview issues for images and PDFs, including incorrect initial image zoom and broken preview actions
- macOS dashboard spacing and section composition for file analytics cards
- Removed an unused local during bucket scan to keep the release build warning-free

## [v1.2.8] - 2026-03-06

### Added
- Refreshed macOS upload experience with a richer floating upload HUD, redesigned upload rows, and a stronger empty upload state
- Improved visual depth for the macOS upload panel with layered material, tinting, and clearer separation between the surface and its contents

### Changed
- macOS upload UI now more closely matches the polished iOS upload design language for progress, status, and actions

### Fixed
- Restored missing macOS browser navigation helper wrappers so the project builds cleanly after the upload UI refresh

## [v1.2.7] - 2026-03-05

### Fixed
- File picker and drag/drop selection updates now run on the main actor so selected files appear reliably in the upload queue/HUD
- macOS list view now shows a clear selection state with an explicit checkmark indicator and stronger row highlight

## [v1.2.6] - 2026-03-05

### Fixed
- Crash on launch on macOS 15.6 caused by creating NSStatusItem before window server connection is established

## [v1.2.5] - 2026-03-04

### Added
- One-line install script (`curl | bash`) for frictionless installation
- Homebrew Cask formula for `brew install --cask` support
- Ad-hoc code signing in CI builds
- Comprehensive installation instructions in README with multiple methods
- Every GitHub Release now includes install instructions for all methods

### Changed
- README rewritten with clear installation guide (right-click Open, terminal, System Settings)
- Release notes template updated with one-liner, Homebrew, and manual install options

## [v1.2.4] - 2026-03-04

### Added
- Recent Uploads in the menu bar now filters by the currently selected bucket
- Menu bar popover redesigned: compact rows, smaller fonts, fixed-width hover action area that doesn't shift layout
- Drop zone enlarged and simplified
- Menu bar settings button updated to gear icon
- Menu bar icon changed to `square.and.arrow.up`

### Changed
- Hover actions on recent upload rows now fade in/out in a reserved fixed-width slot — no layout jumping
- Delete animation on recent upload rows now slides and fades smoothly

## [v1.2.3] - 2026-03-04

### Added
- Menu bar icon now appears immediately on launch without needing to open the main window first
- About R2 Vault and Check for Updates moved to the system app menu (R2Vault menu bar)
- Gear menu in popover streamlined to bucket switcher and Quit only
- Main window can be reopened from the popover even after being closed

### Fixed
- Orange accent color now applied correctly regardless of system accent color setting
- Badge colors in Recent Uploads list no longer desaturate when clicking inside the popover
- Open R2 Vault button now reliably opens the main window even when it has been closed

## [v1.2.2] - 2026-03-04

### Added
- App now runs exclusively in the menu bar — no Dock icon, no app switcher presence
- Closing the main window no longer quits the app; it continues running in the background
- Quit R2 Vault option added to the gear menu in the menu bar popover
- Liquid Glass effects applied to drop zone, file type badges, action buttons, and toast notifications
- Menu bar popover now adapts to system light/dark mode automatically
- Delete confirmation dialog before removing files from the menu bar recent uploads list

## [v1.2.1] - 2026-03-03

### Fixed
- Delete from context menu now shows a confirmation dialog before removing any file or folder
- Folder delete confirmation warns that all contents will be permanently removed

## [v1.2.0] - 2026-03-03

### Added
- Menu bar widget — upload files by dropping them directly onto the menu bar icon
- Live upload progress in the menu bar popover with per-file progress bars and cancel buttons
- Recent uploads list in the menu bar (25 most recent, newest first) with copy link, download, and delete actions
- Auto-copy public URL to clipboard after every upload, with a "Link copied!" toast notification
- Bucket switcher moved into the gear settings menu — cleaner header, less clutter

## [v1.1.6] - 2026-03-03

### Added
- Cancel button on each upload row in the HUD — tap ✕ to cancel any pending or in-progress upload
- Cancelled uploads show a "Cancelled" status instead of an error

## [v1.1.5] - 2025-03-03

### Added
- Recursive folder deletion — deleting a folder now removes all its contents automatically, no need to delete files first

## [v1.1.4] - 2025-03-03

### Fixed
- File upload via "Upload Files…" button now works correctly (files picked from the file picker were silently failing due to a sandbox permission issue)
- Moved file/folder importer to the correct view context so the picker opens reliably

## [v1.1.3] - 2025-03-03

### Fixed
- File selection now works correctly in both icon and list views (single-tap to select)
- Selected items are cleared when navigating into a different folder
- Fixed list view always showing items as unselected regardless of actual selection state

## [v1.1.2] - 2025-03-02

### Fixed
- Fixed update install loop — app no longer reinstalls itself on every launch after an update

## [v1.1.1] - 2025-03-02

### Fixed
- Browser now auto-refreshes after a successful file upload — no need to manually refresh
- Fixed update check showing sheet on every launch even when already up to date

## [v1.1.0] - 2025-03-01

### Added
- Check for Updates via the app menu (R2 Vault → Check for Updates)
- Automatic in-app update download and install
- GitHub Actions CI/CD — releases are built and published automatically on tag push

### Changed
- Rewrote update system using `@Observable` — cleaner, no callback race conditions

---

## Installation Note

Since R2 Vault is not notarized with Apple, macOS may show a "damaged" warning when opening a downloaded build. Run this in Terminal after copying the app to Applications:

```
xattr -dr com.apple.quarantine /Applications/R2Vault.app
```
