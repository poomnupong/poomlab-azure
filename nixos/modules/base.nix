# base.nix — Common base configuration applied to all hosts
#
# Includes: admin user, SSH authorized keys, Nix daemon settings,
# locale, timezone, and basic packages.

{ config, pkgs, ... }:

{
  # ── Dynamic linker compatibility ────────────────────────────────────
  # Required so the Azure VM agent (waagent) and extensions like
  # RunCommandLinux can execute their dynamically-linked binaries.
  # Without this, `az vm run-command invoke` fails with exit code 127.
  programs.nix-ld.enable = true;

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
  # Passwordless sudo for wheel members is required by the deploy-nixos
  # workflow: GitHub Actions SSHes in as azureuser (a wheel member) and runs
  # `sudo nixos-rebuild switch`.  The NSG restricts SSH access to the runner's
  # ephemeral IP only for the duration of each deployment, so the broader sudo
  # permission is safe in this context.
  security.sudo.wheelNeedsPassword = false;
}
