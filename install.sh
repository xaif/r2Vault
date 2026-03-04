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
DMG_URL=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.dmg"' \
  | head -1 \
  | cut -d'"' -f4)

if [ -z "$DMG_URL" ]; then
  echo "  Error: Could not find DMG in latest release."
  exit 1
fi

VERSION=$(echo "$DMG_URL" | grep -o 'v[0-9]*\.[0-9]*\.[0-9]*' | head -1)
echo "  Found: ${VERSION:-latest}"

# Download DMG
TMPDIR_PATH=$(mktemp -d)
DMG_PATH="${TMPDIR_PATH}/r2Vault.dmg"

echo "  Downloading..."
curl -fsSL -o "$DMG_PATH" "$DMG_URL"

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

# Remove old version if exists
if [ -d "${INSTALL_DIR}/${APP_NAME}.app" ]; then
  echo "  Removing previous version..."
  rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
fi

# Copy to Applications
cp -R "$APP_PATH" "${INSTALL_DIR}/"

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
