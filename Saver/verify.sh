#!/usr/bin/env bash
# Builds the saver, runs the offscreen harness (PNGs in Saver/build/renders) and renders
# Saver/build/preview.mp4 (skip with --no-video, it takes minutes). With --soak it also
# measures CPU in an on-screen window for 30 s.
# Never installs the saver and never starts ScreenSaverEngine.
set -euo pipefail

SAVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SAVER_DIR}/build"
BUNDLE="${BUILD_DIR}/ScreenISOSaver.saver"
HARNESS="${BUILD_DIR}/saver-harness"
RENDER_DIR="${BUILD_DIR}/renders"
VIDEO="${BUILD_DIR}/preview.mp4"
SOAK=0
VIDEO_ENABLED=1
for arg in "$@"; do
    case "${arg}" in
        --soak) SOAK=1 ;;
        --no-video) VIDEO_ENABLED=0 ;;
        *) echo "unknown option: ${arg}" >&2; exit 2 ;;
    esac
done

"${SAVER_DIR}/build.sh"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
"$(xcrun --find clang)" \
    -isysroot "${SDK_PATH}" -mmacosx-version-min=14.0 \
    -fobjc-arc -O1 -Wall -Wextra -Werror -Wno-arc-performSelector-leaks \
    -framework AppKit -framework QuartzCore \
    -o "${HARNESS}" "${SAVER_DIR}/Harness/main.m"

rm -rf "${RENDER_DIR}"
mkdir -p "${RENDER_DIR}"
"${HARNESS}" check "${BUNDLE}" "${RENDER_DIR}"

FFMPEG="$(command -v ffmpeg || true)"
[[ -z "${FFMPEG}" && -x /opt/homebrew/bin/ffmpeg ]] && FFMPEG=/opt/homebrew/bin/ffmpeg
if [[ "${VIDEO_ENABLED}" == 0 ]]; then
    echo "preview video skipped (--no-video)"
elif [[ -n "${FFMPEG}" ]]; then
    rm -f "${VIDEO}"
    "${HARNESS}" video "${BUNDLE}" 15 30 \
        | "${FFMPEG}" -v error -y -f rawvideo -pix_fmt rgba -s 1512x982 -r 30 -i - \
            -c:v libx264 -pix_fmt yuv420p -crf 18 -preset medium -movflags +faststart "${VIDEO}"
    echo "preview video: ${VIDEO}"
else
    echo "warning: ffmpeg not found, skipping ${VIDEO}" >&2
fi

if [[ "${SOAK}" == 1 ]]; then
    "${HARNESS}" soak "${BUNDLE}" 30
fi

file "${BUNDLE}/Contents/MacOS/ScreenISOSaver"
lipo -archs "${BUNDLE}/Contents/MacOS/ScreenISOSaver"
codesign --verify --strict --verbose=2 "${BUNDLE}"
