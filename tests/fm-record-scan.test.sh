#!/usr/bin/env bash
# Behavior tests for bin/fm-record-scan.sh through its public command and
# through the feeder executable that reuses it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCAN="$ROOT/bin/fm-record-scan.sh"
TMP_ROOT=$(fm_test_tmproot fm-record-scan)
fm_git_identity fmtest fmtest@example.invalid

secret_fixture() {
  case "$1" in
    openssh-private-key) printf -- '%s\n%s\n%s\n' \
      '-----BEGIN OPENSSH PRIVATE KEY-----' \
      'YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE=' \
      '-----END OPENSSH PRIVATE KEY-----' ;;
    encrypted-private-key) printf -- '%s\n%s\n%s\n' \
      '-----BEGIN ENCRYPTED PRIVATE KEY-----' \
      'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA' \
      '-----END ENCRYPTED PRIVATE KEY-----' ;;
    github-classic) printf '%s%s' 'ghp' '_0123456789abcdefghijklmnopqrstuvwxyzAB' ;;
    github-pat) printf '%s%s' 'github' '_pat_0123456789abcdefghijklmnop' ;;
    aws-access-key) printf '%s%s' 'AKI' 'AABCDEFGHIJKLMNOP' ;;
    slack) printf '%s%s' 'xox' 'b-0123456789abcdef' ;;
    stripe-live) printf '%s%s' 'sk' '_live_0123456789abcdefgh' ;;
    stripe-test) printf '%s%s' 'sk' '_test_0123456789abcdefgh' ;;
    google-api) printf '%s%s' 'AIz' 'aabcdefghijklmnopqrstuvwxyz0123456789' ;;
    openai-project) printf '%s%s' 'sk-' 'proj-0123456789abcdefghijklmnopQRSTUV' ;;
    openai-service-account) printf '%s%s' 'sk-' 'svcacct-0123456789abcdefghijklmnopQRSTUV' ;;
    openai-admin) printf '%s%s' 'sk-' 'admin-0123456789abcdefghijklmnopQRSTUV' ;;
    openai-plain) printf '%s%s' 'sk-' '0123456789abcdefghijklmnopQRSTUV' ;;
    openai-underscore-suffix) printf '%s%s' 'sk-' '0123456789abcdefghijklmnop_suffixX' ;;
    *) fail "secret_fixture: unknown fixture $1" ;;
  esac
}

run_scan() {
  local out rc
  set +e
  out=$("$SCAN" "$@" 2>&1)
  rc=$?
  set -e
  OUT=$out
  RC=$rc
}

test_help_names_owner_and_codes() {
  run_scan --help
  expect_code 0 "$RC" 'help'
  assert_contains "$OUT" 'Exit codes' 'help omitted exit codes'
  assert_contains "$OUT" 'gitleaks' 'help omitted gitleaks'
  assert_contains "$OUT" 'fail-closed' 'help omitted fail-closed policy'
  pass "fm-record-scan: --help names the scan contract"
}

test_eight_classes_refuse_without_echoing_values() {
  local dir pair class secret
  local pairs='private-key:openssh-private-key
private-key:encrypted-private-key
github-classic-token:github-classic
github-fine-grained-token:github-pat
aws-access-key-id:aws-access-key
slack-token:slack
stripe-live-key:stripe-live
google-api-key:google-api
openai-key:openai-project
openai-key:openai-service-account
openai-key:openai-admin
openai-key:openai-plain
openai-key:openai-underscore-suffix'

  dir="$TMP_ROOT/classes"
  mkdir -p "$dir"
  while IFS= read -r pair; do
    class=${pair%%:*}
    secret=$(secret_fixture "${pair#*:}")
    printf '# leaky\n\n%s\n' "$secret" > "$dir/payload.md"
    run_scan tree "$dir"
    expect_code 2 "$RC" "class $class"
    assert_contains "$OUT" "$class" "class $class not named"
    assert_contains "$OUT" 'refusing to publish' "class $class missing refusal"
    assert_not_contains "$OUT" "$secret" "class $class echoed the secret"
  done <<< "$pairs"
  pass "fm-record-scan: every feeder class refuses without echoing the value"
}

