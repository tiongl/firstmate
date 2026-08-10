#!/usr/bin/env bash
# fm-install-zellij.sh - install CI's pinned, verified Zellij build.
#
# Usage:
#   fm-install-zellij.sh <destination-directory>
#
# Pins the no-web Zellij v0.44.3 release exercised by the real backend smoke
# test. Selects an official release asset for Linux, macOS, or native Windows
# under Git Bash, verifies its SHA-256, and checks the installed version.
set -eu

FM_ZELLIJ_CI_VERSION=0.44.3
FM_ZELLIJ_CI_TAG="v${FM_ZELLIJ_CI_VERSION}"
FM_ZELLIJ_CI_MAX_BYTES=30000000
FM_ZELLIJ_CI_REPO=zellij-org/zellij

die() {
  printf 'fm-install-zellij.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-zellij.sh <destination-directory>}

os=$(uname -s)
arch=$(uname -m)
case "${os}-${arch}" in
  Linux-x86_64)
    ARCHIVE=zellij-no-web-x86_64-unknown-linux-musl.tar.gz
    SHA256=f901129919b0a405ac5f278f53acd7fde5d62401324c509b6233038d5c0ad1f9
    ;;
  Linux-aarch64|Linux-arm64)
    ARCHIVE=zellij-no-web-aarch64-unknown-linux-musl.tar.gz
    SHA256=9a92b94ba52e2b03f3a071a978d90922693221fa8ed59fd7f4819fe90e431996
    ;;
  Darwin-arm64)
    ARCHIVE=zellij-no-web-aarch64-apple-darwin.tar.gz
    SHA256=111e15402c73474003ff62b4577c415af1966891bddfc6e5a89b4f33b353c720
    ;;
  Darwin-x86_64)
    ARCHIVE=zellij-no-web-x86_64-apple-darwin.tar.gz
    SHA256=dcc734783a5c1d8d27157e3d8995e4341738535abb901b0a3422218677fbe049
    ;;
  MINGW*-x86_64|MSYS*-x86_64|CYGWIN*-x86_64)
    ARCHIVE=zellij-no-web-x86_64-pc-windows-msvc.zip
    SHA256=2a192ead623d326458b058f235a5c9ca6f955cece8b3787ce744c07ba9f11e34
    WINDOWS=1
    ;;
  *)
    die "unsupported platform ${os}-${arch}; supported assets are linux/macos x86_64 and arm64, plus Windows x86_64"
    ;;
esac

if [ "${WINDOWS:-0}" = 1 ] && command -v cygpath >/dev/null 2>&1; then
  DESTINATION=$(cygpath -u "$DESTINATION")
  TMP_BASE=$(cygpath -u "${RUNNER_TEMP:-${TMPDIR:-/tmp}}")
else
  TMP_BASE=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
fi

URL="https://github.com/${FM_ZELLIJ_CI_REPO}/releases/download/${FM_ZELLIJ_CI_TAG}/${ARCHIVE}"
TMP=$(mktemp -d "$TMP_BASE/fm-zellij.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

printf 'fm-install-zellij.sh: downloading %s from %s\n' "$ARCHIVE" "$URL" >&2
curl -fsSL --max-filesize "$FM_ZELLIJ_CI_MAX_BYTES" "$URL" -o "$TMP/$ARCHIVE" \
  || die "download failed for $URL (bounded at $FM_ZELLIJ_CI_MAX_BYTES bytes)"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ARCHIVE" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the Zellij archive"
fi

[ "$ACTUAL_SHA256" = "$SHA256" ] \
  || die "checksum mismatch for $ARCHIVE (expected $SHA256, got $ACTUAL_SHA256)"

case "$ARCHIVE" in
  *.zip)
    command -v unzip >/dev/null 2>&1 || die "unzip is required for the Windows Zellij archive"
    unzip -q "$TMP/$ARCHIVE" -d "$TMP/unpacked"
    BIN=$(find "$TMP/unpacked" -type f -name zellij.exe | head -n 1)
    [ -n "$BIN" ] || die "archive $ARCHIVE did not contain zellij.exe"
    TARGET=zellij.exe
    ;;
  *)
    tar -xzf "$TMP/$ARCHIVE" -C "$TMP"
    BIN=$(find "$TMP" -type f -name zellij | head -n 1)
    [ -n "$BIN" ] || die "archive $ARCHIVE did not contain zellij"
    TARGET=zellij
    ;;
esac

mkdir -p "$DESTINATION"
install -m 0755 "$BIN" "$DESTINATION/$TARGET"

installed_version=$("$DESTINATION/$TARGET" --version 2>/dev/null | awk '{print $2; exit}')
[ "$installed_version" = "$FM_ZELLIJ_CI_VERSION" ] \
  || die "installed zellij version is '${installed_version:-<empty>}', expected exact pin $FM_ZELLIJ_CI_VERSION"

printf 'fm-install-zellij.sh: installed zellij %s to %s\n' \
  "$installed_version" "$DESTINATION/$TARGET" >&2
"$DESTINATION/$TARGET" --version
