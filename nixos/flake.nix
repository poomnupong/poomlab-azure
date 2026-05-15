# Top-level Nix flake for plaz NixOS hosts
#
# Uses Comin (GitOps pull model) for continuous deployment:
#   - Comin polls this repo and runs nixos-rebuild switch automatically.
#   - Secrets are encrypted with agenix and stored in git.
#   - After Comin is running on the box, all config changes are pulled
#     automatically — the runner is not in the deployment hot path.
#
# How Comin gets onto the box (in transition):
#   - Today: deploy-infra bootstraps Comin on first VM creation via
#     run-command + ephemeral SSH (see docs/comin-deployment.md). This is
#     the legacy path and is the source of most operational pain.
#   - Target: Comin is baked into the gallery image by the `image-bake`
#     workflow; first boot already has comin.service running. The
#     run-command bootstrap goes away in Phase 5.
#   See docs/architecture-refactor.md (D2, D4) and tracking PR #45:
#     https://github.com/poomnupong/poomlab-azure/pull/45
#
# Usage:
#   nix flake check          — validate all host configs
#   nixos-rebuild switch --flake .#gw1   — manual deploy on the VM
#
# To add a new VM:
#   1. Add a nixosConfigurations.<vmname> entry below.
#   2. Create a nixos/hosts/<vmname>/ directory with default.nix and hardware.nix.
#   3. Add the VM's age public key to nixos/secrets/secrets.nix.
#   4. Until image-bake lands, add a bootstrap step in deploy-infra.yml for
#      the new VM. After image-bake lands, no per-VM workflow change is
#      needed beyond the gallery image already having Comin baked in.

{
  description = "plaz NixOS host configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-25.11";

    # Comin — GitOps pull-based deployment for NixOS
    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    # Agenix — age-encrypted secrets in git, decrypted on VMs via SSH host key
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-stable, comin, agenix, ... }:
    let
      system = "x86_64-linux";
      pkgs-unstable = import nixpkgs { inherit system; };
      lib = nixpkgs-stable.lib;
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

      # ── gw2: NixOS gateway / NVA VM (Singapore) ───────────────────
      gw2 = nixpkgs-stable.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit pkgs-unstable; };
        modules = [
          ./hosts/gw2/default.nix
          ./hosts/gw2/hardware.nix
          # Comin GitOps pull-based deployment
          comin.nixosModules.comin
          ./modules/comin.nix
          # Agenix encrypted secrets
          agenix.nixosModules.default
          ./modules/agenix.nix
        ];
      };

      # ── plaz-smoke: ephemeral Tier 2 CI smoke-test host ──────────────
      # Never deployed to production. Exists only so Comin can find a valid
      # nixosConfigurations entry when running on the smoke VM (hostname=plaz-smoke).
      # The VM is provisioned with --computer-name plaz-smoke and destroyed after
      # the smoke test passes. See .github/workflows/image-bake.yml smoke-tier2.
      plaz-smoke = nixpkgs-stable.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit pkgs-unstable; };
        modules = [
          comin.nixosModules.comin
          ./modules/comin.nix
          agenix.nixosModules.default
          ./modules/base.nix
          ./modules/networking.nix
          ./hosts/plaz-smoke/default.nix
          ./hosts/plaz-smoke/hardware.nix
          {
            # plaz.comin.tokenPath = "/etc/comin-bootstrap-token" is set in
            # hosts/plaz-smoke/default.nix; cloud-init delivers the PAT at
            # VM creation time. Works for both public and private repos.
            age.secrets = lib.mkForce {};
            system.stateVersion = "25.11";
          }
        ];
      };

    };

  };
}
