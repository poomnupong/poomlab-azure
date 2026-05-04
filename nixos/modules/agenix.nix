# agenix.nix — Encrypted secrets management
#
# Declares all agenix-managed secrets and their decrypt paths.
# Encrypted .age files live in nixos/secrets/ and are committed to git.
# Decryption happens on each VM using its SSH host key (converted to age).
#
# Workflow:
#   1. Edit secret:   cd nixos && agenix -e secrets/<name>.age
#   2. Commit & push:  git add secrets/<name>.age && git commit && git push
#   3. Comin pulls the new commit and agenix decrypts on the VM automatically.
#
# See docs/comin-deployment.md for the full rotation workflow.

{ config, ... }:

{
  # ── Secret declarations ─────────────────────────────────────────────
  # Each entry maps a .age file to a runtime path on the VM.
  # The decrypted file is placed at /run/agenix/<name> by default.

  age.secrets = {
    # GitHub PAT for Comin (repo pull + commit status API + issue creation)
    comin-github-token = {
      file = ../secrets/comin-github-token.age;
      mode = "0400";
      owner = "root";
    };

    # Tailscale auth key for automatic VPN enrollment
    tailscale-authkey = {
      file = ../secrets/tailscale-authkey.age;
      mode = "0400";
      owner = "root";
    };
  };
}
