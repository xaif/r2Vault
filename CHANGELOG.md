# Changelog

All notable changes to R2 Vault are documented here.

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
