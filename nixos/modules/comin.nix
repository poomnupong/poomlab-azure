# comin.nix — GitOps pull-based deployment via Comin
#
# Comin polls this GitHub repo and runs nixos-rebuild switch automatically.
# After each deployment, the postDeploymentCommand reports status back to
# GitHub (commit status on success, issue on failure) — keeping all
# operations visible in git.
#
# Required secret: comin-github-token (agenix-managed GitHub PAT)
#   - Scoped to this repo with Contents (R/W), Pull requests (R/W),
#     and Commit statuses (R/W) permissions.
#
# See docs/comin-deployment.md for the full runtime architecture.
#
# ── Architectural role (refactor in progress) ───────────────────────────
# This module is the single, swappable "GitOps mechanism" seam called out in
# the workflow/image refactor (see docs/architecture-refactor.md, D3 + D4 +
# Phase 2; tracking PR #45 — https://github.com/poomnupong/poomlab-azure/pull/45).
#
# What that means for agents touching this file:
#   - Comin + agenix wiring lives ONLY here (and modules/agenix.nix). Do not
#     re-introduce Comin config into host modules (nixos/hosts/<host>/*).
#   - Anything baked into the gallery image by the future `image-bake`
#     workflow (Phase 3) will be exactly this module + modules/agenix.nix.
#     Keep this module self-contained and side-effect-free at evaluation
#     time so it's safe to evaluate offline against a fixture flake.
#   - If Comin is ever swapped for deploy-rs / Colmena / similar, the swap
#     is intended to be: replace this module, replace the matching workflow
#     step, done. Do not couple anything host-specific in here.

{ config, pkgs, lib, ... }:

let
  # ── Post-deployment callback script ─────────────────────────────────
  # Called by Comin after each deployment with env vars:
  #   COMIN_GIT_SHA, COMIN_GIT_REF, COMIN_GIT_MSG,
  #   COMIN_HOSTNAME, COMIN_FLAKE_URL, COMIN_GENERATION,
  #   COMIN_STATUS, COMIN_ERROR_MSG
  reportStatusScript = pkgs.writeShellScript "comin-report-status" ''
    set -euo pipefail

    REPO="poomnupong/poomlab-azure"
    TOKEN_FILE="/run/agenix/comin-github-token"

    # If no token file, skip reporting (bootstrap phase)
    if [ ! -f "$TOKEN_FILE" ]; then
      echo "comin-report-status: no token file at $TOKEN_FILE, skipping."
      exit 0
    fi

    TOKEN=$(cat "$TOKEN_FILE")
    SHA="''${COMIN_GIT_SHA:-}"
    STATUS="''${COMIN_STATUS:-}"
    HOSTNAME="''${COMIN_HOSTNAME:-unknown}"
    ERROR_MSG="''${COMIN_ERROR_MSG:-}"

    if [ -z "$SHA" ]; then
      echo "comin-report-status: COMIN_GIT_SHA is empty, skipping."
      exit 0
    fi

    # ── Report commit status ───────────────────────────────────────────
    if [ "$STATUS" = "done" ]; then
      GH_STATE="success"
      DESCRIPTION="NixOS config applied successfully on $HOSTNAME"
    else
      GH_STATE="failure"
      DESCRIPTION="NixOS deployment failed on $HOSTNAME"
    fi

    ${pkgs.curl}/bin/curl -sS --fail-with-body \
      -X POST \
      -H "Authorization: token $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/$REPO/statuses/$SHA" \
      -d "$(${pkgs.jq}/bin/jq -n \
        --arg state "$GH_STATE" \
        --arg context "comin/$HOSTNAME" \
        --arg description "$DESCRIPTION" \
        '{state: $state, context: $context, description: $description}')" \
      2>&1 || echo "comin-report-status: failed to post commit status (HTTP error)"

    # ── On failure, also create a GitHub issue ─────────────────────────
    if [ "$GH_STATE" = "failure" ]; then
      SHORT_SHA="''${SHA:0:7}"
      JOURNAL=$(${pkgs.systemd}/bin/journalctl -u comin --since "30 minutes ago" --no-pager 2>/dev/null | tail -100 || echo "Could not retrieve journal logs")

      ISSUE_BODY=$(cat <<EOF
    ## Comin deployment failed on \`$HOSTNAME\`

    | Field | Value |
    |-------|-------|
    | **Commit** | [$SHORT_SHA](https://github.com/$REPO/commit/$SHA) |
    | **Hostname** | $HOSTNAME |
    | **Status** | $STATUS |
    | **Error** | $ERROR_MSG |

    ### Recent comin journal logs

    \`\`\`
    $JOURNAL
    \`\`\`
    EOF
      )

      ${pkgs.curl}/bin/curl -sS --fail-with-body \
        -X POST \
        -H "Authorization: token $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$REPO/issues" \
        -d "$(${pkgs.jq}/bin/jq -n \
          --arg title "🔴 Comin deploy failed on $HOSTNAME — $SHORT_SHA" \
          --arg body "$ISSUE_BODY" \
          '{title: $title, body: $body, labels: ["deploy-failure", "automated"]}')" \
        2>&1 || echo "comin-report-status: failed to create issue (HTTP error)"
    fi
  '';
in
{
  # ── Comin service ───────────────────────────────────────────────────
  services.comin = {
    enable = true;

    # The flake lives in nixos/ subdirectory, not repo root
    repositorySubdir = "nixos";

    # Report deployment status back to GitHub after each deploy
    postDeploymentCommand = reportStatusScript;

    remotes = [
      {
        name = "origin";
        url = "https://github.com/poomnupong/poomlab-azure.git";
        branches.main.name = "main";
        # Poll every 60 seconds (default)
        poller.period = 60;
        # Authenticate with GitHub PAT for private repo access
        auth.access_token_path = "/run/agenix/comin-github-token";
      }
    ];

    # Prometheus metrics exporter for Comin
    exporter = {
      listen_address = "127.0.0.1";
      port = 4243;
    };
  };
}
