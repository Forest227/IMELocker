#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
APP_NAME="输入法锁定"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${ROOT_DIR}/Resources/Info.plist")}"
DMG_PATH="${BUILD_DIR}/IMELocker-v${VERSION}.dmg"
STAGING_DIR="${BUILD_DIR}/dmg-root"
VOLUME_NAME="输入法锁定"

"${ROOT_DIR}/build.sh"

rm -rf "${STAGING_DIR}" "${DMG_PATH}"
mkdir -p "${STAGING_DIR}"

cp -R "${APP_PATH}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

hdiutil create \
  -volname "${VOLUME_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "${DMG_PATH}" >/dev/null

rm -rf "${STAGING_DIR}"

echo "Built: ${DMG_PATH}"
