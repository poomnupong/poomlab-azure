# secrets.nix — Agenix recipients list
#
# AUTO-POPULATED by deploy-workload.yml (Phase 5, Option A).
# Host key is generated in CI, stored in Key Vault, injected
# via cloud-init customData on VM creation.
# Do not edit key values manually.
#
let
  # ── VM host keys ────────────────────────────────────────────────
  gw1 = "age1rkh86t00gnp86yqkk6rhrar9s8vq5vejgegslhxzccjrwl3ceqxqq8a79a";

  allSystems = [ gw1 ];
in
{
  "comin-github-token.age".publicKeys = allSystems;
  "tailscale-authkey.age".publicKeys = allSystems;
}
