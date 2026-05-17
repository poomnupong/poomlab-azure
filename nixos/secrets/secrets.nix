# secrets.nix — Agenix recipients list
#
# AUTO-POPULATED by deploy-workload.yml (Phase 5, Option A).
# Host keys are generated in CI, stored in Key Vault, injected
# via cloud-init customData on VM creation.
# Do not edit key values manually.
#
let
  # ── VM host keys ────────────────────────────────────────────────
  gw1-scus = "age1uzw473a7jpn2l8nxhtgg6dep2537s38eg2tx9fxelgn2jyccgg3srz3xe0";
  gw1-sea = "age1yaxt5ug96xc6r3zvp5skeayxru68g62s82qeyg59p47qrtau7c4s27n4xk";
  gw1-krc = "age1w9fjs4etqd954cu6e468t4zekyr58avgz5t4eylwseuq29cqzefsedpgap";

  allSystems = [ gw1-krc gw1-scus gw1-sea ];
in
{
  "comin-github-token.age".publicKeys = allSystems;
  "tailscale-authkey.age".publicKeys = allSystems;
}
