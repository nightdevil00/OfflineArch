# Arch Linux Offline Installer

A two-script toolkit for building a self-contained Arch Linux live ISO that can perform a fully offline, non-destructive installation with LUKS encryption, Btrfs snapshots, Limine EFI boot, and optional Windows dual-boot detection.

**`build_iso.sh`** – Builds a custom `archiso` image containing an offline package repository (all dependencies pre-cached). The ISO boots directly into the installer with no internet required.

**`install_arch.sh`** – Interactive installer that runs from the ISO . It detects free disk space (no full-disk wipe), optionally encrypts with LUKS2, creates a Btrfs layout with subvolumes (`@`, `@home`, `@snapshots`, `@log`), installs the base system from the offline repo, configures Limine as the UEFI bootloader (with automatic Windows chainload detection), and enables Plymouth, ZRAM, PipeWire, and NetworkManager. It's a minimal install that's done in minutes.

### Features

- **Fully offline** – all packages bundled into the ISO; no internet needed during install
- **Non-destructive** – partitions are created in free space, existing OSes untouched
- **Dual-boot aware** – detects Windows EFI partitions and copies the bootloader for a chainload entry
- **Btrfs + snapshots** – CoW filesystem with `@snapshots` subvolume ready for snapper/timeshift
- **LUKS2 encryption** – optional full-disk encryption with Plymouth splash support
- **Limine bootloader** – modern, fast EFI bootloader with graphical menu
- **ZRAM + zstd** – compressed swap-on-RAM for better memory management
- **PipeWire audio** – full audio stack pre-configured

## Requirements

- **To build the ISO:** An existing Arch Linux system (or any Arch-based distro) with `archiso` and `pacman-contrib` installed.
- **To run the installer:** A UEFI system (BIOS/CSM not supported). At least 10 GB of free unpartitioned space on the target disk.
- **Internet** is only needed during `build_iso.sh` (to download packages). The resulting ISO installs entirely offline.

## Usage

### 1. Build the ISO

```bash
git clone <this-repo>
cd arch-offline-installer
sudo ./build_iso.sh
```

This will:
- Install `archiso` and `pacman-contrib` if missing
- Download all packages and their dependencies needed by the installer
- Create an offline package repository embedded in the ISO
- Output `arch-offline-installer-<date>.iso` in the current directory

### 2. Write the ISO to a USB drive

```bash
sudo dd if=arch-offline-installer-<date>.iso of=/dev/sdX bs=4M status=progress
```

Replace `/dev/sdX` with your USB device (e.g. `/dev/sda`).

### 3. Boot and install

1. Boot from the USB on the target UEFI machine.
2. The installer launches automatically on tty1. If it doesn't, run manually:

   ```bash
   sudo /root/install_arch.sh
   ```

3. Follow the prompts:
   - Select the target disk
   - Optionally encrypt with LUKS
   - Enter hostname, username, and password
   - Confirm to begin installation

4. After completion, reboot and select "Arch Linux (Limine)" from the UEFI boot menu.
5. Use nmtui to connect to Internet and pacman-key --init and pacman-key --populate archlinux before updating your system.
6. Enjoy

## Customization

Edit the `TARGET_PACKAGES` array in `build_iso.sh` to add or remove packages from the offline repository and installation target and in `install_arch.sh` to strap them into the installed system.


## How it works

`build_iso.sh` starts from Arch's `releng` profile, layers in the installer script, and pre-downloads every package (with full dependency resolution) into an offline repo stored on the ISO's `airootfs`. At boot, `install_arch.sh` partitions the largest free space region on the selected disk, optionally encrypts the root, creates a Btrfs subvolume layout, and uses `pacstrap -C /etc/pacman-offline.conf` to install everything from the local cache — no mirror required.
