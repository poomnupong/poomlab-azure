# secrets.nix — Agenix recipients list
#
# AUTO-POPULATED by deploy-infra.yml — do not edit the key values manually.
# To rotate secrets, see docs/comin-deployment.md.
#
# VM keys extracted from SSH host keys via az vm run-command + ssh-to-age.
# The VM's SSH host key is the only recipient — agenix decrypts on the VM
# using /etc/ssh/ssh_host_ed25519_key (the private half of this key).

let
  # ── VM host keys ────────────────────────────────────────────────
  gw1 = "age1802l3yqtg3een7ewpt9sse8nhnp2d2lxjf4uc5974n0j4lzv69asntxfla";

  allSystems = [ gw1 ];
in
{
  "comin-github-token.age".publicKeys = allSystems;
  "tailscale-authkey.age".publicKeys = allSystems;
}
