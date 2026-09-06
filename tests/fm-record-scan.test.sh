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
    openssh-private-key) printf -- '-----BEGIN OPENSSH PRIVATE %s-----' 'KEY' ;;
    encrypted-private-key) printf -- '-----BEGIN ENCRYPTED PRIVATE %s-----' 'KEY' ;;
    github-classic) printf '%s%s' 'ghp' '_0123456789abcdefghijklmnopqrstuvwxyzAB' ;;
    github-pat) printf '%s%s' 'github' '_pat_0123456789abcdefghijklmnop' ;;
    aws-access-key) printf '%s%s' 'AKI' 'AABCDEFGHIJKLMNOP' ;;
    slack) printf '%s%s' 'xox' 'b-0123456789abcdef' ;;
    stripe-live) printf '%s%s' 'sk' '_live_0123456789abcdefgh' ;;
    stripe-test) printf '%s%s' 'sk' '_test_0123456789abcdefgh' ;;
    google-api) printf '%s%s' 'AIz' 'aabcdefghijklmnopqrstuvwxyz0123456789' ;;
    openai-project) printf '%s%s' 'sk-' 'proj-0123456789_abcd-efghijklmnop' ;;
    openai-service-account) printf '%s%s' 'sk-' 'svcacct-0123456789_abcd-efghijklmnop' ;;
    openai-admin) printf '%s%s' 'sk-' 'admin-0123456789_abcd-efghijklmnop' ;;
    openai-plain) printf '%s%s' 'sk-' '0123456789abcdefghijklmnop' ;;
    openai-underscore-suffix) printf '%s%s' 'sk-' '0123456789abcdefghij_suffix' ;;
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
Decision key: sample-route-call
A short token like ghp_abc or AKIAshort is not a credential shape.
The literal pattern gh[pousr]_[A-Za-z0-9]{36,255} is documentation.
MD
  run_scan tree "$dir"
  expect_code 0 "$RC" 'lookalikes'
  run_scan class "$dir/safe.md"
  expect_code 0 "$RC" 'lookalike class'
  assert_contains "$OUT" 'none' 'lookalike classified as a key'
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
  run_scan chain --dir "$dir"
  expect_code 2 "$RC" 'chain path-label'
  assert_contains "$OUT" 'credential-shaped source path redacted' 'gitleaks path-label not redacted'
  assert_not_contains "$OUT" "$token" 'gitleaks path-label leaked the token'
  assert_not_contains "$OUT" "$body" 'gitleaks path-label leaked the body token'
  printf 'harmless content\n' > "$dir/${token}.md"
  run_scan tree "$dir"
  expect_code 0 "$RC" 'feeder filename contract'
  run_scan chain --dir "$dir"
  expect_code 2 "$RC" 'credential filename with harmless content'
  assert_not_contains "$OUT" "$token" 'harmless filename leaked the token'
  rm "$dir/${token}.md"
  printf 'corrupt archive' > "$dir/${token}.zip"
  run_scan chain --dir "$dir"
  expect_code 2 "$RC" 'archive path-label'
  assert_not_contains "$OUT" "$token" 'archive diagnostic leaked the token'
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
  cat > "$TMP_ROOT/gitleaks-nonzero/fakebin/gitleaks" <<'SH'
#!/usr/bin/env bash
printf 'WRN incomplete scan with private diagnostic\n' >&2
exit 0
SH
  set +e
  OUT=$(PATH="$TMP_ROOT/gitleaks-nonzero/fakebin:$PATH" "$SCAN" chain --dir "$dir" 2>&1)
  RC=$?
  set -e
  expect_code 1 "$RC" 'incomplete gitleaks scan'
  assert_not_contains "$OUT" 'private diagnostic' 'raw diagnostic was exposed'
  pass "fm-record-scan: missing, failing, and incomplete gitleaks scans fail closed"
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

