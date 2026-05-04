# tailscale.nix — Tailscale VPN module
#
# Enables the Tailscale daemon and configures automatic authentication.
# The auth key is managed by agenix — see modules/agenix.nix for the
# secret declaration and nixos/secrets/ for the encrypted file.

{ config, pkgs, pkgs-unstable, ... }:

{
  # ── Tailscale service ────────────────────────────────────────────────
  services.tailscale = {
    enable = true;
    package = pkgs-unstable.tailscale;
    openFirewall = true;
  };

  # ── One-shot auth unit ───────────────────────────────────────────────
  # Authenticate tailscale on first boot using an auth key decrypted by agenix.
  # The key file is provisioned at /run/agenix/tailscale-authkey by agenix.
  systemd.services.tailscale-autoconnect = {
    description = "Tailscale auto-connect on first boot";
    after = [ "network-online.target" "tailscale.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      # Skip if already authenticated
      status="$(${pkgs-unstable.tailscale}/bin/tailscale status --json | ${pkgs.jq}/bin/jq -r .BackendState)"
      if [ "$status" = "Running" ]; then
        echo "Tailscale already running, skipping auth."
        exit 0
      fi

      # Agenix decrypts the auth key to /run/agenix/tailscale-authkey
      AUTH_KEY_FILE="/run/agenix/tailscale-authkey"
      if [ ! -f "$AUTH_KEY_FILE" ]; then
        echo "No Tailscale auth key file found at $AUTH_KEY_FILE, skipping."
        exit 0
      fi

      ${pkgs-unstable.tailscale}/bin/tailscale up \
        --authkey "$(cat "$AUTH_KEY_FILE")" \
        --accept-routes \
        --advertise-exit-node=false
    '';
  };
}
