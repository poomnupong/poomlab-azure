# secrets.nix — Agenix recipients list
#
# AUTO-POPULATED by deploy-workload.yml (Phase 5, Option A).
# Host keys are generated in CI, stored in Key Vault, injected
# via cloud-init customData on VM creation.
# Do not edit key values manually.
#
let
  # ── VM host keys ────────────────────────────────────────────────
  gw1-scus = "age1tf75lymgsqgk5ad8wtwengwz93w96858fm3rtg8udk36nu8dmgsspqejez";

  # Existing ciphertext needs separate re-encryption to revoke retired recipients.
  allSystems = [ gw1-scus ];
in
{
  "comin-github-token.age".publicKeys = allSystems;
  "tailscale-authkey.age".publicKeys = allSystems;
}
