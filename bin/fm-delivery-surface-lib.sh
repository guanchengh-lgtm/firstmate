#!/usr/bin/env bash
# fm-delivery-surface-lib.sh - ship-surface closed set and the direct-PR refuse.
#
# Sourced by bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh.
# This is the one owner of the product-quality gate: --mode direct-PR is legal
# only with --surface internal-only. Product-facing, mixed, and uncertain ships
# cannot use the no-verifier direct-PR path, even when the caller passes an
# explicit --mode. An omitted surface is uncertain and is refused.
# --mode no-mistakes and --mode local-only accept any valid surface or none.
# yolo is orthogonal and is not read here.
#
# Surfaces: internal-only | product | mixed | uncertain
# No side effects on source. set -u / set -e safe.

fm_delivery_assert_surface_value() {
  case "$1" in
    internal-only|product|mixed|uncertain) return 0 ;;
    *)
      echo "error: --surface must be one of internal-only, product, mixed, uncertain (got '$1')" >&2
      return 1
      ;;
  esac
}

fm_delivery_assert_direct_pr_surface() {
  local mode=$1 surface=$2 surface_set=${3:-0}
  case "$mode" in
    direct-PR) ;;
    *) return 0 ;;
  esac
  if [ "$surface_set" -eq 0 ] || [ -z "$surface" ]; then
    echo "error: --mode direct-PR requires --surface internal-only; product, mixed, or uncertain work must ship no-mistakes" >&2
    return 1
  fi
  case "$surface" in
    internal-only) return 0 ;;
    product|mixed|uncertain)
      echo "error: --mode direct-PR is refused for $surface work; only internal-only tooling, automation, operator process, or release submission may use direct-PR" >&2
      return 1
      ;;
    *)
      echo "error: --surface must be one of internal-only, product, mixed, uncertain (got '$surface')" >&2
      return 1
      ;;
  esac
}
