#!/usr/bin/env bash
# Runs the real Gitleaks section (lines 36-62) of .cursor/install.sh unchanged,
# with the same shell options and log() helper the script defines.
set -euo pipefail
SCRIPT="$1"; SHIMDIR="${2:-}"
[ -n "$SHIMDIR" ] && export PATH="$SHIMDIR:$PATH"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/fm-cloud-install.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
log() { printf 'install: %s\n' "$*" >&2; }
echo "uname -m => $(uname -m)"
sed -n '36,62p' "$SCRIPT" > "$STAGE/block.sh"
# shellcheck disable=SC1091
source "$STAGE/block.sh"
echo "block exit ok; staged gitleaks: $(ls -l "$STAGE/gitleaks" 2>/dev/null | awk '{print $5" bytes"}')"
file "$STAGE/gitleaks" 2>/dev/null || true
