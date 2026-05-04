# secrets.nix — Agenix recipients list
#
# Maps encrypted secret files to the age public keys allowed to decrypt them.
# Each VM's age public key is derived from its SSH host key:
#
#   ssh-keyscan <vm-ip> 2>/dev/null | ssh-to-age
#
# Your admin age public key can be generated from your SSH key:
#
#   cat ~/.ssh/id_ed25519.pub | ssh-to-age
#
# After adding/changing keys, re-encrypt all secrets:
#
#   cd nixos && agenix -r
#
# See docs/comin-deployment.md for the full workflow.

let
  # ── Admin keys ──────────────────────────────────────────────────────
  # TODO: replace with your actual age public key (derived from SSH key)
  admin = "age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";

  # ── VM host keys ────────────────────────────────────────────────────
  # Derived from each VM's SSH host key via ssh-to-age.
  # Run: ssh-keyscan <vm-ip> 2>/dev/null | ssh-to-age
  # TODO: replace with actual VM age public key after first deploy-infra run
  gw1 = "age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";

  # All systems that need access to shared secrets
  allSystems = [ gw1 ];
  allKeys = [ admin ] ++ allSystems;
in
{
  # ── Comin GitHub PAT ────────────────────────────────────────────────
  # GitHub Personal Access Token used by Comin to pull from this private repo
  # and by the postDeploymentCommand to report commit status / create issues.
  "comin-github-token.age".publicKeys = allKeys;

  # ── Tailscale auth key ─────────────────────────────────────────────
  # Tailscale auth key for automatic VPN enrollment on first boot.
  "tailscale-authkey.age".publicKeys = allKeys;
}
