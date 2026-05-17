# secrets.nix — Agenix recipients list
#
# AUTO-POPULATED by deploy-workload.yml (Phase 5, Option A).
# Host keys are generated in CI, stored in Key Vault, injected
# via cloud-init customData on VM creation.
# Do not edit key values manually.
#
let
  # ── VM host keys ────────────────────────────────────────────────
  gw1-krc = "age1m5ttjtdks4r0pq3l8m8mljl9xwvl9quy74es5xruq3nhp9qup3vqaul0jd";
  gw1-scus = "age1tf75lymgsqgk5ad8wtwengwz93w96858fm3rtg8udk36nu8dmgsspqejez";
  gw1-sea = "age1rtm853kvt5ameul2zawx2cv0eh348vq9wrmeu38j2n4v0k63258qks88gz";

  allSystems = [ gw1-krc gw1-scus gw1-sea ];
in
{
  "comin-github-token.age".publicKeys = allSystems;
  "tailscale-authkey.age".publicKeys = allSystems;
}
