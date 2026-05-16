# gw3 — Azure Gen2 hardware configuration (Japan East region)
#
# Hardware profile for an Azure Hyper-V Gen2 VM with NVMe + SCSI support.
# Identical to gw1/gw2 hardware profile — same Azure VM generation.

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

  # ── Azure Linux Agent (waagent) ──────────────────────────────────────
  services.waagent.enable = true;

  # ── Azure-specific networking ────────────────────────────────────────
  networking.useDHCP = lib.mkDefault true;

  # ── Platform ────────────────────────────────────────────────────────
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
