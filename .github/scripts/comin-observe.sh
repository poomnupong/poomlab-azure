#!/bin/sh
# Read-only, bounded observation for comin-status.py. No credentials or journal
# contents are emitted. Keep the framed response below Azure's 4 KiB tail limit.
export PATH="/run/current-system/sw/bin:/run/current-system/sw/sbin:$PATH"
set -eu

service=$(timeout 10 systemctl show comin.service \
  --property=LoadState,ActiveState,SubState,Result)
service=$(printf '%s\n' "$service" | jq -Rsc '
  split("\n") | map(select(length > 0) | split("=") | {(.[0]): .[1]}) | add
  | {load: .LoadState, active: .ActiveState, sub: .SubState, result: .Result}')
host=$(hostname)
version=$(nixos-version)
current=$(readlink -f /run/current-system)
profile=/nix/var/nix/profiles/system-profiles/comin
count=0
if [ -e "$profile" ] || [ -L "$profile" ]; then
  generations=$(timeout 10 nix-env --list-generations --profile "$profile")
  count=$(printf '%s\n' "$generations" | awk '/^[[:space:]]*[0-9]+[[:space:]]/ {n++} END {print n+0}')
fi

state=null
observation_error=""
if [ "$(printf '%s' "$service" | jq -r .active)" = active ]; then
  if raw_state=$(timeout 15 comin status --json 2>/dev/null); then
    # cmd/status.go uses proto field names. Fetch errors describe the *latest*
    # attempt; fetched_at advances on failures too. A lifetime success counter
    # or old journal error cannot tell us the current authenticated fetch state.
    if ! state=$(printf '%s' "$raw_state" | jq -ce '
      def has_error:
        if type != "string" then error("invalid error field") else length > 0 end;
      def fetch_error:
        if type != "string" then error("invalid fetch error")
        elif . == "" then "none"
        elif test("authentication required|authentication failed|authorization failed|invalid credentials|invalid username or password|status code:? (401|403)|HTTP (401|403)"; "i")
        then "authentication" else "other" end;
      .fetcher.repository_status as $repo |
      {
        suspended: .is_suspended,
        fetching: .fetcher.is_fetching,
        repository_error: ($repo.error_msg | has_error),
        selected_commit: $repo.selected_commit_id,
        selected_remote: $repo.selected_remote_name,
        signature_required: $repo.selected_commit_should_be_signed,
        signature_valid: $repo.selected_commit_signed,
        remote: ([$repo.remotes[] | select(.name == "origin") | {
          name, fetched_at, fetched, error: (.fetch_error_msg | fetch_error),
          branch_error: (.main.error_msg | has_error)
        }] | if length == 0 then null elif length == 1 then .[0] else error("duplicate origin") end),
        builder: (.builder | {
          evaluating: .is_evaluating, building: .is_building, suspended: .is_suspended,
          generation: (.generation | if . == null then null else {
            commit: .selected_commit_id, eval_status, build_status,
            eval_error: (.eval_err | has_error), build_error: (.build_err | has_error)
          } end)
        }),
        deployer: (.deployer | {
          deploying: .is_deploying, suspended: .is_suspended,
          pending: (.generation_to_deploy != null),
          deployment: (.deployment | if . == null then null else {
            status, operation, ended_at, error: (.error_msg | has_error),
            commit: .generation.selected_commit_id, out_path: .generation.out_path
          } end)
        })
      }' 2>/dev/null); then
      state=null
      observation_error=status_invalid
    fi
  else
    observation_error=status_unavailable
  fi
fi

payload=$(jq -cn \
  --argjson observed_at "$(date +%s)" --argjson service "$service" \
  --arg hostname "$host" --arg nixos_version "$version" \
  --arg current_system "$current" --argjson generation_count "$count" \
  --arg observation_error "$observation_error" --argjson state "$state" \
  '{observed_at: $observed_at, service: $service, hostname: $hostname,
    nixos_version: $nixos_version, current_system: $current_system,
    generation_count: $generation_count, observation_error: $observation_error,
    state: $state}')
if [ "${#payload}" -gt 3500 ]; then
  echo "Comin observation exceeds the bounded protocol size" >&2
  exit 1
fi
printf 'COMIN_OBSERVATION_V1\n%s\nCOMIN_OBSERVATION_END\n' "$payload"
