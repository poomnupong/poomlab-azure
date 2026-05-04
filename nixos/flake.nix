# Top-level Nix flake for plaz NixOS hosts
#
# Uses Comin (GitOps pull model) for continuous deployment:
#   - Comin polls this repo and runs nixos-rebuild switch automatically.
#   - Secrets are encrypted with agenix and stored in git.
#   - deploy-infra bootstraps Comin on first VM creation.
#   - After bootstrap, all config changes are pulled automatically.
#
# Usage:
#   nix flake check          — validate all host configs
#   nixos-rebuild switch --flake .#gw1   — manual deploy on the VM
#
# To add a new VM:
#   1. Add a nixosConfigurations.<vmname> entry below.
#   2. Create a nixos/hosts/<vmname>/ directory with default.nix and hardware.nix.
#   3. Add the VM's age public key to nixos/secrets/secrets.nix.
#   4. Add a bootstrap step in deploy-infra.yml for the new VM.

{
  description = "plaz NixOS host configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-25.11";

    # Comin — GitOps pull-based deployment for NixOS
    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Agenix — age-encrypted secrets in git, decrypted on VMs via SSH host key
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-stable, comin, agenix, ... }:
    let
      system = "x86_64-linux";
      pkgs-unstable = import nixpkgs { inherit system; };
    in
    {

    # ── Standard NixOS configurations ────────────────────────────────
    # Each entry is consumed by `nixos-rebuild switch --flake .#<name>`.
    # Comin evaluates nixosConfigurations.<hostname> automatically.
    #
    # Channel policy:
    #   - pkgs (default) = nixpkgs-stable (nixos-25.11) — used unless specified
    #   - pkgs-unstable  = nixpkgs (nixos-unstable) — opt-in for bleeding-edge
    nixosConfigurations = {

      # ── gw1: NixOS gateway / NVA VM ──────────────────────────────
      gw1 = nixpkgs-stable.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit pkgs-unstable; };
        modules = [
          ./hosts/gw1/default.nix
          ./hosts/gw1/hardware.nix
          # Comin GitOps pull-based deployment
          comin.nixosModules.comin
          ./modules/comin.nix
          # Agenix encrypted secrets
          agenix.nixosModules.default
          ./modules/agenix.nix
        ];
      };

      # Future VMs: add entries here, e.g.:
      # vm2 = nixpkgs-stable.lib.nixosSystem {
      #   inherit system;
      #   specialArgs = { inherit pkgs-unstable; };
      #   modules = [
      #     ./hosts/vm2/default.nix
      #     ./hosts/vm2/hardware.nix
      #     comin.nixosModules.comin
      #     ./modules/comin.nix
      #     agenix.nixosModules.default
      #     ./modules/agenix.nix
      #   ];
      # };

    };

  };
}
