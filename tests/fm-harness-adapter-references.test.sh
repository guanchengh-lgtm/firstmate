#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROUTER="$ROOT/.agents/skills/harness-adapters/SKILL.md"
TMP_ROOT=$(fm_test_tmproot fm-harness-adapter-references)
ROUTING_JSON="$TMP_ROOT/routing.json"
EXPECTED_JSON="$TMP_ROOT/expected-routing.json"

awk '
  /^```json harness-adapter-routing-v1$/ { capture = 1; next }
  capture && /^```$/ { exit }
  capture { print }
' "$ROUTER" > "$ROUTING_JSON"

cat > "$EXPECTED_JSON" <<'EOF'
{
  "operations": {
    "start": {
      "default": ["references/common/dispatch.md", "references/common/model-and-effort.md"],
      "trust-dialog": ["references/common/control-and-recovery.md"]
    },
    "trust": {"default": ["references/common/control-and-recovery.md"]},
    "skill": {"default": ["references/common/control-and-recovery.md"]},
    "interrupt": {"default": ["references/common/control-and-recovery.md"]},
    "exit": {"default": ["references/common/control-and-recovery.md"]},
    "resume": {"default": ["references/common/control-and-recovery.md"]},
    "recovery": {
      "default": ["references/common/control-and-recovery.md"],
      "replacement-profile": ["references/common/control-and-recovery.md", "references/common/dispatch.md", "references/common/model-and-effort.md"],
      "secondmate": ["references/common/control-and-recovery.md", "references/common/primary-hooks.md"],
      "replacement-secondmate": ["references/common/control-and-recovery.md", "references/common/dispatch.md", "references/common/model-and-effort.md", "references/common/primary-hooks.md"]
    },
    "primary": {"default": ["references/common/primary-hooks.md"]},
    "model-effort": {
      "default": ["references/common/model-and-effort.md"],
      "configured-profile": ["references/common/model-and-effort.md", "references/common/dispatch.md"]
    },
    "verify": {"default": ["references/common/dispatch.md", "references/common/control-and-recovery.md", "references/common/primary-hooks.md", "references/common/model-and-effort.md"]}
  },
  "harnesses": {
    "claude": "references/harness/claude.md",
    "codex": "references/harness/codex.md",
    "opencode": "references/harness/opencode.md",
    "pi": "references/harness/pi.md",
    "pi-signed": "references/harness/pi.md",
    "grok": "references/harness/grok.md",
    "kimi": "references/harness/kimi.md",
    "cursor": "references/harness/cursor.md",
    "muse": "references/harness/muse.md"
  }
}
EOF

jq -e --slurp '.[0] == .[1]' "$ROUTING_JSON" "$EXPECTED_JSON" >/dev/null \
  || fail "harness adapter routing artifact does not match the owned routing contract"

while IFS= read -r path; do
  [ -r "$ROOT/.agents/skills/harness-adapters/$path" ] \
    || fail "harness adapter routing target is unreadable: $path"
done < <(jq -r '.operations[][][], .harnesses[]' "$ROUTING_JSON" | sort -u)
pass "harness adapter routing artifact matches the exact map and every target is readable"
