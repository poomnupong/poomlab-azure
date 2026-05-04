#!/usr/bin/env bash
# az-run-command.sh — Run a script on an Azure VM via
# `az vm run-command invoke` and surface the remote stdout/stderr/status
# reliably.
#
# Why this wrapper exists:
#   * `az vm run-command invoke` always exits 0 even when the remote
#     script fails, so failures must be detected by parsing the JSON.
#   * The JSON output embeds remote stdout and stderr inside
#     `value[0].message` between literal `[stdout]` / `[stderr]` markers
#     under code `ProvisioningState/succeeded`. It does NOT expose them
#     as separate `ComponentStatus/StdOut/...` entries (that format is
#     used by the newer `az vm run-command create/show` resource API).
#     A jq filter like `select(.code | test("StdOut"))` matches nothing
#     here and silently produces empty output, which is what masked the
#     real failure mode in deploy-infra runs prior to this script.
#
# Usage:
#   az-run-command.sh <resource-group> <vm-name> <script> [extra az args...]
#
# I/O contract:
#   * Writes the remote command's stdout to local stdout (fd 1).
#   * Writes diagnostics to local stderr (fd 2): the extension status
#     line (e.g. "Enable succeeded:" / "Enable failed: ...") and the
#     remote stderr section. The remote stdout section is NEVER echoed
#     to fd 2, so callers can safely capture sensitive output (host
#     keys, tokens) via `> file` without leaking it into Actions logs.
#   * Exits 0 iff Azure reports the run command provisioning succeeded
#     AND the status line does not begin with `Enable failed`.
#   * Note: `az vm run-command invoke` does not surface the remote
#     script's exit code, so callers must still validate the captured
#     stdout (e.g. `grep` for an explicit success marker).

set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: $0 <resource-group> <vm-name> <script> [extra az args...]" >&2
  exit 2
fi

RG=$1
VM_NAME=$2
SCRIPT=$3
shift 3

OUTPUT=$(az vm run-command invoke \
  --resource-group "$RG" \
  --name "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "$SCRIPT" \
  "$@" \
  --output json)

CODE=$(printf '%s' "$OUTPUT" | jq -r '.value[0].code // empty')
MESSAGE=$(printf '%s' "$OUTPUT" | jq -r '.value[0].message // empty')

if [ -z "$MESSAGE" ]; then
  {
    echo "::error::az vm run-command invoke returned no message field. Raw output:"
    echo "$OUTPUT"
  } >&2
  exit 1
fi

# Split MESSAGE at the FIRST `[stdout]` and FIRST subsequent `[stderr]`
# delimiter only. The remote command itself may legitimately print a
# line like `[stdout]` or `[stderr]`, so toggling sections on every
# match would mis-route or drop output.
#
# Layout produced by the run-command extension:
#   <status prefix line(s), e.g. "Enable succeeded:" or "Enable failed: ...">
#   [stdout]
#   <remote stdout lines...>
#   [stderr]
#   <remote stderr lines...>
TMPDIR_PARSE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_PARSE"' EXIT
printf '%s\n' "$MESSAGE" | awk -v out="$TMPDIR_PARSE" '
  BEGIN { section="prefix" }
  section == "prefix" && /^\[stdout\]$/ { section="out"; next }
  section == "out"    && /^\[stderr\]$/ { section="err"; next }
  { print > (out "/" section) }
'
STATUS_LINE=$(head -n 1 "$TMPDIR_PARSE/prefix" 2>/dev/null || true)
REMOTE_STDERR=$(cat "$TMPDIR_PARSE/err" 2>/dev/null || true)

# Log diagnostics to fd 2. Deliberately do NOT echo the raw message or
# the remote stdout — the caller may be capturing stdout that contains
# sensitive data (e.g. host keys, tokens). Surface only the extension
# status line and remote stderr.
{
  echo "--- az vm run-command invoke (vm=$VM_NAME, code=$CODE) ---"
  echo "[status] $STATUS_LINE"
  echo "[remote stderr]"
  if [ -n "$REMOTE_STDERR" ]; then
    echo "$REMOTE_STDERR"
  else
    echo "(empty)"
  fi
  echo "--- end ---"
} >&2

# Detect extension-level failure. `az vm run-command invoke` keeps
# `code=ProvisioningState/succeeded` even when the user script exits
# non-zero, but the message is prefixed `Enable failed:` when the
# extension itself fails. Combine both signals.
if printf '%s' "$CODE" | grep -qi 'failed' \
   || printf '%s' "$STATUS_LINE" | grep -q '^Enable failed'; then
  echo "::error::Remote command failed on $VM_NAME (code=$CODE)" >&2
  exit 1
fi

# Stream remote stdout to fd 1 for the caller. Use cat to preserve
# trailing newlines / absence thereof exactly as the remote produced.
if [ -f "$TMPDIR_PARSE/out" ]; then
  cat "$TMPDIR_PARSE/out"
fi