test_private_key_headers_refuse_in_serialized_text() {
  local dir header format
  dir="$TMP_ROOT/private-headers"
  mkdir -p "$dir"
  header=$(secret_fixture openssh-private-key)
  for format in indented json; do
    if [ "$format" = indented ]; then
      printf '  %s\n' "$header" > "$dir/key.txt"
    else
      printf '{"key":"%s\\nbody"}\n' "$header" > "$dir/key.txt"
    fi
    run_scan tree "$dir"
    expect_code 2 "$RC" "$format private key header"
    assert_contains "$OUT" 'private-key' 'serialized header was not classified'
    assert_not_contains "$OUT" "$header" 'serialized header was exposed'
  done
  pass "fm-record-scan: private key headers refuse in indented and serialized text"
}

test_compressed_feeder_patterns_block_the_chain() {
  local dir secret
  dir="$TMP_ROOT/compressed-feeder"
  mkdir -p "$dir"
  secret=$(secret_fixture openai-plain)
  python3 - "$dir/archive.zip" "$secret" <<'PYTEST'
import io
import sys
import zipfile
inner = io.BytesIO()
with zipfile.ZipFile(inner, "w", zipfile.ZIP_DEFLATED) as archive:
    archive.writestr("payload.txt", sys.argv[2])
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as archive:
    archive.writestr("inner.zip", inner.getvalue())
PYTEST
  run_scan chain --dir "$dir"
  expect_code 2 "$RC" 'compressed feeder pattern'
  assert_not_contains "$OUT" "$secret" 'archive scan leaked the token'
  pass "fm-record-scan: compressed feeder patterns block the archive-aware chain"
}

test_gitleaks_path_exclusions_do_not_hide_payloads() {
  local dir secret
  dir="$TMP_ROOT/excluded-binary"
  mkdir -p "$dir"
  secret=$(secret_fixture stripe-test)
  printf 'token %s\n' "$secret" > "$dir/response.bin"
  run_scan tree "$dir"
  expect_code 0 "$RC" 'feeder still misses Stripe test keys'
  run_scan gitleaks --dir "$dir"
  expect_code 2 "$RC" 'gitleaks binary payload'
  assert_not_contains "$OUT" "$secret" 'binary scan exposed the token'
  run_scan chain --dir "$dir"
  expect_code 2 "$RC" 'chain binary payload'
  rm "$dir/response.bin"
  printf 'harmless content\n' > "$dir/${secret}.txt"
  run_scan chain --dir "$dir"
  expect_code 2 "$RC" 'gitleaks-only filename'
  assert_not_contains "$OUT" "$secret" 'gitleaks-only filename was exposed'
  rm "$dir/${secret}.txt"
  python3 - "$dir/archive.zip" "$secret" <<'PY'
import io
import sys
import tarfile
import zipfile
inner = io.BytesIO()
with tarfile.open(fileobj=inner, mode="w") as archive:
    payload = sys.argv[2].encode()
    entry = tarfile.TarInfo("response.bin")
    entry.size = len(payload)
    archive.addfile(entry, io.BytesIO(payload))
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as archive:
    archive.writestr("inner.tar", inner.getvalue())
PY
  run_scan chain --dir "$dir"
  expect_code 2 "$RC" 'nested binary payload'
  assert_not_contains "$OUT" "$secret" 'nested scan exposed the token'
  pass "fm-record-scan: Gitleaks exclusions cannot hide payloads or credential filenames"
}

