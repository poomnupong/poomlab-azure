# networking.nix — IP forwarding and routing for the NVA role
#
# Enables IPv4/IPv6 forwarding so this VM can act as a network virtual
# appliance (NVA) routing traffic between subnets or to the internet.

{ config, lib, pkgs, ... }:

{
  # ── IP forwarding ────────────────────────────────────────────────────
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
    # Disable reverse path filtering to allow asymmetric routing (NVA pattern)
    "net.ipv4.conf.all.rp_filter" = 0;
    "net.ipv4.conf.default.rp_filter" = 0;
  };

  # ── NAT / masquerade ─────────────────────────────────────────────────
  # TODO: enable masquerade if this VM provides outbound NAT for internal subnets.
  # Replace "eth0" with the actual outbound interface name.
  # networking.nat = {
  #   enable = true;
  #   externalInterface = "eth0";
  #   internalInterfaces = [ "tailscale0" ];
  # };

  # ── Static routes ────────────────────────────────────────────────────
  # TODO: add static routes for any spoke subnets that should be reachable
  # via this NVA. Example:
  # networking.interfaces.eth0.ipv4.routes = [
  #   { address = "10.0.0.0"; prefixLength = 8; via = "192.168.85.1"; }
  # ];
}
