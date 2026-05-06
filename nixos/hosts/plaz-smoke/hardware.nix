# plaz-smoke — Azure Gen2 hardware configuration (ephemeral smoke VM)
#
# Same hardware profile as gw1 — both run on the same baked Azure
# Gen2 gallery image. This file exists to satisfy nix flake check
# assertions (fileSystems, boot.loader) that would otherwise fail
# during CI validation.
#
# This VM is ephemeral: provisioned from the gallery image, tested,
# and destroyed within the same CI job.

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  # ── Boot loader ─────────────────────────────────────────────────────
  boot.loader.systemd-boot.enable = false;
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    device = "nodev";
    efiInstallAsRemovable = true;
  };

  # ── Kernel modules ──────────────────────────────────────────────────
  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "ahci"
    "sd_mod"
    "sr_mod"
    "hv_storvsc"
    "hv_vmbus"
    "hv_netvsc"
  ];
  boot.kernelModules = [ "hv_balloon" ];

  # ── Disk layout ─────────────────────────────────────────────────────
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  swapDevices = [ ];

  # ── Azure-specific networking ────────────────────────────────────────
  networking.useDHCP = lib.mkDefault true;

  # ── Platform ────────────────────────────────────────────────────────
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
