#!/usr/bin/env bash
set -euo pipefail

# ── 参数解析 ──
# 用法: ./build.sh [--target universal|arm64|x86_64]
TARGET="${1:---target}"
TARGET_VALUE="${2:-universal}"

if [[ "${TARGET}" == "--target" ]]; then
  :
else
  echo "用法: ./build.sh [--target universal|arm64|x86_64]" >&2
  exit 1
fi

# ── 配置 ──
APP_EXEC_NAME="InputSourceLock"
APP_BUNDLE_NAME="输入法锁定"
MIN_MACOS_VERSION="12.0"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
APP_DIR="${BUILD_DIR}/${APP_BUNDLE_NAME}.app"
LEGACY_APP_DIRS=("${BUILD_DIR}/WeChatIMLock.app" "${BUILD_DIR}/微信输入法锁定.app")
MODULE_CACHE_DIR="${BUILD_DIR}/ModuleCache"
BIN_DIR="${BUILD_DIR}/bin"

rm -rf "${APP_DIR}" "${LEGACY_APP_DIRS[@]}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
mkdir -p "${APP_DIR}/Contents/Frameworks"
mkdir -p "${MODULE_CACHE_DIR}/arm64" "${MODULE_CACHE_DIR}/x86_64"
mkdir -p "${BIN_DIR}"

cp "${ROOT_DIR}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"

if [[ -f "${ROOT_DIR}/Resources/AppIcon.icns" ]]; then
  cp "${ROOT_DIR}/Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
OUT_BIN="${APP_DIR}/Contents/MacOS/${APP_EXEC_NAME}"
ARM_BIN="${BIN_DIR}/${APP_EXEC_NAME}-arm64"
X86_BIN="${BIN_DIR}/${APP_EXEC_NAME}-x86_64"
SWIFT_SOURCES=("${ROOT_DIR}"/src/*.swift)

COMMON_ARGS=(
  -O
  -sdk "${SDK_PATH}"
  -framework Cocoa
  -framework Carbon
  -framework ServiceManagement
)

# ── 编译函数 ──
build_arm64() {
  swiftc \
    "${COMMON_ARGS[@]}" \
    -module-cache-path "${MODULE_CACHE_DIR}/arm64" \
    -target "arm64-apple-macosx${MIN_MACOS_VERSION}" \
    -o "${ARM_BIN}" \
    "${SWIFT_SOURCES[@]}"
}

build_x86_64() {
  swiftc \
    "${COMMON_ARGS[@]}" \
    -module-cache-path "${MODULE_CACHE_DIR}/x86_64" \
    -target "x86_64-apple-macosx${MIN_MACOS_VERSION}" \
    -o "${X86_BIN}" \
    "${SWIFT_SOURCES[@]}"
}

# ── 根据 target 执行编译 ──
case "${TARGET_VALUE}" in
  arm64)
    build_arm64
    cp "${ARM_BIN}" "${OUT_BIN}"
    ;;
  x86_64)
    build_x86_64
    cp "${X86_BIN}" "${OUT_BIN}"
    ;;
  universal|*)
    # 并行编译
    build_arm64 &
    ARM_PID=$!

    X86_OK=true
    build_x86_64 &
    X86_PID=$!

    if ! wait "${ARM_PID}"; then
      echo "error: arm64 build failed" >&2
      exit 1
    fi

    if ! wait "${X86_PID}"; then
      echo "warn: x86_64 build failed; output arm64-only binary" >&2
      X86_OK=false
    fi

    if [[ "${X86_OK}" == true ]]; then
      lipo -create -output "${OUT_BIN}" "${ARM_BIN}" "${X86_BIN}"
    else
      cp "${ARM_BIN}" "${OUT_BIN}"
    fi
    ;;
esac

# ── 后处理：复制 Swift 运行时 ──
if STD_TOOL="$(xcrun --find swift-stdlib-tool 2>/dev/null)"; then
  "${STD_TOOL}" \
    --copy \
    --scan-executable "${OUT_BIN}" \
    --destination "${APP_DIR}/Contents/Frameworks" \
    --platform macosx \
    --strip-bitcode >/dev/null 2>&1 || true
fi

# ── 签名：先签 Frameworks，再签主二进制 ──
if command -v codesign >/dev/null 2>&1; then
  # 签名 Frameworks 下的每个 dylib
  if [[ -d "${APP_DIR}/Contents/Frameworks" ]]; then
    find "${APP_DIR}/Contents/Frameworks" -name "*.dylib" -o -name "*.framework" | while read -r lib; do
      codesign --force --sign - "${lib}" >/dev/null 2>&1 || true
    done
  fi
  # 签名主 app bundle
  codesign --force --sign - "${APP_DIR}" >/dev/null 2>&1 || true
fi

echo "Built: ${APP_DIR} (${TARGET_VALUE})"
