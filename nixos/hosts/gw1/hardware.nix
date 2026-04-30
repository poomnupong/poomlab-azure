# gw1 — Azure Gen2 hardware configuration
#
# Hardware profile for an Azure Hyper-V Gen2 VM with NVMe + SCSI support.
# Adjust disk device names if your image uses a different layout.

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  # ── Boot loader ─────────────────────────────────────────────────────
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # ── Kernel modules ──────────────────────────────────────────────────
  # Azure Hyper-V + NVMe disk controller support
  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "ahci"
    "sd_mod"
    "sr_mod"
    "hv_storvsc"   # Hyper-V storage controller (SCSI)
    "hv_vmbus"
    "hv_netvsc"
  ];
  boot.kernelModules = [ "hv_balloon" ];

  # ── Disk layout ─────────────────────────────────────────────────────
  # TODO: verify disk device names match your image. NVMe-attached OS disk is
  # typically /dev/nvme0n1; SCSI-attached would be /dev/sda.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
  };

  swapDevices = [ ];

  # ── Azure-specific networking ────────────────────────────────────────
  # Hyper-V network interface drivers
  networking.useDHCP = lib.mkDefault true;

  # ── Platform ────────────────────────────────────────────────────────
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
