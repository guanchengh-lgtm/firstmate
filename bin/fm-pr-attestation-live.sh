#!/usr/bin/env bash
# Read the live pull request for the no-mistakes signature gate.
# Usage: fm-pr-attestation-live.sh --repo <owner/name> --pr <number> --output <file> [--timeout-seconds <n>] [--interval-seconds <n>]
set -u

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  cat <<'HELP'
usage: fm-pr-attestation-live.sh --repo <owner/name> --pr <number> --output <file> [--timeout-seconds <n>] [--interval-seconds <n>]
no-mistakes pushes a new head first and edits the pull request body to attest that head second.
The synchronize event therefore carries a frozen body that still attests the previous head, so a gate that judges the event payload fails on every pipeline fix push, and a rerun replays the same stale payload.
This script reads the live pull request through `gh api` and polls until the body attests the live head or the timeout passes (default 180 seconds, polled every 10 seconds).
--interval-seconds must be at least 1 second, because a zero interval spins on the GitHub API for the whole timeout.
It writes head_sha, attested_sha, converged, and body to <file> in GITHUB_OUTPUT form and never judges the attestation itself.
The pinned gate action judges those live values, so a push that is never re-attested still fails once the timeout passes.
Exit 0 when the live pull request was read, 1 when every `gh api` attempt failed, 2 on a usage error.
HELP
  exit 0
fi

REPO=""
PR=""
OUT=""
TIMEOUT=180
INTERVAL=10
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo|--pr|--output|--timeout-seconds|--interval-seconds)
      [ "$#" -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }
      ;;
  esac
  case "$1" in
    --repo) REPO=$2; shift 2 ;;
    --pr) PR=$2; shift 2 ;;
    --output) OUT=$2; shift 2 ;;
    --timeout-seconds) TIMEOUT=$2; shift 2 ;;
    --interval-seconds) INTERVAL=$2; shift 2 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$REPO" in */*) ;; *) echo "error: --repo must be <owner/name>" >&2; exit 2 ;; esac
case "$PR" in ''|*[!0-9]*) echo "error: --pr must be a number" >&2; exit 2 ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) echo "error: --timeout-seconds must be a number" >&2; exit 2 ;; esac
case "$INTERVAL" in ''|*[!0-9]*|0) echo "error: --interval-seconds must be a positive number of seconds" >&2; exit 2 ;; esac
[ -n "$OUT" ] || { echo "error: --output is required" >&2; exit 2; }

attested_head() {  # <body>
  printf '%s\n' "$1" \
    | grep -oE 'no-mistakes-pipeline-attestation:v1[^>]*' \
    | grep -oE '"head_sha"[[:space:]]*:[[:space:]]*"[0-9a-f]{40}"' \
    | grep -oE '[0-9a-f]{40}' \
    | head -n 1
}

read_ok=0
head=""
attested=""
body=""
converged=false
SECONDS=0
while :; do
  if json=$(gh api "repos/$REPO/pulls/$PR" 2>/dev/null); then
    read_ok=1
    head=$(printf '%s' "$json" | jq -r '.head.sha // ""')
    body=$(printf '%s' "$json" | jq -r '.body // ""')
    attested=$(attested_head "$body")
    if [ -n "$head" ] && [ "$attested" = "$head" ]; then
      converged=true
      break
    fi
  fi
  [ "$SECONDS" -lt "$TIMEOUT" ] || break
  sleep "$INTERVAL"
done

if [ "$read_ok" -ne 1 ]; then
  echo "error: could not read pull request $REPO#$PR through gh api within ${TIMEOUT}s" >&2
  exit 1
fi

delim="fm-pr-body-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
{
  printf 'head_sha=%s\n' "$head"
  printf 'attested_sha=%s\n' "$attested"
  printf 'converged=%s\n' "$converged"
  printf 'body<<%s\n%s\n%s\n' "$delim" "$body" "$delim"
} >> "$OUT"
printf 'live pull request %s#%s head %s attested %s converged %s after %ss\n' \
  "$REPO" "$PR" "${head:-none}" "${attested:-none}" "$converged" "$SECONDS"
