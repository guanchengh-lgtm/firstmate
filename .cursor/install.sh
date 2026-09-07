#!/usr/bin/env bash
# Cloud Agent install for the firstmate template.
#
# Installs the pinned developer toolbelt that firstmate's lint and behavior
# test suites expect, matching the versions in .github/workflows/ci.yml so a
# Cloud Agent reproduces CI parity. The base image already provides bash 5,
# node, npm, jq, python3, tmux, git, perl, and iconv; this script adds the
# tools that are otherwise missing.
#
# Idempotent: every step installs a fixed, pinned version and overwrites any
# prior copy, so re-running converges to the same state without accumulating
# anything. Safe to run repeatedly and against a cached or partially prepared
# filesystem.
#
# Binaries land in /usr/local/bin (already on PATH for agent shells); the
# repo's own verified installers own each pin and checksum.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BINDIR=/usr/local/bin
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/fm-cloud-install.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

log() { printf 'install: %s\n' "$*" >&2; }

# 1. Pinned lint toolchain via the repo's checksum-verified installers.
log "installing pinned ShellCheck, Ruff, and actionlint"
bin/fm-install-shellcheck.sh "$STAGE"
bin/fm-install-ruff.sh "$STAGE"
bin/fm-install-actionlint.sh "$STAGE"

# 2. Pinned Gitleaks, matching the version and checksum in ci.yml. Used by the
#    record-scan toolbelt; the base image lacks it.
GITLEAKS_VERSION=8.30.1
case "$(uname -m)" in
  x86_64 | amd64)
    gl_asset="gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
    gl_sha256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
    ;;
  aarch64 | arm64)
    gl_asset="gitleaks_${GITLEAKS_VERSION}_linux_arm64.tar.gz"
    gl_sha256=
    ;;
  *)
    log "unsupported architecture $(uname -m) for gitleaks; skipping"
    gl_asset=
    ;;
esac
if [ -n "$gl_asset" ]; then
  log "installing pinned Gitleaks ${GITLEAKS_VERSION}"
  gl_url="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/${gl_asset}"
  curl --fail --silent --show-error --location --retry 6 "$gl_url" -o "$STAGE/$gl_asset"
  if [ -n "$gl_sha256" ]; then
    printf '%s  %s\n' "$gl_sha256" "$STAGE/$gl_asset" | sha256sum --check
  else
    log "no pinned checksum for this architecture; installing without verification"
  fi
  tar -xzf "$STAGE/$gl_asset" -C "$STAGE" gitleaks
fi

# 3. Publish the staged binaries onto PATH (sudo: /usr/local/bin is root-owned).
log "publishing binaries to $BINDIR"
staged=("$STAGE"/shellcheck "$STAGE"/ruff "$STAGE"/actionlint)
[ -n "$gl_asset" ] && staged+=("$STAGE"/gitleaks)
sudo install -m 0755 "${staged[@]}" "$BINDIR"/

# 4. Ruby: the base image lacks it, but ubuntu-latest CI ships it and one
#    fm-test-run contract test parses ci.yml as YAML through ruby.
if ! command -v ruby >/dev/null 2>&1; then
  log "installing ruby (system package)"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ruby >/dev/null
fi

# 5. Ensure `node` resolves to a build that supports unflagged TypeScript type
#    stripping (Node >= 22.18). The Pi extension tests import .ts files with a
#    bare `node`, and the pinned Pi package's engines field requires it. The
#    base harness may place an older node first on PATH; if so, pin a capable
#    node/npm/npx (already installed on the machine) into the first writable
#    PATH directory so the whole environment agrees on one node.
ensure_capable_node() {
  local probe="$STAGE/probe.ts" candidate="" c nodebin dir first_writable=""
  printf 'export const x: number = 1;\nprocess.stdout.write(String(x));\n' >"$probe"
  if node "$probe" >/dev/null 2>&1; then
    return 0
  fi
  log "primary node lacks TypeScript type stripping; pinning a capable node"
  for c in "$HOME"/.nvm/versions/node/*/bin/node /usr/local/bin/node /usr/bin/node; do
    [ -x "$c" ] || continue
    if "$c" "$probe" >/dev/null 2>&1; then
      candidate="$c"
      break
    fi
  done
  [ -n "$candidate" ] || {
    log "WARNING: no TypeScript-capable node found; Pi extension tests may skip"
    return 0
  }
  while IFS= read -r dir; do
    [ -n "$dir" ] && [ -d "$dir" ] && [ -w "$dir" ] && {
      first_writable="$dir"
      break
    }
  done < <(printf '%s\n' "$PATH" | tr ':' '\n')
  [ -n "$first_writable" ] || {
    log "WARNING: no writable PATH directory found to pin node"
    return 0
  }
  nodebin="$(dirname "$candidate")"
  ln -sf "$candidate" "$first_writable/node"
  [ -x "$nodebin/npm" ] && ln -sf "$nodebin/npm" "$first_writable/npm"
  [ -x "$nodebin/npx" ] && ln -sf "$nodebin/npx" "$first_writable/npx"
  hash -r 2>/dev/null || true
  log "pinned node $("$candidate" --version) into $first_writable"
}
ensure_capable_node

# 6. Node-based dev dependencies, installed into this node's global root so both
#    PATH and `npm root -g` (which the Pi tests use to locate the package) agree.
#    tasks-axi is the tracked backlog backend (.tasks.toml); the Pi package and
#    TypeScript back the Pi extension typecheck tests. Pins match ci.yml.
log "installing node global dev dependencies (tasks-axi, Pi, TypeScript)"
npm install -g \
  tasks-axi@0.2.5 \
  @earendil-works/pi-coding-agent@0.84.4 \
  typescript@5.9.3 >/dev/null

# 7. Report the resulting toolbelt for a quick sanity read in setup logs.
log "installed toolbelt:"
shellcheck --version | awk '/^version:/ {print "  shellcheck " $2}'
printf '  ruff %s\n' "$(ruff version | awk '{print $2}')" >&2
printf '  actionlint %s\n' "$(actionlint -version | head -1)" >&2
[ -n "$gl_asset" ] && printf '  gitleaks %s\n' "$(gitleaks version)" >&2
printf '  ruby %s\n' "$(ruby --version | awk '{print $2}')" >&2
printf '  tasks-axi %s\n' "$(tasks-axi --version)" >&2
printf '  pi %s\n' "$(pi --version 2>/dev/null | head -1)" >&2
printf '  tsc %s\n' "$(tsc --version 2>/dev/null | awk '{print $2}')" >&2
log "done"
