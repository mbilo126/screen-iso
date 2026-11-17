#!/usr/bin/env bash
# Builds Saver/build/ScreenISOSaver.saver with clang only (no Xcode) and signs it ad-hoc.
set -euo pipefail

SAVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SAVER_DIR}/build"
BUNDLE="${BUILD_DIR}/ScreenISOSaver.saver"
EXECUTABLE_NAME="ScreenISOSaver"
MIN_MACOS="14.0"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --find clang)"

COMMON_FLAGS=(
    -isysroot "${SDK_PATH}"
    -mmacosx-version-min="${MIN_MACOS}"
    -fobjc-arc
    -O2
    -Wall -Wextra -Werror
)

probe_arch() {
    local arch="$1"
    local probe_dir status=0
    probe_dir="$(mktemp -d)"
    printf '#import <ScreenSaver/ScreenSaver.h>\n@interface P : ScreenSaverView\n@end\n@implementation P\n@end\n' \
        > "${probe_dir}/probe.m"
    "${CLANG}" "${COMMON_FLAGS[@]}" -arch "${arch}" -bundle \
        -framework ScreenSaver -framework AppKit \
        -o "${probe_dir}/probe" "${probe_dir}/probe.m" >/dev/null 2>&1 || status=$?
    rm -rf "${probe_dir}"
    return "${status}"
}

ARCH_FLAGS=(-arch arm64)
ARCHS="arm64"
if probe_arch x86_64; then
    ARCH_FLAGS+=(-arch x86_64)
    ARCHS="arm64 x86_64"
else
    echo "warning: x86_64 not supported by this toolchain, building arm64 only" >&2
fi

rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"

"${CLANG}" "${COMMON_FLAGS[@]}" "${ARCH_FLAGS[@]}" \
    -bundle \
    -framework ScreenSaver -framework AppKit -framework QuartzCore -framework Foundation \
    -o "${BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}" \
    "${SAVER_DIR}/ScreenISOSaverView.m" \
    "${SAVER_DIR}/ScreenISOTruchetField.m"

cp "${SAVER_DIR}/Info.plist" "${BUNDLE}/Contents/Info.plist"
plutil -lint "${BUNDLE}/Contents/Info.plist" >/dev/null
printf 'BNDL????' > "${BUNDLE}/Contents/PkgInfo"

codesign --force --sign - --timestamp=none "${BUNDLE}"
codesign --verify --strict "${BUNDLE}"

echo "built ${BUNDLE} (${ARCHS})"
