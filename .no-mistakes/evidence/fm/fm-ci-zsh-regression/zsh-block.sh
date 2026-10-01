# Linux lanes have no zsh, so the zsh contract case skips there; macOS
# ships /bin/zsh. Three ok lines means both zsh cases ran, two means skipped.
command -v zsh >/dev/null || { echo "::error::zsh is required for the shell-portable backend regression"; exit 1; }
zsh_output=$(FM_TEST_ONLY=test_backend_source_shell_portable \
  FM_TEST_BASH=/bin/bash \
  /bin/bash tests/fm-backend.test.sh)
printf '%s\n' "$zsh_output"
zsh_count=$(printf '%s\n' "$zsh_output" | grep -c '^ok - ')
[ "$zsh_count" -eq 3 ] || {
  echo "::error::expected 3 shell-portable backend regressions (2 zsh, 1 bash), got $zsh_count"
  exit 1
}
