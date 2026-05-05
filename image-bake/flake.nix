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

      # Modules common to both the baked Azure image and the Tier 1
      # nixosTest VM. These are the poomlab-azure application modules:
      # base packages, Comin GitOps agent, agenix secret declarations,
      # and NVA networking. By sharing this list we guarantee the test
      # exercises the same module set the image is built from.
      #
      # host-specific modules (hostname, interface names, hardware.nix disk
      # layout) are NOT included here - they are applied at deploy time by
      # Comin via the runtime nixos/flake.nix.
      #
      # Secrets (.age files) cannot be baked in - agenix decrypts at runtime
      # using the VM's ssh_host_ed25519_key (injected by cloud-init, Phase 5).
      # The age.secrets declarations are included but the .age files only need
      # to exist at activation time, not at build time.
      appModules = [
        # NixOS module providers
        agenix.nixosModules.default
        comin.nixosModules.comin

        # poomlab-azure application modules
        ../nixos/modules/base.nix
        ../nixos/modules/comin.nix
        ../nixos/modules/agenix.nix
        ../nixos/modules/networking.nix

        # Common settings (shared between bake and test).
        # Inline lambda modules must be parenthesized when placed in a list:
        # without parens the Nix parser tries to read `{ lib, ... }` as an
        # attribute-set literal and fails on the `,`.
        ({ lib, ... }: {
          # stateVersion is a compat marker, not a channel version.
          # Use mkDefault so `core_pulse.nix`'s "24.11" wins for the bake while
          # this default applies to the smoke test (which does not import
          # core_pulse.nix).
          system.stateVersion = lib.mkDefault "25.11";

          # Comin asserts that either `networking.hostName` or
          # `services.comin.hostname` is set; without one of these the eval
          # fails with "You must set `networking.hostName` or
          # `services.comin.hostname` explicitly in your NixOS configuration."
          #
          # Host-specific modules (which set `networking.hostName = "gw1"` etc.)
          # are intentionally NOT imported here — they are layered on by Comin
          # at deploy time via the runtime nixos/flake.nix, which is a separate
          # flake from this one, so there is no priority conflict at deploy time.
          #
          # Use a regular-priority assignment (NOT lib.mkDefault) here: the
          # `azure` format from nixos-generators pulls in
          # `nixos/modules/virtualisation/azure-common.nix`, which itself
          # declares `networking.hostName = lib.mkDefault "";`. Two mkDefault
          # values at the same priority would conflict; a regular assignment
          # cleanly overrides azure-common's default while still satisfying
          # Comin's "explicitly set" assertion.
          networking.hostName = "plaz-image";

          # pkgs-unstable is expected by base.nix (for tailscale).
          # In the bake context we pin to stable - version is not critical here;
          # Comin will update via nixos-rebuild from the runtime flake.
          _module.args.pkgs-unstable = pkgs;
        })
      ];

      # Modules layered for the actual bake. Adds the upstream Azure
      # hardware baseline (core_pulse.nix: NVMe+SCSI drivers, Gen2 UEFI,
      # 8GiB disk, cloud-init, nix-ld, azureuser account, waagent enable)
      # plus bake-only overrides.
      #
      # core_pulse.nix is intentionally NOT shared with the smoke test:
      # it hard-codes Azure-specific bootloader and filesystem options
      # (GRUB-EFI, ESP label, /dev/disk/by-label mounts) that conflict
      # with the nixosTest VM's own disk/bootloader plumbing. Coverage
      # of that baseline is the job of Tier 2 (Phase 4) on real Azure.
      plazModules = [
        # nixos-azimage-builder does not export nixosModules, so import via path
        "${nixos-azimage-builder}/core_pulse.nix"
      ] ++ appModules ++ [
        {
          # waagent must be enabled in the baked image so it survives
          # nixos-rebuild switch after Comin applies config (D5 Tier 1 gate)
          services.waagent.enable = true;
        }
      ];

    in {

      # Baked Azure VHD image
      packages.${system} = {
        plazImage = nixos-generators.nixosGenerate {
          inherit system;
          format = "azure";
          modules = plazModules;
        };
        default = self.packages.${system}.plazImage;
      };

      # Tier 1 smoke test (nixosTest in QEMU, no Azure cost).
      #
      # SCOPE (intentionally narrow - see docs/architecture-refactor.md D5):
      #   - Loads the same `appModules` used to build the image so
      #     regressions in module evaluation, option conflicts, or
      #     activation-script generation are caught here.
      #   - Confirms the system boots, multi-user.target reaches active,
      #     and that the comin/agenix systemd units + their wiring are
      #     present and well-formed.
      #
      # OUT OF SCOPE for Tier 1:
      #   - The upstream `core_pulse.nix` hardware baseline (Azure-only
      #     bootloader / filesystem options collide with the nixosTest
      #     driver). Validated by Tier 2 on real Azure.
      #   - Comin actually fetching from the remote git repo (no internet
      #     in the QEMU sandbox; no token).
      #   - agenix decrypting .age files (the test VM's ssh host key is
      #     not in secrets.nix recipients).
      #   - waagent running (no Azure fabric in QEMU).
      # These end-to-end behaviours are validated by Tier 2 (Phase 4) on a
      # throwaway real-Azure VM. Only Tier 2 should set blessed=true.
      checks.${system} = {
        smokeTest = pkgs.nixosTest {
        name = "plaz-image-smoke";

        nodes.machine = { lib, ... }: {
          imports = appModules ++ [
            {
              # ── QEMU-sandbox-only overrides ─────────────────────────
              # agenix activation would fail-hard trying to decrypt the
              # real .age files with the test VM's host key (which is not
              # a recipient in secrets.nix). Drop the secrets in-test so
              # boot completes; agenix decryption is a Tier 2 concern.
              age.secrets = lib.mkForce {};
            }
          ];
        };

        testScript = ''
          machine.start()
          machine.wait_for_unit("multi-user.target")

          # nix-ld must be configured (required for Azure VM extensions)
          machine.succeed("systemctl is-active nix-ld.service")

          # comin systemd unit must be defined and loaded with the
          # repository URL we configured in nixos/modules/comin.nix.
          machine.succeed("systemctl cat comin.service")
          machine.succeed(
              "systemctl cat comin.service "
              "| grep -q 'github.com/poomnupong/poomlab-azure'"
          )

          # IP forwarding must be enabled (NVA role, from networking.nix)
          machine.succeed("sysctl net.ipv4.ip_forward | grep -q 'net.ipv4.ip_forward = 1'")

          # SSH daemon must be running
          machine.wait_for_unit("sshd.service")

          # azureuser must exist
          machine.succeed("id azureuser")

          # Basic Nix tooling works
          machine.succeed("nix --version")
        '';
        };
      };

    };
}
