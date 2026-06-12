#!/usr/bin/env bash
set -euo pipefail

# 用法: ./scripts/build_dmg.sh [VERSION] [TARGET]
# VERSION: 版本号，默认从 Info.plist 读取
# TARGET: universal|arm64|x86_64，默认 universal

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
APP_NAME="输入法锁定"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${ROOT_DIR}/Resources/Info.plist")}"
TARGET="${2:-universal}"

# 构建 app
bash "${ROOT_DIR}/build.sh" --target "${TARGET}"

# DMG 文件名包含架构标识
if [[ "${TARGET}" == "universal" ]]; then
  DMG_SUFFIX="universal"
else
  DMG_SUFFIX="${TARGET}"
fi
DMG_PATH="${BUILD_DIR}/IMELocker-v${VERSION}-${DMG_SUFFIX}.dmg"
STAGING_DIR="${BUILD_DIR}/dmg-root"
VOLUME_NAME="输入法锁定"

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
