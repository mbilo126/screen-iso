#!/usr/bin/env bash
# Publishes the version in Resources/Info.plist: app zip -> GitHub Release -> cask in the Homebrew tap.
# Bump CFBundleShortVersionString first, then run `make release`.
#
# With --dry-run nothing leaves this machine: the zip and the rendered cask stay in build/ for inspection.
# If the release is already on GitHub but the tap was not updated, running it again only updates the tap.
set -euo pipefail

REPO="mbilo126/screen-iso"
TAP_REPO="mbilo126/homebrew-screeniso"
CASK_NAME="screeniso"
GH_ACCOUNT="mbilo126"
REPO_URL="https://github.com/${REPO}.git"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

fail() {
    echo "error: $*" >&2
    exit 1
}

step() {
    echo "==> $*"
}

# git would answer GitHub with the keychain credential, which can belong to another account.
git_as_account() {
    git -c credential.helper= -c credential.helper='!gh auth git-credential' "$@"
}

DRY_RUN=0
for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY_RUN=1 ;;
        *) fail "unknown option: ${arg}" ;;
    esac
done

PLIST="Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${PLIST}")"
MIN_MACOS="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "${PLIST}")"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version '${VERSION}' in ${PLIST} is not MAJOR.MINOR.PATCH"

TAG="v${VERSION}"
ZIP="build/ScreenISO-${VERSION}.zip"
CASK_TEMPLATE="packaging/homebrew/${CASK_NAME}.rb.in"
CASK_PATH="Casks/${CASK_NAME}.rb"

# The cask's minimum macOS follows the bundle's: if they drift, brew installs where the app cannot start.
case "${MIN_MACOS%%.*}" in
    14) MACOS_SYMBOL="sonoma" ;;
    15) MACOS_SYMBOL="sequoia" ;;
    26) MACOS_SYMBOL="tahoe" ;;
    *) fail "no Homebrew name known for LSMinimumSystemVersion ${MIN_MACOS}: add it to scripts/release.sh" ;;
esac

render_cask() {
    local target="$1"
    sed -e "s|@VERSION@|${VERSION}|" -e "s|@SHA256@|${SHA}|" -e "s|@MACOS@|${MACOS_SYMBOL}|" \
        "${CASK_TEMPLATE}" > "${target}"
    if grep -q '@[A-Z0-9_]*@' "${target}"; then
        fail "placeholders left in ${target}"
    fi
}

update_tap() {
    step "update ${CASK_PATH} in ${TAP_REPO}"
    local work
    work="$(mktemp -d)"
    git_as_account clone --quiet --depth 1 "https://github.com/${TAP_REPO}.git" "${work}/tap" \
        || fail "cannot clone ${TAP_REPO}: create the tap repository first"
    mkdir -p "${work}/tap/$(dirname "${CASK_PATH}")"
    render_cask "${work}/tap/${CASK_PATH}"
    git -C "${work}/tap" add "${CASK_PATH}"
    if git -C "${work}/tap" diff --cached --quiet; then
        echo "tap already at ${VERSION}"
    else
        git -C "${work}/tap" commit --quiet -m "${CASK_NAME} ${VERSION}"
        git_as_account -C "${work}/tap" push --quiet
        echo "tap updated"
    fi
    rm -rf "${work}"
}

release_notes() {
    local previous
    previous="$(git describe --tags --abbrev=0 "${TAG}^" 2>/dev/null || true)"
    if [[ -n "${previous}" ]]; then
        git log --format='- %s' "${previous}..${TAG}"
    else
        git log --format='- %s' "${TAG}"
    fi
}

if [[ "${DRY_RUN}" == 0 ]]; then
    command -v gh >/dev/null 2>&1 || fail "gh not found"
    # The release account need not be the active gh account: its token goes to every gh and git call below,
    # so nothing is switched globally.
    GH_TOKEN="$(gh auth token --user "${GH_ACCOUNT}" 2>/dev/null)" \
        || fail "gh has no login for ${GH_ACCOUNT}: run gh auth login"
    export GH_TOKEN

    # A release is a snapshot of one commit on main.
    branch="$(git rev-parse --abbrev-ref HEAD)"
    [[ "${branch}" == "main" ]] || fail "not on main (on '${branch}')"
    [[ -z "$(git status --porcelain)" ]] || fail "working tree not clean: commit or stash first"

    # origin can be another copy of the project that has never seen the release tags.
    git_as_account fetch --quiet "${REPO_URL}" 'refs/tags/*:refs/tags/*'

    tag_exists=0
    release_exists=0
    git rev-parse --quiet --verify "refs/tags/${TAG}" >/dev/null && tag_exists=1
    gh release view "${TAG}" --repo "${REPO}" >/dev/null 2>&1 && release_exists=1

    if [[ "${tag_exists}" == 1 && "${release_exists}" == 1 ]]; then
        step "${TAG} is already on GitHub: only the tap is updated"
        download="$(mktemp -d)"
        gh release download "${TAG}" --repo "${REPO}" --pattern '*.zip' --dir "${download}" \
            || fail "cannot download the zip of release ${TAG}"
        SHA="$(shasum -a 256 "${download}"/*.zip | awk '{print $1}')"
        rm -rf "${download}"
        update_tap
        exit 0
    elif [[ "${tag_exists}" == 1 || "${release_exists}" == 1 ]]; then
        fail "inconsistent state for ${TAG} (tag=${tag_exists}, release=${release_exists}): fix it by hand"
    fi
fi

step "build ScreenISO ${VERSION}"
make build
APP="build/ScreenISO.app"
built="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP}/Contents/Info.plist")"
[[ "${built}" == "${VERSION}" ]] || fail "built app is ${built}, expected ${VERSION}"

step "zip ${ZIP}"
rm -f "${ZIP}"
ditto -c -k --keepParent "${APP}" "${ZIP}"

# The archive must give back an app whose signature still verifies, or it will not start after install.
check="$(mktemp -d)"
ditto -x -k "${ZIP}" "${check}"
codesign --verify --deep --strict "${check}/ScreenISO.app" || fail "the app extracted from ${ZIP} does not verify"
rm -rf "${check}"

SHA="$(shasum -a 256 "${ZIP}" | awk '{print $1}')"
echo "sha256 ${SHA}"

if [[ "${DRY_RUN}" == 1 ]]; then
    render_cask "build/${CASK_NAME}.rb"
    echo "dry run: nothing pushed, tagged or published"
    echo "  zip:  ${ZIP}"
    echo "  cask: build/${CASK_NAME}.rb"
    exit 0
fi

step "push main and ${TAG} to ${REPO}"
git_as_account push "${REPO_URL}" main
git tag -a "${TAG}" -m "ScreenISO ${TAG}"
git_as_account push "${REPO_URL}" "${TAG}"

step "create the GitHub release"
notes="$(mktemp)"
release_notes > "${notes}"
gh release create "${TAG}" "${ZIP}" --repo "${REPO}" --title "ScreenISO ${TAG}" --notes-file "${notes}"
rm -f "${notes}"

update_tap

echo "released ScreenISO ${TAG}"
echo "  install: brew install --cask ${GH_ACCOUNT}/${CASK_NAME}/${CASK_NAME}"
echo "  upgrade: brew update && brew upgrade --cask ${CASK_NAME}"
