# gw1-scus — NixOS gateway / NVA host (South Central US region)
#
# Host-specific configuration for the Azure NixOS gateway VM.
# Import shared modules from ../../modules/ and add host-specific overrides here.
#
# Deployed via Comin (GitOps pull model):
#   - Comin polls this repo and applies config changes automatically.
#   - Secrets are encrypted with agenix and stored in git.
#   - First-boot bootstrap of Comin is currently performed by deploy-infra
#     (legacy path); the upcoming image-bake workflow will bake Comin into
#     the gallery image so the bootstrap step disappears. See
#     docs/architecture-refactor.md and PR #45.
#
# Comin + agenix wiring lives in ../../modules/comin.nix and
# ../../modules/agenix.nix (imported once in ../../flake.nix). Do not
# duplicate that wiring here — it is intentionally the single swappable
# seam for the GitOps mechanism.

{ config, pkgs, ... }:

{
  imports = [
    ../../modules/base.nix
    ../../modules/tailscale.nix
    ../../modules/networking.nix
    ../../modules/monitoring.nix
  ];

  # ── Hostname ────────────────────────────────────────────────────────
  networking.hostName = "gw1-scus";

  # ── Network interface ───────────────────────────────────────────────
  # TODO: verify the interface name on your Azure VM (typically eth0 or enP...).
  networking.interfaces = {
    # TODO: replace eth0 with the actual interface name if different.
    eth0 = {
      useDHCP = true;
    };
  };

  # ── Tailscale ───────────────────────────────────────────────────────
  # TODO: set your Tailscale auth key as a NixOS secret or via environment.
  # See modules/tailscale.nix for the expected secret path.

  # ── Firewall ────────────────────────────────────────────────────────
  networking.firewall = {
    enable = true;
    # Allow SSH in the gateway subnet.
    # Tailscale UDP port is opened automatically by services.tailscale.openFirewall
    # in modules/tailscale.nix — no need to list it here.
    allowedTCPPorts = [ 22 ];
  };

  # ── Comin token ─────────────────────────────────────────────────────
  # Use the agenix-managed GitHub PAT for Comin authentication.
  # After the first Comin apply, agenix decrypts the secret from the .age
  # file using the VM's SSH host key (injected at provisioning time via
  # cloud-init customData by deploy-workload).
  plaz.comin.tokenPath = "/run/agenix/comin-github-token";

  system.stateVersion = "25.11";
}
