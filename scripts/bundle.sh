#!/usr/bin/env bash
# Builds build/ScreenISO.app: release binary, Info.plist, the icon, the screen saver from Saver/build.sh,
# ad-hoc signature.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${ROOT}/build/ScreenISO.app"
CONTENTS="${APP}/Contents"
SAVER_NAME="ScreenISOSaver.saver"
SAVER_SOURCE="${ROOT}/Saver/build/${SAVER_NAME}"
ICON_SOURCE="${ROOT}/Resources/AppIcon.icns"

fail() {
    echo "error: $*" >&2
    exit 1
}

step() {
    echo "==> $*"
}

cd "${ROOT}"

step "swift build -c release"
swift build -c release --product ScreenISO
BIN_DIR="$(swift build -c release --show-bin-path)"
BINARY="${BIN_DIR}/ScreenISO"
[[ -x "${BINARY}" ]] || fail "release binary not found at ${BINARY}"

step "Saver/build.sh"
"${ROOT}/Saver/build.sh" || fail "Saver/build.sh failed"
[[ -d "${SAVER_SOURCE}" ]] || fail "screen saver bundle not found at ${SAVER_SOURCE}"

step "assemble ${APP}"
rm -rf "${APP}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"
cp "${BINARY}" "${CONTENTS}/MacOS/ScreenISO"
cp "${ROOT}/Resources/Info.plist" "${CONTENTS}/Info.plist"
plutil -lint "${CONTENTS}/Info.plist" >/dev/null || fail "invalid Info.plist"
printf 'APPL????' > "${CONTENTS}/PkgInfo"
[[ -f "${ICON_SOURCE}" ]] || fail "icon not found at ${ICON_SOURCE}: run make icon"
cp "${ICON_SOURCE}" "${CONTENTS}/Resources/AppIcon.icns"
ditto "${SAVER_SOURCE}" "${CONTENTS}/Resources/${SAVER_NAME}"

step "codesign (ad-hoc): nested saver first, then the app"
codesign --force --sign - --timestamp=none "${CONTENTS}/Resources/${SAVER_NAME}"
codesign --force --sign - --timestamp=none --identifier it.yellowtech.screeniso "${APP}"
codesign --verify --deep --strict "${APP}" || fail "codesign verification failed"

echo "built ${APP}"
