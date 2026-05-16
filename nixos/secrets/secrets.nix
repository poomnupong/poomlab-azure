# secrets.nix — Agenix recipients list
#
# AUTO-POPULATED by deploy-workload.yml (Phase 5, Option A).
# Host keys are generated in CI, stored in Key Vault, injected
# via cloud-init customData on VM creation.
# Do not edit key values manually.
#
let
  # ── VM host keys ────────────────────────────────────────────────
  gw1 = "age1z9agtp63vyme64qqglykw95mky5c4ayhq08qmqv83tx0ahvs2srqjy084u";
  gw2 = "age1yaxt5ug96xc6r3zvp5skeayxru68g62s82qeyg59p47qrtau7c4s27n4xk";

  allSystems = [ gw1 gw2 ];
in
{
  "comin-github-token.age".publicKeys = allSystems;
  "tailscale-authkey.age".publicKeys = allSystems;
}
