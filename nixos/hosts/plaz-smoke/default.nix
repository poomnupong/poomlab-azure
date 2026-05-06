# plaz-smoke — ephemeral smoke-test host (Tier 2 image-bake CI gate)
#
# This host is never deployed to production. It exists solely so that
# nixosConfigurations.plaz-smoke is a valid target for Comin to apply
# during the Tier 2 smoke test in .github/workflows/image-bake.yml.
#
# The smoke VM is provisioned from the freshly baked gallery image,
# booted with --computer-name plaz-smoke, and destroyed after the test.
# Comin fetches main, finds this configuration, applies it, and the
# generation counter incrementing is the pass signal.

{ ... }:

{
  # ── Hostname ────────────────────────────────────────────────────────
  # Must match --computer-name plaz-smoke used in image-bake.yml smoke-tier2.
  networking.hostName = "plaz-smoke";

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
  };

  # ── Azure Linux Agent (waagent) ──────────────────────────────────────
  # Mirrors hosts/gw1/hardware.nix:58-63. The baked image ships with
  # waagent enabled, but `nixos-rebuild switch` to a config that doesn't
  # re-declare it disables the unit — which kills run-command, the
  # transport the smoke gate uses for generation polling. Without this
  # the gate races waagent's death the moment Comin applies generation 2.
  services.waagent.enable = true;
}
