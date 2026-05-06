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
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
  };
}
