#!/bin/sh
# Thin curl wrapper for the Compositor automation API (docs/automation-api.md).
#
#   compositor-api.sh health
#   compositor-api.sh ops
#   compositor-api.sh state [project]
#   compositor-api.sh run '{"op": "layer.add", "name": "Grade"}'
#   compositor-api.sh run @script.json            # a {"steps": [...]} file
#   compositor-api.sh render out.png [layer]
#
# COMPOSITOR_URL (default http://127.0.0.1:4747) and COMPOSITOR_TOKEN are honored.

set -eu
base="${COMPOSITOR_URL:-http://127.0.0.1:4747}"
auth=""
if [ -n "${COMPOSITOR_TOKEN:-}" ]; then auth="-H \"Authorization: Bearer $COMPOSITOR_TOKEN\""; fi

case "${1:-}" in
  health) eval curl -sS "$auth" "$base/v1/health" ;;
  ops) eval curl -sS "$auth" "$base/v1/ops" ;;
  state) eval curl -sS "$auth" "\"$base/v1/state?project=${2:-}\"" ;;
  run)
    body="${2:?json body or @file}"
    if [ "${body#@}" != "$body" ]; then
      eval curl -sS "$auth" -H '"Content-Type: application/json"' --data-binary "\"$body\"" "$base/v1/run"
    else
      eval curl -sS "$auth" -H '"Content-Type: application/json"' --data-binary "'$body'" "$base/v1/run"
    fi
    ;;
  render)
    out="${2:?output file}"
    eval curl -sS "$auth" -o "\"$out\"" "\"$base/v1/render?format=${out##*.}&layer=${3:-}\""
    echo "$out"
    ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
echo
