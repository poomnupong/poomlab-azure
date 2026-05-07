# base.nix — Common base configuration applied to all hosts
#
# Includes: admin user, SSH authorized keys, Nix daemon settings,
# locale, timezone, and basic packages.

{ config, lib, pkgs, pkgs-unstable, ... }:

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
  # Default pkgs = stable (nixos-25.11). Use pkgs-unstable for bleeding-edge.
  environment.systemPackages = (with pkgs; [
    vim
    git
    curl
    htop
    jq
    tmux
  ]) ++ [
    pkgs-unstable.tailscale
  ];

  # ── Locale / Timezone ────────────────────────────────────────────────
  # TODO: adjust timezone to match your Azure region / preference.
  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # ── Admin user ───────────────────────────────────────────────────────
  users.users.azureuser = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    # SSH public keys loaded from nixos/keys/admin.pub (one key per line).
    # Edit that file and push — Comin applies the change on all hosts.
    openssh.authorizedKeys.keys =
      let
        raw = builtins.readFile ../keys/admin.pub;
        lines = lib.splitString "\n" raw;
        trimmed = map lib.trim lines;
      in
      builtins.filter (line: line != "" && !(lib.hasPrefix "#" line)) trimmed;
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
  security.sudo.wheelNeedsPassword = true;
}
