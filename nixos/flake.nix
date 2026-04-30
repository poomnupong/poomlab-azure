# Top-level Nix flake for plaz NixOS hosts
#
# Uses Colmena for multi-host deployment. Add new VMs by creating a new folder
# under hosts/<vmname>/ and referencing it in the colmena output below.
#
# Usage:
#   nix flake check          — validate all host configs
#   colmena apply --on gw1   — deploy to a specific host

{
  description = "plaz NixOS host configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    colmena = {
      url = "github:zhaofengli/colmena";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, colmena, ... }: {

    # ── Colmena deployment configuration ─────────────────────────────
    colmena = {
      meta = {
        nixpkgs = import nixpkgs { system = "x86_64-linux"; };
        # TODO: set nodeNixpkgs / nodeSpecialArgs per host if you need
        #       to pin different nixpkgs branches for specific hosts.
      };

      # ── gw1: NixOS gateway / NVA VM ────────────────────────────────
      gw1 = { name, nodes, pkgs, ... }: {
        deployment = {
          # TODO: replace with the actual public IP or Tailscale hostname of gw1.
          # This is overridden at deploy time via --override-hostname in the
          # deploy-nixos.yml workflow, so a placeholder is fine here.
          targetHost = "TODO_GW1_IP_OR_HOSTNAME";
          targetUser = "azureuser";
          tags = [ "gateway" "azure" ];
        };

        imports = [
          ./hosts/gw1/default.nix
          ./hosts/gw1/hardware.nix
        ];
      };
    };

  };
}