test_lookalikes_are_clean() {
  local dir
  dir="$TMP_ROOT/lookalikes"
  mkdir -p "$dir"
  cat > "$dir/safe.md" <<'MD'
A short OpenAI token like sk-short stays ordinary text.
A color token like sk-gradient-from-blue-to-navy-and-then-some is not a key.
Decision key: sample-route-call
See the quoted header "-----BEGIN PRIVATE KEY-----" in this sentence.
-----BEGIN PRIVATE KEY-----
A short token like ghp_abc or AKIAshort is not a credential shape.
The literal pattern gh[pousr]_[A-Za-z0-9]{36,255} is documentation.
MD
  run_scan tree "$dir"
  expect_code 0 "$RC" 'lookalikes'
  run_scan class "$dir/safe.md"
  expect_code 0 "$RC" 'lookalike class'
  assert_contains "$OUT" 'none' 'quoted header classified as a key'
  pass "fm-record-scan: lookalikes stay clean"
}

test_credential_shaped_path_is_redacted() {
  local dir token body
  dir="$TMP_ROOT/path-label"
  token=$(secret_fixture github-classic)
  body=$(secret_fixture aws-access-key)
  mkdir -p "$dir"
  printf '# leaky\n\n%s\n' "$body" > "$dir/${token}.md"
  run_scan tree "$dir"
  expect_code 2 "$RC" 'path-label'
  assert_contains "$OUT" 'credential-shaped source path redacted' 'path-label not redacted'
  assert_not_contains "$OUT" "$token" 'path-label leaked the token'
  assert_not_contains "$OUT" "$body" 'path-label leaked the body token'
  pass "fm-record-scan: credential-shaped path labels are redacted"
}

test_binary_bytes_and_scan_errors_fail_closed() {
  local dir fakebin
  dir="$TMP_ROOT/binary"
  mkdir -p "$dir"
  printf '# leaky\n\n%s\n' "$(secret_fixture slack)" > "$dir/payload.bin"
  printf '\000' >> "$dir/payload.bin"
  run_scan tree "$dir"
  expect_code 2 "$RC" 'binary-hit'
  assert_contains "$OUT" 'slack-token' 'binary class missing'
  assert_not_contains "$OUT" "$(secret_fixture slack)" 'binary echoed the secret'

  dir="$TMP_ROOT/grep-fail"
  mkdir -p "$dir/tree" "$dir/fakebin"
  printf 'plain\n' > "$dir/tree/ok.md"
  cat > "$dir/fakebin/grep" <<'SH'
#!/usr/bin/env bash
exit 2
SH
  chmod +x "$dir/fakebin/grep"
  set +e
  OUT=$(PATH="$dir/fakebin:$PATH" "$SCAN" tree "$dir/tree" 2>&1)
  RC=$?
  set -e
  [ "$RC" -ne 0 ] || fail 'grep failure reported clean'
  assert_contains "$OUT" 'credential scan failed' 'grep failure message'
  pass "fm-record-scan: binary hits and scanner errors fail closed"
}

test_gitleaks_missing_and_broken_config_fail_closed() {
  local dir fakebin
  dir="$TMP_ROOT/gitleaks-missing/tree"
  mkdir -p "$dir" "$TMP_ROOT/gitleaks-missing/fakebin"
  printf 'plain\n' > "$dir/ok.md"
  cat > "$TMP_ROOT/gitleaks-missing/fakebin/true" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$TMP_ROOT/gitleaks-missing/fakebin/true"
  set +e
  OUT=$(PATH="$TMP_ROOT/gitleaks-missing/fakebin:/usr/bin:/bin" "$SCAN" gitleaks --dir "$dir" 2>&1)
  RC=$?
  set -e
  [ "$RC" -ne 0 ] || fail 'missing gitleaks reported clean'
  assert_contains "$OUT" 'gitleaks is missing' 'missing gitleaks message'

  dir="$TMP_ROOT/gitleaks-nonzero/tree"
  mkdir -p "$dir" "$TMP_ROOT/gitleaks-nonzero/fakebin"
  printf 'plain\n' > "$dir/ok.md"
  cat > "$TMP_ROOT/gitleaks-nonzero/fakebin/gitleaks" <<'SH'
#!/usr/bin/env bash
exit 3
SH
  chmod +x "$TMP_ROOT/gitleaks-nonzero/fakebin/gitleaks"
  set +e
  OUT=$(PATH="$TMP_ROOT/gitleaks-nonzero/fakebin:$PATH" "$SCAN" gitleaks --dir "$dir" 2>&1)
  RC=$?
  set -e
  [ "$RC" -ne 0 ] || fail 'nonzero gitleaks reported clean'
  assert_contains "$OUT" 'gitleaks scan failed' 'nonzero gitleaks message'
  pass "fm-record-scan: missing and failing gitleaks fail closed"
}

