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
  # Match the base image (nixos-azimage-builder → nixpkgs azure-image.nix
  # with vmGeneration = "v2"), which installs GRUB-EFI as a removable
  # bootloader on the ESP. Switching to systemd-boot here would require
  # a one-time `--install-bootloader` rebuild and break first-boot deploys.
  boot.loader.systemd-boot.enable = false;
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    device = "nodev";
    efiInstallAsRemovable = true;
  };

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
    # The ESP is labelled "ESP" by nixpkgs azure-image.nix (vmGeneration = "v2"),
    # not "boot".
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  swapDevices = [ ];

  # ── Azure Linux Agent (waagent) ──────────────────────────────────────
  # The base image (nixos-azimage-builder / azure-image.nix) ships with
  # waagent enabled.  We must re-declare it here so that after
  # nixos-rebuild switch the agent stays enabled — otherwise Azure
  # loses VM-agent heartbeat and extensions like Run Command break.
  services.waagent.enable = true;

  # ── Azure-specific networking ────────────────────────────────────────
  # Hyper-V network interface drivers
  networking.useDHCP = lib.mkDefault true;

  # ── Platform ────────────────────────────────────────────────────────
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
