# Top-level Nix flake for plaz NixOS hosts
#
# Consumed by `nixos-rebuild switch --flake .#<hostname>` run directly on each VM.
# GitHub Actions nudges each VM via `az vm run-command invoke` — no SSH key needed.
#
# Usage:
#   nix flake check          — validate all host configs
#   nixos-rebuild switch --flake .#gw1   — deploy on the VM itself
#
# To add a new VM:
#   1. Add a nixosConfigurations.<vmname> entry below.
#   2. Create a nixos/hosts/<vmname>/ directory with default.nix and hardware.nix.
#   3. Add a filter entry and a deploy-<vmname> job in deploy-nixos.yml.

{
  description = "plaz NixOS host configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs, nixpkgs-stable, ... }:
    let
      system = "x86_64-linux";
      pkgs-stable = import nixpkgs-stable { inherit system; };
    in
    {

    # ── Standard NixOS configurations ────────────────────────────────
    # Each entry is consumed by `nixos-rebuild switch --flake .#<name>`.
    # GitHub Actions passes an ephemeral GITHUB_TOKEN to the VM so it can
    # pull from this private repo without any stored credentials.
    nixosConfigurations = {

      # ── gw1: NixOS gateway / NVA VM ──────────────────────────────
      gw1 = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit pkgs-stable; };
        modules = [
          ./hosts/gw1/default.nix
          ./hosts/gw1/hardware.nix
        ];
      };

      # Future VMs: add entries here, e.g.:
      # vm2 = nixpkgs.lib.nixosSystem {
      #   system = "x86_64-linux";
      #   modules = [
      #     ./hosts/vm2/default.nix
      #     ./hosts/vm2/hardware.nix
      #   ];
      # };

    };

  };
}
