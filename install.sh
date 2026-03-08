#!/bin/bash
# r2Vault Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/xaif/r2Vault/main/install.sh | bash

set -euo pipefail

APP_NAME="R2Vault"
REPO="xaif/r2Vault"
INSTALL_DIR="/Applications"

echo ""
echo "  r2Vault Installer"
echo "  ────────────────────"
echo ""

# Get latest release DMG URL
echo "  Fetching latest release..."
RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest")

DMG_URL=$(printf '%s' "$RELEASE_JSON" \
  | grep -o '"browser_download_url": *"[^"]*\.dmg"' \
  | head -1 \
  | cut -d'"' -f4)

SHA256_URL=$(printf '%s' "$RELEASE_JSON" \
  | grep -o '"browser_download_url": *"[^"]*\.dmg\.sha256"' \
  | head -1 \
  | cut -d'"' -f4)

if [ -z "$DMG_URL" ]; then
  echo "  Error: Could not find DMG in latest release."
  exit 1
fi

if [ -z "$SHA256_URL" ]; then
  echo "  Error: Could not find checksum file in latest release."
  exit 1
fi

VERSION=$(echo "$DMG_URL" | grep -o 'v[0-9]*\.[0-9]*\.[0-9]*' | head -1)
echo "  Found: ${VERSION:-latest}"

# Download DMG
TMPDIR_PATH=$(mktemp -d)
DMG_PATH="${TMPDIR_PATH}/r2Vault.dmg"
SHA256_PATH="${TMPDIR_PATH}/r2Vault.dmg.sha256"

echo "  Downloading..."
curl -fsSL -o "$DMG_PATH" "$DMG_URL"
curl -fsSL -o "$SHA256_PATH" "$SHA256_URL"

EXPECTED_SHA=$(awk '{print $1}' "$SHA256_PATH")
ACTUAL_SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

if [ -z "$EXPECTED_SHA" ] || [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
  echo "  Error: Downloaded DMG failed checksum verification."
  rm -rf "$TMPDIR_PATH"
  exit 1
fi

# Mount DMG
echo "  Installing..."
MOUNT_POINT=$(hdiutil attach "$DMG_PATH" -nobrowse -quiet | tail -1 | awk '{print $NF}')

# Find the .app inside the mounted DMG
APP_PATH=$(find "$MOUNT_POINT" -name "*.app" -maxdepth 1 | head -1)

if [ -z "$APP_PATH" ]; then
  echo "  Error: No .app found in DMG."
  hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
  rm -rf "$TMPDIR_PATH"
  exit 1
fi

# Stage the new app first so a failed copy does not remove the existing install.
STAGED_APP="${INSTALL_DIR}/${APP_NAME}.app.new"
BACKUP_APP="${INSTALL_DIR}/${APP_NAME}.app.backup"
DEST_APP="${INSTALL_DIR}/${APP_NAME}.app"

rm -rf "$STAGED_APP" "$BACKUP_APP"
cp -R "$APP_PATH" "$STAGED_APP"

if [ -d "$DEST_APP" ]; then
  echo "  Replacing previous version..."
  mv "$DEST_APP" "$BACKUP_APP"
fi

if ! mv "$STAGED_APP" "$DEST_APP"; then
  rm -rf "$STAGED_APP"
  if [ -d "$BACKUP_APP" ]; then
    mv "$BACKUP_APP" "$DEST_APP"
  fi
  echo "  Error: Failed to install the app."
  hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
  rm -rf "$TMPDIR_PATH"
  exit 1
fi

rm -rf "$BACKUP_APP"

# Remove quarantine attribute
xattr -dr com.apple.quarantine "${INSTALL_DIR}/${APP_NAME}.app" 2>/dev/null || true

# Cleanup
hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
rm -rf "$TMPDIR_PATH"

echo ""
echo "  r2Vault ${VERSION:-} installed to ${INSTALL_DIR}/"
echo ""
echo "  Launch it from your Applications folder or run:"
echo "    open -a ${APP_NAME}"
echo ""
