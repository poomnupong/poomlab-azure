# tailscale.nix — Tailscale VPN module
#
# Enables the Tailscale daemon and configures automatic authentication.
# Set the auth key via a NixOS secret or an environment-specific override.

{ config, pkgs, ... }:

{
  # ── Tailscale service ────────────────────────────────────────────────
  services.tailscale = {
    enable = true;
    # TODO: set openFirewall = true if you want NixOS to manage the firewall
    # rule for Tailscale UDP port 41641 automatically.
    openFirewall = true;
  };

  # ── One-shot auth unit ───────────────────────────────────────────────
  # Authenticate tailscale on first boot using an auth key stored as a secret.
  # TODO: provision the auth key via a secrets manager (e.g. agenix, sops-nix)
  # and adjust the path below. The key file should contain only the raw auth key.
  systemd.services.tailscale-autoconnect = {
    description = "Tailscale auto-connect on first boot";
    after = [ "network-online.target" "tailscale.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      # Skip if already authenticated
      status="$(${pkgs.tailscale}/bin/tailscale status --json | ${pkgs.jq}/bin/jq -r .BackendState)"
      if [ "$status" = "Running" ]; then
        echo "Tailscale already running, skipping auth."
        exit 0
      fi

      # TODO: replace /run/secrets/tailscale-authkey with your actual secrets path.
      AUTH_KEY_FILE="/run/secrets/tailscale-authkey"
      if [ ! -f "$AUTH_KEY_FILE" ]; then
        echo "No Tailscale auth key file found at $AUTH_KEY_FILE, skipping."
        exit 0
      fi

      ${pkgs.tailscale}/bin/tailscale up \
        --authkey "$(cat "$AUTH_KEY_FILE")" \
        --accept-routes \
        --advertise-exit-node=false
    '';
  };
}
