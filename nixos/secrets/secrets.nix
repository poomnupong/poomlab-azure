# secrets.nix — Agenix recipients list
#
# Maps encrypted secret files to the age public keys allowed to decrypt them.
#
# ┌────────────────────────────────────────────────────────────────────┐
# │  This file is AUTO-POPULATED by deploy-infra.yml after the first  │
# │  VM is created. No manual editing needed.                         │
# │                                                                    │
# │  deploy-infra automatically:                                       │
# │    1. Extracts the VM's SSH host key → converts to age public key │
# │    2. Derives admin age key from ADMIN_SSH_PUBLIC_KEY (if ed25519) │
# │    3. Updates this file with the real keys                        │
# │    4. Encrypts secrets (GH_PAT) → .age files                     │
# │    5. Commits and pushes to the repo                              │
# │                                                                    │
# │  To rotate secrets later, see docs/comin-deployment.md.           │
# └────────────────────────────────────────────────────────────────────┘

let
  # ── Admin keys ──────────────────────────────────────────────────────
  # Auto-populated from ADMIN_SSH_PUBLIC_KEY (if ed25519) by deploy-infra.
  # To add manually: cat ~/.ssh/id_ed25519.pub | ssh-to-age
  admin = "age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";

  # ── VM host keys ────────────────────────────────────────────────────
  # Auto-populated by deploy-infra from each VM's SSH host key.
  # To extract manually: ssh-keyscan <vm-ip> 2>/dev/null | ssh-to-age
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
