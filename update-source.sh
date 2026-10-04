#!/bin/bash
# update-source.sh — Updates altstore-source.json with a new app version
#
# Usage:
#   ./update-source.sh <version> <ipa_path> [changelog]
#
# Example:
#   ./update-source.sh 1.1 ./build/r2Vault.ipa "Bug fixes and improvements"
#   ./update-source.sh 2.0 ./build/r2Vault.ipa

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_FILE="$SCRIPT_DIR/altstore-source.json"

if [ $# -lt 2 ]; then
    echo "Usage: $0 <version> <ipa_path> [changelog]"
    echo "  version   - e.g. 1.1, 2.0"
    echo "  ipa_path  - path to the .ipa file"
    echo "  changelog - (optional) release notes for this version"
    exit 1
fi

VERSION="$1"
IPA_PATH="$2"
CHANGELOG="${3:-Release $VERSION}"
DATE=$(date +%Y-%m-%d)

if [ ! -f "$IPA_PATH" ]; then
    echo "Error: IPA file not found at $IPA_PATH"
    exit 1
fi

if [ ! -f "$SOURCE_FILE" ]; then
    echo "Error: altstore-source.json not found at $SOURCE_FILE"
    exit 1
fi

# Get file size in bytes
IPA_SIZE=$(stat -f%z "$IPA_PATH" 2>/dev/null || stat --printf="%s" "$IPA_PATH" 2>/dev/null)

# Oldest iOS the app runs on, from the app's Info.plist (so AltStore doesn't offer it to older devices)
APP_PLIST=$(unzip -Z1 "$IPA_PATH" | grep -E '^Payload/[^/]+\.app/Info\.plist$' | head -1)
MIN_OS=$(unzip -p "$IPA_PATH" "$APP_PLIST" | plutil -extract MinimumOSVersion raw -o - - 2>/dev/null || echo "16.0")

echo "Updating altstore-source.json..."
echo "  Version:   $VERSION"
echo "  IPA Size:  $IPA_SIZE bytes"
echo "  Min iOS:   $MIN_OS"
echo "  Date:      $DATE"
echo "  Changelog: $CHANGELOG"

# Check if python3 is available (needed for JSON manipulation)
if ! command -v python3 &>/dev/null; then
    echo "Error: python3 is required but not found"
    exit 1
fi

python3 << PYEOF
import json
import sys

source_file = "$SOURCE_FILE"
version = "$VERSION"
ipa_size = $IPA_SIZE
date = "$DATE"
changelog = """$CHANGELOG"""

with open(source_file, "r") as f:
    source = json.load(f)

# Build the new version entry
new_version = {
    "version": version,
    "date": date,
    "localizedDescription": changelog,
    "downloadURL": f"https://github.com/xaif/r2Vault/releases/download/v{version}/R2Vault.ipa",
    "size": ipa_size,
    "minOSVersion": "$MIN_OS"
}

# Prepend the new version to the versions array (newest first)
app = source["apps"][0]
existing_versions = [v["version"] for v in app["versions"]]

if version in existing_versions:
    # Update existing version entry
    for i, v in enumerate(app["versions"]):
        if v["version"] == version:
            app["versions"][i] = new_version
            print(f"  Updated existing version {version}")
            break
else:
    # Insert new version at the beginning
    app["versions"].insert(0, new_version)
    print(f"  Added new version {version}")

# Add a news entry for this release
news_id = f"r2vault-v{version.replace('.', '-')}"
existing_news_ids = [n["identifier"] for n in source.get("news", [])]

if news_id not in existing_news_ids:
    news_entry = {
        "title": f"r2Vault v{version} Released",
        "identifier": news_id,
        "caption": changelog,
        "date": date,
        "tintColor": "007AFF",
        "notify": True,
        "appID": "fiaxe.r2Vault"
    }
    source.setdefault("news", []).insert(0, news_entry)
    print(f"  Added news entry: {news_id}")

with open(source_file, "w") as f:
    json.dump(source, f, indent=2)
    f.write("\n")

print("Done! altstore-source.json updated.")
PYEOF
