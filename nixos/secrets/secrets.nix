# secrets.nix — Agenix recipients list
#
# AUTO-POPULATED by deploy-workload.yml (Phase 5, Option A).
# Host keys are generated in CI, stored in Key Vault, injected
# via cloud-init customData on VM creation.
# Do not edit key values manually.
#
let
  # ── VM host keys ────────────────────────────────────────────────
  gw1 = "age1ha7pzesrwk4dnezd90gddqr2wtrpepjfupfpcd9rcxdstu2t9svq5vnx37";
  gw2 = "age1yaxt5ug96xc6r3zvp5skeayxru68g62s82qeyg59p47qrtau7c4s27n4xk";
  gw3 = "age140zq5hlxzl4f7vyckq3776y2s6xq7evz8vu98rwrzfcchs9mcfrsdyd2un";

  allSystems = [ gw1 gw2 gw3 ];
in
{
  "comin-github-token.age".publicKeys = allSystems;
  "tailscale-authkey.age".publicKeys = allSystems;
}
