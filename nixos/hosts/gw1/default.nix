# gw1 — NixOS gateway / NVA host
#
# Host-specific configuration for the Azure NixOS gateway VM.
# Import shared modules from ../../modules/ and add host-specific overrides here.

{ config, pkgs, ... }:

{
  imports = [
    ../../modules/base.nix
    ../../modules/tailscale.nix
    ../../modules/networking.nix
    ../../modules/monitoring.nix
  ];

  # ── Hostname ────────────────────────────────────────────────────────
  networking.hostName = "gw1";

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

  system.stateVersion = "24.11";
}