test_gitleaks_only_and_feeder_only_each_block() {
  local dir secret
  dir="$TMP_ROOT/gitleaks-only"
  mkdir -p "$dir"
  secret=$(secret_fixture stripe-test)
  printf 'token %s\n' "$secret" > "$dir/stripe-test.txt"
  run_scan gitleaks --dir "$dir"
  expect_code 2 "$RC" 'gitleaks-only'
  assert_not_contains "$OUT" "$secret" 'gitleaks-only echoed the secret'

  run_scan tree "$dir"
  expect_code 0 "$RC" 'feeder misses stripe-test'

  dir="$TMP_ROOT/feeder-only"
  mkdir -p "$dir"
  secret=$(secret_fixture openai-plain)
  printf '# leaky\n\n%s\n' "$secret" > "$dir/openai.md"
  run_scan tree "$dir"
  expect_code 2 "$RC" 'feeder-only tree'
  assert_contains "$OUT" 'openai-key' 'feeder-only class'
  assert_not_contains "$OUT" "$secret" 'feeder-only echoed the secret'
  pass "fm-record-scan: gitleaks-only and feeder-only hits each block independently"
}

test_inline_allow_comment_is_ignored() {
  local dir secret
  dir="$TMP_ROOT/allow-comment"
  mkdir -p "$dir"
  secret=$(secret_fixture stripe-test)
  printf 'token %s  # gitleaks:allow\n' "$secret" > "$dir/allowed.txt"
  run_scan gitleaks --dir "$dir"
  expect_code 2 "$RC" 'gitleaks-allow'
  assert_not_contains "$OUT" "$secret" 'gitleaks-allow echoed the secret'
  pass "fm-record-scan: gitleaks:allow comments do not exempt a hit"
}

test_archive_corrupt_and_encrypted_refuse() {
  local dir
  dir="$TMP_ROOT/archives/corrupt"
  mkdir -p "$dir"
  printf 'not-a-zip' > "$dir/bad.zip"
  run_scan archive-preflight --dir "$dir"
  [ "$RC" -ne 0 ] || fail 'corrupt zip was accepted'
  assert_contains "$OUT" 'corrupt' 'corrupt zip message'

  dir="$TMP_ROOT/archives/encrypted"
  mkdir -p "$dir"
  python3 - "$dir/secret.zip" <<'PY'
import sys
import zipfile
path = sys.argv[1]
zf = zipfile.ZipFile(path, "w")
zf.writestr("hidden.txt", "nope")
zf.close()
data = bytearray(open(path, "rb").read())
data[6] |= 1
central = data.find(b"PK\x01\x02")
if central >= 0:
    data[central + 8] |= 1
open(path, "wb").write(data)
PY
  run_scan archive-preflight --dir "$dir"
  [ "$RC" -ne 0 ] || fail 'encrypted zip was accepted'
  assert_contains "$OUT" 'encrypted' 'encrypted zip message'
  pass "fm-record-scan: corrupt and encrypted archives refuse"
}

test_lfs_pointer_does_not_hide_payload() {
  local dir secret
  dir="$TMP_ROOT/lfs-payload"
  mkdir -p "$dir"
  secret=$(secret_fixture github-classic)
  cat > "$dir/pointer.md" <<'PTR'
version https://git-lfs.github.com/spec/v1
oid sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
size 123
PTR
  printf '%s\n' "$secret" > "$dir/payload.bin"
  run_scan tree "$dir"
  expect_code 2 "$RC" 'lfs-payload'
  assert_contains "$OUT" 'github-classic-token' 'lfs payload class'
  assert_not_contains "$OUT" "$secret" 'lfs payload echoed the secret'
  pass "fm-record-scan: LFS pointer text is not enough; payload bytes are scanned"
}

test_chain_clean_tree() {
  local dir
  dir="$TMP_ROOT/chain-clean"
  mkdir -p "$dir"
  printf '# safe\n\nhello\n' > "$dir/ok.md"
  run_scan chain --dir "$dir"
  expect_code 0 "$RC" 'chain-clean'
  pass "fm-record-scan: chain accepts a clean tree"
}

test_help_names_owner_and_codes
test_eight_classes_refuse_without_echoing_values
test_lookalikes_are_clean
test_credential_shaped_path_is_redacted
test_binary_bytes_and_scan_errors_fail_closed
test_gitleaks_missing_and_broken_config_fail_closed
test_gitleaks_only_and_feeder_only_each_block
test_inline_allow_comment_is_ignored
test_archive_corrupt_and_encrypted_refuse
test_lfs_pointer_does_not_hide_payload
test_chain_clean_tree