test_nested_archives_require_complete_scans() {
  local dir mode
  dir="$TMP_ROOT/nested-preflight"
  mkdir -p "$dir"
  for mode in clean encrypted corrupt depth; do
    python3 - "$dir/outer.tar" "$mode" <<'PY'
import io
import sys
import tarfile
import zipfile
inner = io.BytesIO()
with zipfile.ZipFile(inner, "w", zipfile.ZIP_DEFLATED) as archive:
    archive.writestr("safe.txt", "harmless content")
data = bytearray(inner.getvalue())
if sys.argv[2] == "encrypted":
    data[6] |= 1
    data[data.find(b"PK\x01\x02") + 8] |= 1
elif sys.argv[2] == "corrupt":
    data = data[:10]
elif sys.argv[2] == "depth":
    wrapper = io.BytesIO()
    with zipfile.ZipFile(wrapper, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("inner.zip", data)
    data = wrapper.getvalue()
with tarfile.open(sys.argv[1], "w") as archive:
    entry = tarfile.TarInfo("nested.zip")
    entry.size = len(data)
    archive.addfile(entry, io.BytesIO(data))
PY
    run_scan chain --dir "$dir"
    if [ "$mode" = clean ]; then
      expect_code 0 "$RC" 'clean nested archive'
    else
      expect_code 1 "$RC" "$mode nested archive"
    fi
  done
  pass "fm-record-scan: nested archives must be readable within the scan depth"
}

test_unsupported_archive_formats_refuse() {
  local dir secret variant
  dir="$TMP_ROOT/unsupported-archives"
  secret=$(secret_fixture stripe-test)
  python3 - "$dir" "$secret" <<'PY'
import io
import pathlib
import sys
import tarfile
import zipfile
root = pathlib.Path(sys.argv[1])
for variant, compression, name in (("xz", "xz", "archive.tar.xz"), ("hidden", "xz", "response.bin"),
        ("nested", "xz", "archive.zip"), ("bz2", "bz2", "archive.tar.bz2")):
    directory = root / variant
    directory.mkdir(parents=True)
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode="w:" + compression) as archive:
        payload = sys.argv[2].encode()
        entry = tarfile.TarInfo("response.bin")
        entry.size = len(payload)
        archive.addfile(entry, io.BytesIO(payload))
    if variant == "nested":
        with zipfile.ZipFile(directory / name, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("response.bin", data.getvalue())
    else:
        (directory / name).write_bytes(data.getvalue())
PY
  for variant in xz hidden nested bz2; do
    run_scan chain --dir "$dir/$variant"
    expect_code 1 "$RC" "$variant unsupported archive"
    assert_contains "$OUT" 'unsupported' 'unsupported archive had no named refusal'
    assert_not_contains "$OUT" "$secret" 'unsupported archive exposed its payload'
  done
  pass "fm-record-scan: unsupported archives refuse even under hidden or nested names"
}

test_executable_cleans_only_its_own_stages() {
  local dir temp stage command mode input expected
  dir="$TMP_ROOT/stage-ownership"
  temp="$dir/temp"
  stage="$dir/caller-stage"
  mkdir -p "$dir/tree" "$temp" "$stage"
  for command in tree chain; do
    for mode in clean hit error; do
      input="$dir/tree"
      expected=0
      printf 'clean\n' > "$input/payload.txt"
      case "$mode" in
        hit) secret_fixture github-classic > "$input/payload.txt"; expected=2 ;;
        error) input="$dir/missing"; expected=1 ;;
      esac
      if [ "$command" = tree ]; then
        STAGE= TMPDIR="$temp" run_scan tree "$input"
      else
        STAGE= TMPDIR="$temp" run_scan chain --dir "$input"
      fi
      expect_code "$expected" "$RC" "$command $mode stage cleanup"
      [ -z "$(find "$temp" -mindepth 1 -print)" ] || fail "$command $mode left a scanner temporary"
    done
  done
  printf 'caller-owned\n' > "$stage/marker"
  printf 'clean\n' > "$dir/tree/payload.txt"
  STAGE="$stage" TMPDIR="$temp" run_scan tree "$dir/tree"
  expect_code 0 "$RC" 'caller-owned stage scan'
  [ "$(cat "$stage/marker")" = caller-owned ] || fail 'scanner removed caller-owned files'
  [ -f "$stage/secret-scan-hits" ] || fail 'scanner removed caller-owned scan results'
  pass "fm-record-scan: executable scans remove only their own temporary stages"
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
test_private_key_headers_refuse_in_serialized_text
test_compressed_feeder_patterns_block_the_chain
test_gitleaks_path_exclusions_do_not_hide_payloads
test_nested_archives_require_complete_scans
test_unsupported_archive_formats_refuse
test_executable_cleans_only_its_own_stages
test_chain_clean_tree
