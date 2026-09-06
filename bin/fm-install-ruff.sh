#!/usr/bin/env bash
# fm-install-ruff.sh - install CI's pinned, verified Ruff build.
#
# Downloads the official Astral release archive for the host OS/arch, verifies
# its per-archive SHA-256 pin, and installs the binary into the destination
# directory. Supported platforms: linux amd64/x86_64, linux arm64/aarch64,
# darwin amd64/x86_64, darwin arm64/aarch64. Pins come from the official
# Ruff 0.16.6 release checksum files. Verification uses sha256sum when present,
# otherwise shasum -a 256. An unsupported OS/arch or a missing pin fails
# without downloading.
#
# Usage:
#   fm-install-ruff.sh <destination-directory>
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$("$ROOT/bin/fm-lint.sh" --required-ruff-version)"

die() {
  printf 'fm-install-ruff.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-ruff.sh <destination-directory>}

os=$(uname -s)
arch=$(uname -m)
# SHA-256 pins are the official Ruff 0.16.6 release checksum files
# (https://github.com/astral-sh/ruff/releases/tag/0.16.6).
case "${os}-${arch}" in
  Linux-x86_64|Linux-amd64)
    ARCHIVE="ruff-x86_64-unknown-linux-gnu.tar.gz"
    SHA256=0696335ef16615d8c7445ad438750eb0f55b3da6f153df21265a7c6d5750254f
    ;;
  Linux-aarch64|Linux-arm64)
    ARCHIVE="ruff-aarch64-unknown-linux-gnu.tar.gz"
    SHA256=3c1b99f65b8bf2df64ff099ee072e11b4652813e2c164ec875a26fc9e99be88f
    ;;
  Darwin-x86_64|Darwin-amd64)
    ARCHIVE="ruff-x86_64-apple-darwin.tar.gz"
    SHA256=87cce7e591603efa979be9044ac00835638a5d9052947070b6e2e7c0cdb21940
    ;;
  Darwin-arm64|Darwin-aarch64)
    ARCHIVE="ruff-aarch64-apple-darwin.tar.gz"
    SHA256=77513748c833b435b82453ba20e07db808ef6c5121945ede80a6cf21bee468a4
    ;;
  *)
    die "unsupported platform ${os}-${arch}; need linux or darwin on amd64/x86_64 or arm64/aarch64"
    ;;
esac
[ -n "$SHA256" ] || die "no pinned checksum for ${os}-${arch}"

URL="https://releases.astral.sh/github/ruff/releases/download/${VERSION}/${ARCHIVE}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-ruff.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

DOWNLOAD_ATTEMPTS=6
download_attempt=1
while ! curl -fsSL "$URL" -o "$TMP/$ARCHIVE"; do
  [ "$download_attempt" -lt "$DOWNLOAD_ATTEMPTS" ] || {
    printf 'fm-install-ruff.sh: download failed after %s attempts\n' "$DOWNLOAD_ATTEMPTS" >&2
    exit 1
  }
  printf 'fm-install-ruff.sh: download attempt %s failed; retrying\n' "$download_attempt" >&2
  sleep $((1 << (download_attempt - 1)))
  download_attempt=$((download_attempt + 1))
done

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ARCHIVE" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the Ruff archive"
fi
[ "$ACTUAL_SHA256" = "$SHA256" ] || {
  printf 'fm-install-ruff.sh: checksum mismatch for %s (expected %s, got %s)\n' \
    "$ARCHIVE" "$SHA256" "$ACTUAL_SHA256" >&2
  exit 1
}

mkdir -p "$DESTINATION"
tar -xzf "$TMP/$ARCHIVE" -C "$TMP"
found=$(find "$TMP" -type f -name ruff | head -n 1)
[ -n "$found" ] || die "archive $ARCHIVE did not contain a ruff binary"
cp "$found" "$DESTINATION/ruff"
chmod 755 "$DESTINATION/ruff"
