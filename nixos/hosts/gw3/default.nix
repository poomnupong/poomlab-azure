# gw3 — NixOS gateway / NVA host (Japan East region)
#
# Host-specific configuration for the Azure NixOS gateway VM in japaneast.
# Mirrors gw1/gw2 with a different hostname. Import shared modules from
# ../../modules/ and add host-specific overrides here.
#
# Deployed via Comin (GitOps pull model):
#   - Comin polls this repo and applies config changes automatically.
#   - Secrets are encrypted with agenix and stored in git.

{ config, pkgs, ... }:

{
  imports = [
    ../../modules/base.nix
    ../../modules/tailscale.nix
    ../../modules/networking.nix
    ../../modules/monitoring.nix
  ];

  # ── Hostname ────────────────────────────────────────────────────────
  networking.hostName = "gw3";

  # ── Network interface ───────────────────────────────────────────────
  networking.interfaces = {
    eth0 = {
      useDHCP = true;
    };
  };

  # ── Firewall ────────────────────────────────────────────────────────
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
  };

  # ── Comin token ─────────────────────────────────────────────────────
  # Use the agenix-managed GitHub PAT for Comin authentication.
  plaz.comin.tokenPath = "/run/agenix/comin-github-token";

  system.stateVersion = "25.11";
}
