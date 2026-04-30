# base.nix — Common base configuration applied to all hosts
#
# Includes: admin user, SSH authorized keys, Nix daemon settings,
# locale, timezone, and basic packages.

{ config, pkgs, ... }:

{
  # ── Nix settings ────────────────────────────────────────────────────
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  # ── System packages ─────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    htop
    jq
  ];

  # ── Locale / Timezone ────────────────────────────────────────────────
  # TODO: adjust timezone to match your Azure region / preference.
  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # ── Admin user ───────────────────────────────────────────────────────
  users.users.azureuser = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    # TODO: replace with the actual SSH public key for the admin user.
    # This should match the ADMIN_SSH_PUBLIC_KEY secret set in GitHub Actions.
    openssh.authorizedKeys.keys = [
      # "ssh-ed25519 AAAA... your-key-comment"
    ];
  };

  # ── SSH daemon ───────────────────────────────────────────────────────
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
      X11Forwarding = false;
    };
  };

  # ── Sudo ────────────────────────────────────────────────────────────
  security.sudo.wheelNeedsPassword = false;
}
