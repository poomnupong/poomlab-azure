# secrets.nix — Agenix recipients list
#
# AUTO-POPULATED by deploy-workload.yml (Phase 5, Option A).
# Host keys are generated in CI, stored in Key Vault, injected
# via cloud-init customData on VM creation.
# Do not edit key values manually.
#
let
  # ── VM host keys ────────────────────────────────────────────────
  gw1-krc = "age1w9fjs4etqd954cu6e468t4zekyr58avgz5t4eylwseuq29cqzefsedpgap";
  gw1-scus = "age177j87hyj5xr78lqg9pmvfeqvqnjnuvy54ep6wh0gzlxsmd20fstslcnrcq";
  gw1-sea = "age1yaxt5ug96xc6r3zvp5skeayxru68g62s82qeyg59p47qrtau7c4s27n4xk";

  allSystems = [ gw1-krc gw1-scus gw1-sea ];
in
{
  "comin-github-token.age".publicKeys = allSystems;
  "tailscale-authkey.age".publicKeys = allSystems;
}
