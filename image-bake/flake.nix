# image-bake/flake.nix
#
# Build-time flake: layers poomlab-azure modules on top of the upstream
# nixos-azimage-builder hardware baseline to produce a gallery-ready VHD
# with Comin baked in from first boot.
#
# Phase 3 of the workflow/image architecture refactor.
# See docs/architecture-refactor.md for design decisions D1-D5.
#
# Usage (CI):
#   cd image-bake && nix build .#plazImage --print-build-logs
#   nix build .#checks.x86_64-linux.smokeTest
#
# This flake is intentionally separate from nixos/flake.nix (the runtime
# flake consumed by Comin for nixos-rebuild switch). They have different
# input sets: this one needs nixos-generators and nixos-azimage-builder;
# the runtime one does not.

{
  description = "plaz NixOS Azure image bake pipeline";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-azimage-builder = {
      url = "github:poomnupong/nixos-azimage-builder";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators, nixos-azimage-builder, agenix, comin, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      # Modules layered on top of the upstream hardware baseline.
      # core_pulse.nix provides: NVMe+SCSI drivers, Gen2 UEFI, 8GiB disk,
      # cloud-init, nix-ld, azureuser account, waagent enable.
      # We add the application modules: base packages, Comin GitOps agent,
      # agenix secret declarations, and NVA networking.
      #
      # host-specific modules (hostname, interface names, hardware.nix disk
      # layout) are NOT included here - they are applied at deploy time by
      # Comin via the runtime nixos/flake.nix.
      #
      # Secrets (.age files) cannot be baked in - agenix decrypts at runtime
      # using the VM's ssh_host_ed25519_key (injected by cloud-init, Phase 5).
      # The age.secrets declarations are included but the .age files only need
      # to exist at activation time, not at build time.
      plazModules = [
        # Hardware baseline from upstream (boot, disk, cloud-init, drivers, waagent)
        # nixos-azimage-builder does not export nixosModules, so import via path
        "${nixos-azimage-builder}/core_pulse.nix"

        # NixOS module providers
        agenix.nixosModules.default
        comin.nixosModules.comin

        # poomlab-azure application modules
        ../nixos/modules/base.nix
        ../nixos/modules/comin.nix
        ../nixos/modules/agenix.nix
        ../nixos/modules/networking.nix

        # Image-bake overrides
        {
          # stateVersion must match the nixpkgs channel (nixos-25.11)
          system.stateVersion = "25.11";

          # waagent must be enabled in the baked image so it survives
          # nixos-rebuild switch after Comin applies config (D5 Tier 1 gate)
          virtualisation.azure.agent.enable = true;

          # pkgs-unstable is expected by base.nix (for tailscale).
          # In the bake context we pin to stable - version is not critical here;
          # Comin will update via nixos-rebuild from the runtime flake.
          _module.args.pkgs-unstable = pkgs;
        }
      ];

    in {

      # Baked Azure VHD image
      packages.${system}.plazImage = nixos-generators.nixosGenerate {
        inherit system;
        format = "azure";
        modules = plazModules;
      };

      packages.${system}.default = self.packages.${system}.plazImage;

      # Tier 1 smoke test (nixosTest in QEMU, no Azure cost)
      # Tests the module set - boots the same modules in a QEMU VM and
      # asserts service/unit correctness.
      # See docs/architecture-refactor.md D5 for Tier 1 assertions.
      checks.${system}.smokeTest = pkgs.nixosTest {
        name = "plaz-image-smoke";

        nodes.machine = { lib, ... }: {
          imports = [
            agenix.nixosModules.default
            comin.nixosModules.comin
            ../nixos/modules/base.nix
            ../nixos/modules/comin.nix
            ../nixos/modules/agenix.nix
            ../nixos/modules/networking.nix
          ];

          # Test-environment overrides
          _module.args.pkgs-unstable = pkgs;

          # Disable waagent in QEMU (no Azure fabric present)
          virtualisation.azure.agent.enable = lib.mkForce false;

          # Disable comin polling in QEMU (no real git remote reachable).
          # The systemd unit must be defined but should not actively fetch.
          services.comin.enable = lib.mkForce false;

          # agenix: .age files do not exist in the test VM sandbox
          age.secrets = lib.mkForce {};

          system.stateVersion = "25.11";
        };

        testScript = ''
          machine.start()
          machine.wait_for_unit("multi-user.target")

          # nix-ld must be configured (required for Azure VM extensions)
          machine.succeed("systemctl is-active nix-ld.service")

          # comin systemd unit must be defined (even if disabled in test)
          machine.succeed("systemctl cat comin.service")

          # IP forwarding must be enabled (NVA role, from networking.nix)
          machine.succeed("sysctl net.ipv4.ip_forward | grep -q 'net.ipv4.ip_forward = 1'")

          # SSH daemon must be running
          machine.wait_for_unit("sshd.service")

          # azureuser must exist
          machine.succeed("id azureuser")

          # node_exporter must be running (monitoring module)
          machine.wait_for_unit("prometheus-node-exporter.service")

          # Basic Nix tooling works
          machine.succeed("nix --version")
        '';
      };

    };
}
