#!/bin/sh
set -e

APP_PATH="$1"

if [ -z "$APP_PATH" ]; then
  echo "Usage: $0 /path/to/AppName.app" >&2
  exit 1
fi

if [ ! -d "$APP_PATH" ]; then
  echo "Missing app bundle: $APP_PATH" >&2
  exit 1
fi

APP_NAME="$(basename "$APP_PATH" .app)"
DMG_NAME="${APP_NAME}.dmg"

rm -f "${DMG_NAME}"

# Restore executable permissions (lost during artifact upload/download)
# chmod +x "dist/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"

# Check if npx is available for a nicer installer experience
if command -v npx >/dev/null 2>&1; then
  npx --yes create-dmg \
    --overwrite \
    --no-version-in-filename \
    --dmg-title "head.surf" \
    --no-code-sign \
    "$APP_PATH" \
    .
  mv "${APP_NAME}.dmg" "${DMG_NAME}"
else
  echo "Note: Install node to use create-dmg for a nicer DMG layout"
  # Fallback to basic DMG
  hdiutil create -volname "${APP_NAME}" -srcfolder "$APP_PATH" -ov -format UDZO "${DMG_NAME}"
fi
