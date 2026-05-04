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
  gw1 = "age1fcvee7uadn9pyd0y8n0tdtle05gkjxx3za8lvw6t5j74anhxgsrsd435y2";

  allSystems = [ gw1 ];
in
{
  "comin-github-token.age".publicKeys = allSystems;
  "tailscale-authkey.age".publicKeys = allSystems;
}
