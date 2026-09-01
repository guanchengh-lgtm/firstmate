demo_end_to_end() {
  local dir
  dir=$(new_case e2e-demo)
  add_decision "$dir" knowledge-stack-2026-08-31.md '# Knowledge stack lock — feeder is a private mirror

The feeder is a one-way private GitHub mirror.
No BM25, no index build, no write-back.
'
  add_decision "$dir" naming-2026-02-14.md '# Naming lock

Destination identifiers stay portable ASCII.
'
  add_report "$dir" kb-feeder-scout '# Feeder scout report

Section 4 is the design of record.
'

  echo "=== STEP 1: first export (publish + push) ==="
  echo "$ bin/fm-feeder-export.sh"
  run_export "$dir"; printf '%s\n' "$OUT"; echo "exit=$RC"

  echo
  echo "=== vault commit created by the exporter ==="
  git -C "$dir/vault" log --oneline -1 --stat

  echo
  echo "=== files in the vault working tree ==="
  (cd "$dir/vault" && LC_ALL=C find wiki -type f | LC_ALL=C sort)

  echo
  echo "=== rendered mirror page wiki/decisions/knowledge-stack-2026-08-31.md ==="
  cat "$dir/vault/wiki/decisions/knowledge-stack-2026-08-31.md"

  echo
  echo "=== rendered index wiki/decisions/_index.md ==="
  cat "$dir/vault/wiki/decisions/_index.md"

  echo
  echo "=== pushed state on the bare origin (git show refs/heads/main) ==="
  git -C "$dir/origin.git" log --oneline -1 refs/heads/main
  git -C "$dir/origin.git" ls-tree -r --name-only refs/heads/main
  echo "local HEAD  = $(git -C "$dir/vault" rev-parse HEAD)"
  echo "origin main = $(git -C "$dir/origin.git" rev-parse refs/heads/main)"
  echo "private-visibility checks issued to gh-axi:"
  cat "$dir/gh.log"

  echo
  echo "=== STEP 2: rerun with no source change (no commit, still pushes HEAD) ==="
  local head_before
  head_before=$(git -C "$dir/vault" rev-parse HEAD)
  echo "$ bin/fm-feeder-export.sh"
  run_export "$dir"; printf '%s\n' "$OUT"; echo "exit=$RC"
  echo "HEAD unchanged: $([ "$head_before" = "$(git -C "$dir/vault" rev-parse HEAD)" ] && echo yes || echo no)"

  echo
  echo "=== STEP 3: a source record carrying a credential refuses before any mutation ==="
  local key
  key="sk-$(printf 'proj')_$(printf 'A%.0s' $(seq 1 40))$(printf 'B%.0s' $(seq 1 40))"
  add_decision "$dir" leaky-2026-03-01.md "# Leaky lock

token: $key
"
  echo "$ bin/fm-feeder-export.sh"
  run_export "$dir"; printf '%s\n' "$OUT"; echo "exit=$RC"
  echo "credential text printed by the exporter: $(printf '%s' "$OUT" | grep -c "$key") occurrences"
  echo "HEAD unchanged: $([ "$head_before" = "$(git -C "$dir/vault" rev-parse HEAD)" ] && echo yes || echo no)"
  rm -f "$dir/home/data/decisions/leaky-2026-03-01.md"

  echo
  echo "=== STEP 4: change one source record, export again ==="
  add_decision "$dir" naming-2026-02-14.md '# Naming lock

Destination identifiers stay portable ASCII.
Collisions are refused outright.
'
  echo "$ bin/fm-feeder-export.sh"
  run_export "$dir"; printf '%s\n' "$OUT"; echo "exit=$RC"
  git -C "$dir/vault" log --oneline -1 --name-only
  echo "origin main now = $(git -C "$dir/origin.git" rev-parse refs/heads/main)"
  echo "local HEAD      = $(git -C "$dir/vault" rev-parse HEAD)"
  echo "vault worktree clean: $([ -z "$(git -C "$dir/vault" status --porcelain)" ] && echo yes || echo no)"

  echo
  echo "=== STEP 5: the source of record was never written back to ==="
  echo "$ find home/data -type f | sort  (after four export runs)"
  (cd "$dir/home" && LC_ALL=C find data -type f | LC_ALL=C sort)
  echo "sources still hold exactly the bytes the operator wrote:"
  (cd "$dir/home" && LC_ALL=C find data -type f | LC_ALL=C sort \
    | while IFS= read -r f; do printf '%s %s\n' "$(shasum -a 256 "$f" | awk '{print $1}')" "$f"; done)
}
demo_end_to_end
