#!/usr/bin/env bash
set -euo pipefail

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'

ask() { printf "${Y}[Y/n]${N} %s " "$1"; read -r ans; case "$ans" in [nN]*) return 1;; *) return 0;; esac; }
warn() { echo -e "${R}WARNING:${N} $1"; }
info() { echo -e "${B}INFO:${N} $1"; }
ok()   { echo -e "${G}OK:${N} $1"; }

abort() { warn "$1"; echo "Aborted."; exit 1; }

[[ $EUID -eq 0 ]] || abort "This script must be run as root."

# ==============================
# LOGGING SETUP
# ==============================
LOGFILE="/root/install_arch.log"
exec > >(tee -a "$LOGFILE") 2>&1
info "Installation log: $LOGFILE"

to_gb() { awk -v b="$1" 'BEGIN{printf "%.1fGB",b/1073741824}'; }

# ==============================
# STEP 1: SELECT MODE
# ==============================
echo "=== Select installation mode ==="
echo "  1) DualBoot  — Install alongside an existing OS"
echo "  2) Full Wipe — Erase entire disk and install fresh"
echo
read -r -p "Select mode [1/2]: " MODE
case "$MODE" in
  1|D|d|dualboot|DualBoot) MODE="dualboot" ;;
  2|F|f|full|Full|fullwipe|FullWipe) MODE="fullwipe" ;;
  *) abort "Invalid mode selection." ;;
esac
info "Mode: $([[ "$MODE" == "dualboot" ]] && echo "DualBoot" || echo "Full Wipe")"

# ==============================
# STEP 2: SELECT DISK
# ==============================
echo "=== Available disks ==="
boot_source=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)
exclude_disk=""
if [[ -n "$boot_source" ]]; then
  dev="$boot_source"
  while true; do
    parent=$(lsblk -dno PKNAME "$dev" 2>/dev/null | tail -n1)
    [[ -n "$parent" ]] || break
    dev="/dev/$parent"
  done
  [[ $(lsblk -dno TYPE "$dev" 2>/dev/null) == "disk" ]] && exclude_disk="$dev"
fi

disks=()
while IFS= read -r d; do
  [[ "$d" == "$exclude_disk" ]] && continue
  disks+=("$d")
done < <(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}' | grep -E '/dev/(sd|hd|vd|nvme|mmcblk|xv)')

[[ ${#disks[@]} -eq 0 ]] && abort "No disks found."

for i in "${!disks[@]}"; do
  d="${disks[$i]}"
  size=$(lsblk -dno SIZE "$d")
  model=$(lsblk -dno MODEL "$d" | sed 's/ *$//')
  echo "  $((i+1))) $d ($size) $model"
done

echo
read -r -p "Select disk number [1-${#disks[@]}]: " sel
sel=$((sel-1))
[[ $sel -ge 0 && $sel -lt ${#disks[@]} ]] || abort "Invalid selection."
DISK="${disks[$sel]}"
info "Selected: $DISK"

# ==============================
# STEP 3: DETECT WINDOWS + FREE SPACE (DualBoot only)
# ==============================
WIN_EFI=""
FREE_START_B=""
FREE_END_B=""
FREE_SIZE_B=""

if [[ "$MODE" == "dualboot" ]]; then
  # Detect Windows EFI
  for p in $(blkid -t TYPE=vfat -o device 2>/dev/null); do
    mp=$(mktemp -d)
    if mount -o ro "$p" "$mp" 2>/dev/null; then
      if [[ -d "$mp/EFI/Microsoft" ]]; then
        WIN_EFI="$p"
        umount "$mp" 2>/dev/null; rmdir "$mp" 2>/dev/null
        break
      fi
      umount "$mp" 2>/dev/null
    fi
    rmdir "$mp" 2>/dev/null
  done

  if [[ -n "$WIN_EFI" ]]; then
    echo; ok "Windows EFI detected on $WIN_EFI"
  else
    echo; warn "No Windows EFI partition found."
    ask "Continue anyway (may overwrite existing data)?" || abort "Cancelled."
  fi

  # Detect free space
  echo
  partprobe "$DISK" 2>/dev/null || true
  sleep 1

  FREE_INFO=$(parted -m "$DISK" unit B print free 2>/dev/null | \
    awk -F: '$NF ~ /free/ {gsub(/B/,"",$2);gsub(/B/,"",$3);gsub(/B/,"",$4); if($4+0>m+0){m=$4;s=$2;e=$3}} END{if(m>0) printf "%s %s %s",s,e,m}')
  FREE_START_B=$(echo "$FREE_INFO" | awk '{print $1}')
  FREE_END_B=$(echo "$FREE_INFO" | awk '{print $2}')
  FREE_SIZE_B=$(echo "$FREE_INFO" | awk '{print $3}')

  if [[ -z "$FREE_INFO" || "$FREE_SIZE_B" -lt $((10*1073741824)) ]]; then
    abort "No usable free space (>=10GB) detected on $DISK. Shrink a partition first."
  fi

  FREE_START_GB=$(to_gb "$FREE_START_B")
  FREE_SIZE_GB=$(to_gb "$FREE_SIZE_B")
  info "Free space: $FREE_SIZE_GB (from $FREE_START_GB)"
fi

# ==============================
# STEP 4: USER INPUT
# ==============================
echo
read -r -p "Hostname [archlinux]: " HOSTNAME
HOSTNAME=${HOSTNAME:-archlinux}

read -r -p "Username: " USERNAME
[[ -n "$USERNAME" && "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || abort "Invalid username."

read -r -s -p "Password: " PASSWORD; echo
read -r -s -p "Confirm password: " PASSWORD2; echo
[[ "$PASSWORD" == "$PASSWORD2" && -n "$PASSWORD" ]] || abort "Passwords don't match or empty."

PASSWORD_HASH=$(printf '%s' "$PASSWORD" | openssl passwd -6 -stdin)

# ==============================
# STEP 5: ENCRYPTION
# ==============================
echo
ENCRYPT=false
if ask "Encrypt root partition with LUKS?"; then
  ENCRYPT=true
  info "Root will be LUKS-encrypted."
else
  info "Root will NOT be encrypted."
fi

# ==============================
# STEP 6: CONFIRM
# ==============================
echo
echo "=== Installation Summary ==="
echo "  Mode:      $([[ "$MODE" == "dualboot" ]] && echo "DualBoot" || echo "Full Wipe")"
echo "  Disk:      $DISK"
if [[ "$MODE" == "dualboot" ]]; then
  echo "  Free:      $FREE_SIZE_GB at $FREE_START_GB"
  echo "  Windows:   ${WIN_EFI:+Yes ($WIN_EFI)}${WIN_EFI:-Not detected}"
fi
echo "  Encrypt:   $ENCRYPT"
echo "  Hostname:  $HOSTNAME"
echo "  Username:  $USERNAME"
echo "  Boot:      Limine (UEFI)"
echo
echo "Partitions to create:"
echo "  1) 2GB EFI (fat32, esp)"
if [[ "$MODE" == "fullwipe" ]]; then
  DISK_SIZE_B=$(lsblk -b -dno SIZE "$DISK")
  ROOT_EST_SIZE=$(( DISK_SIZE_B - 2147483648 ))
  echo "  2) $(to_gb "$ROOT_EST_SIZE") Btrfs root (rest of disk)${ENCRYPT:+ (LUKS encrypted)}"
else
  echo "  2) ${FREE_SIZE_GB} Btrfs root${ENCRYPT:+ (LUKS encrypted)}"
fi

if [[ "$MODE" == "fullwipe" ]]; then
  echo
  warn "This will ERASE ALL DATA on $DISK!"
fi
echo
ask "Proceed with installation?" || abort "Cancelled."

# ==============================
# STEP 7: PARTITION
# ==============================
echo
info "Creating partitions..."

ALIGN=$((1048576))

if [[ "$MODE" == "fullwipe" ]]; then
  # Full wipe: create fresh GPT, EFI (2GB) + root (rest)
  parted --script "$DISK" mklabel gpt
  parted --script "$DISK" mkpart primary fat32 1MiB 2GiB
  parted --script "$DISK" set 1 esp on
  parted --script "$DISK" name 1 "ARCH_EFI"
  parted --script "$DISK" mkpart primary btrfs 2GiB 100%
  parted --script "$DISK" name 2 "ARCH_ROOT"

  EFI_NUM=1
  ROOT_NUM=2
else
  # DualBoot: create partitions in free space
  LAST_PART=$(lsblk -n -o PARTN "$DISK" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1)
  EFI_NUM=$(( ${LAST_PART:-0} + 1 ))
  ROOT_NUM=$(( EFI_NUM + 1 ))

  EFI_SIZE_B=$((2147483648))
  EFI_START_B=$(( (FREE_START_B + ALIGN - 1) / ALIGN * ALIGN ))
  EFI_END_B=$((EFI_START_B + EFI_SIZE_B))
  ROOT_START_B=$(( (EFI_END_B + 1 + ALIGN - 1) / ALIGN * ALIGN ))
  ROOT_END_B=$((FREE_END_B / ALIGN * ALIGN - ALIGN))

  (( ROOT_END_B > ROOT_START_B )) || abort "Not enough aligned space."

  parted --script "$DISK" mkpart primary fat32 "${EFI_START_B}B" "${EFI_END_B}B"
  parted --script "$DISK" set "$EFI_NUM" esp on
  parted --script "$DISK" name "$EFI_NUM" "ARCH_EFI"
  parted --script "$DISK" mkpart primary btrfs "${ROOT_START_B}B" "${ROOT_END_B}B"
  parted --script "$DISK" name "$ROOT_NUM" "ARCH_ROOT"
fi

partprobe "$DISK"; sync; sleep 3

if [[ "$DISK" == *nvme* || "$DISK" == *mmcblk* ]]; then
  EFI_DEV="${DISK}p${EFI_NUM}"
  ROOT_DEV="${DISK}p${ROOT_NUM}"
else
  EFI_DEV="${DISK}${EFI_NUM}"
  ROOT_DEV="${DISK}${ROOT_NUM}"
fi

ok "EFI: $EFI_DEV   Root: $ROOT_DEV"

# ==============================
# STEP 8: ENCRYPTION + FILESYSTEMS
# ==============================
LUKS_UUID=""

# Remove old filesystem/LUKS signatures
wipefs -a "$ROOT_DEV"

if $ENCRYPT; then
  info "Setting up LUKS on $ROOT_DEV..."

  printf "%s" "$PASSWORD" | cryptsetup luksFormat \
    --type luks2 \
    --batch-mode \
    --force-password \
    "$ROOT_DEV" -

  printf "%s" "$PASSWORD" | cryptsetup open "$ROOT_DEV" root

  ROOT_MAPPER="/dev/mapper/root"
  LUKS_UUID=$(cryptsetup luksUUID "$ROOT_DEV")

  # Clear any signatures inside mapper too
  wipefs -a "$ROOT_MAPPER"
else
  # Remove stale LUKS metadata if present
  cryptsetup luksErase "$ROOT_DEV" 2>/dev/null || true

  ROOT_MAPPER="$ROOT_DEV"
fi

info "Creating Btrfs filesystem on $ROOT_MAPPER..."
mkfs.btrfs -f "$ROOT_MAPPER"

mount "$ROOT_MAPPER" /mnt
for sub in @ @home @snapshots @log; do
  btrfs subvolume create "/mnt/$sub"
done
umount /mnt

mount -o noatime,compress=zstd,subvol=@ "$ROOT_MAPPER" /mnt
mkdir -p /mnt/{home,.snapshots,var/log,boot}
mount -o noatime,compress=zstd,subvol=@home "$ROOT_MAPPER" /mnt/home
mount -o noatime,compress=zstd,subvol=@snapshots "$ROOT_MAPPER" /mnt/.snapshots
mount -o noatime,compress=zstd,subvol=@log "$ROOT_MAPPER" /mnt/var/log

mkfs.fat -F32 "$EFI_DEV"
mount "$EFI_DEV" /mnt/boot

ok "Filesystems created and mounted."

# Copy Windows EFI bootloader for Limine chainload entry (DualBoot only)
if [[ "$MODE" == "dualboot" && -n "$WIN_EFI" ]]; then
  [[ "$EFI_DEV" == "$WIN_EFI" ]] && abort "EFI device collision with Windows partition."
  WIN_MP=$(mktemp -d)
  if mount -o ro "$WIN_EFI" "$WIN_MP" 2>/dev/null; then
    mkdir -p /mnt/boot/EFI && cp -r "$WIN_MP/EFI/Microsoft" /mnt/boot/EFI/ 2>/dev/null && ok "Windows bootloader copied to EFI" || warn "Failed to copy Windows bootloader"
    umount "$WIN_MP"
  fi
  rmdir "$WIN_MP" 2>/dev/null
fi

# Build kernel cmdline (used later inside chroot for limine.conf)
if $ENCRYPT; then
  CMDLINE="quiet splash cryptdevice=UUID=${LUKS_UUID}:root root=/dev/mapper/root rw rootflags=subvol=@ rootfstype=btrfs"
  CMDLINE_FB="quiet cryptdevice=UUID=${LUKS_UUID}:root root=/dev/mapper/root rw rootflags=subvol=@ rootfstype=btrfs"
else
  ROOT_FS_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
  CMDLINE="quiet splash root=UUID=${ROOT_FS_UUID} rw rootflags=subvol=@ rootfstype=btrfs"
  CMDLINE_FB="quiet root=UUID=${ROOT_FS_UUID} rw rootflags=subvol=@ rootfstype=btrfs"
fi

# ==============================
# STEP 9: PACSTRAP (offline or online)
# ==============================
info "Installing base system..."
PACMAN_CONF="/etc/pacman.conf"

PACKAGES=(
  base base-devel linux linux-firmware
  sudo btrfs-progs git nano
  dhcpcd networkmanager iwd limine efibootmgr binutils
  amd-ucode intel-ucode
  cryptsetup pipewire pipewire-alsa pipewire-pulse wireplumber
  sof-firmware plymouth
  zram-generator
  vim
)

OFFLINE_PACMAN_CONF=""
OFFLINE_REPO="/var/cache/offline-repo"
if [[ -d "$OFFLINE_REPO" && -f "$OFFLINE_REPO/offline.db" ]]; then
  OFFLINE_PACMAN_CONF=$(mktemp /tmp/pacman-offline-XXXXXXXX.conf)
  cat > "$OFFLINE_PACMAN_CONF" << 'PACOFF'
[options]
HoldPkg = pacman glibc
Architecture = auto
CheckSpace
ParallelDownloads = 8
SigLevel = Never
LocalFileSigLevel = Optional

[offline]
SigLevel = Never
Server = file:///var/cache/offline-repo/
PACOFF
  info "Using offline repo at $OFFLINE_REPO"
  PACMAN_CONF="$OFFLINE_PACMAN_CONF"
fi
if [[ -z "$OFFLINE_PACMAN_CONF" ]]; then
  info "Checking internet connectivity..."
  ping -c 1 archlinux.org >/dev/null 2>&1 \
    || abort "No internet connection and no offline repo available."
fi
if pacstrap -C "$PACMAN_CONF" /mnt "${PACKAGES[@]}"; then
  genfstab -U /mnt >> /mnt/etc/fstab
  ok "Base system installed."
else
  abort "pacstrap failed."
fi

if [[ -n "$OFFLINE_PACMAN_CONF" ]]; then
  mkdir -p /mnt/var/cache/offline-repo
  mount --bind "$OFFLINE_REPO" /mnt/var/cache/offline-repo
  cp "$OFFLINE_PACMAN_CONF" /mnt/etc/pacman.conf
fi

# Crypttab
if $ENCRYPT; then
  echo "root UUID=$LUKS_UUID none luks,discard" >> /mnt/etc/crypttab
fi

# ==============================
# STEP 10: CHROOT CONFIGURATION
# ==============================
info "Configuring system in chroot..."

cat > /mnt/setup.sh << 'CHROOT'
#!/usr/bin/bash
set -euo pipefail
source /pwhash.env
rm /pwhash.env

TIMEZONE="__TIMEZONE__"
HOSTNAME="__HOSTNAME__"
KB="__KB__"
USERNAME="__USERNAME__"
EFINUM="__EFINUM__"
DISK="__DISK__"
ENCRYPT="__ENCRYPT__"

# Time
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

# Locale
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts << H
127.0.0.1 localhost
::1       localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
H

# Console keymap
echo "KEYMAP=$KB" > /etc/vconsole.conf

# Root password
echo "root:$PWHASH" | chpasswd -e

# User
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$PWHASH" | chpasswd -e
sed -i '/^# %wheel ALL=(ALL:ALL) ALL$/s/^# //' /etc/sudoers

# Pacman configuration (standard online repos)
cat > /etc/pacman.conf << 'PACCONF'
[options]
HoldPkg = pacman glibc
Architecture = auto
CheckSpace
ParallelDownloads = 5
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist
PACCONF

# mkinitcpio
sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
sed -i 's|^BINARIES=.*|BINARIES=(/usr/bin/btrfs)|' /etc/mkinitcpio.conf

if [[ "$ENCRYPT" == "true" ]]; then
  sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
else
  sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap block filesystems fsck)/' /etc/mkinitcpio.conf
fi

echo 'COMPRESSION="zstd"' >> /etc/mkinitcpio.conf
mkinitcpio -P

# ZRAM
cat > /etc/systemd/zram-generator.conf << Z
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
Z

# Limine EFI
mkdir -p /boot/EFI/limine
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/
efibootmgr --create --disk "$DISK" --part "$EFINUM" \
  --label "Arch Linux (Limine)" \
  --loader '\EFI\limine\BOOTX64.EFI' \
  --unicode

  efibootmgr -v

# Write limine.conf
cat > /boot/EFI/limine/limine.conf << 'LIMEOF'
timeout: 3

/Arch Linux
    protocol: linux
    kernel_path: boot():/vmlinuz-linux
    cmdline: __CMDLINE__
    module_path: boot():/initramfs-linux.img

/Arch Linux (fallback)
    protocol: linux
    kernel_path: boot():/vmlinuz-linux
    cmdline: __CMDLINE_FB__
    module_path: boot():/initramfs-linux-fallback.img
LIMEOF

if [[ -d "/boot/EFI/Microsoft" ]]; then
  cat >> /boot/EFI/limine/limine.conf << 'WEOF'

/Windows Boot Manager
    protocol: chainload
    path: boot():/EFI/Microsoft/Boot/bootmgfw.efi
WEOF
fi

# Network stack: iwd + systemd-resolved + systemd-networkd
systemctl disable --now NetworkManager.service 2>/dev/null || true
systemctl enable --now iwd.service
systemctl enable --now systemd-resolved.service
systemctl enable --now systemd-networkd

# systemd-networkd DHCP config for wlan0
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/25-wlan0.network << 'NETEOF'
[Match]
Name=wlan0

[Network]
DHCP=ipv4
NETEOF

# iwd DNS config
mkdir -p /root/.config/iwd
cat > /root/.config/iwd/main.conf << 'IWDOF'
[Network]
EnableNetworkConfiguration=true
NameResolvingService=systemd
IWDOF
CHROOT

# Fill placeholders
TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")

KB_LAYOUT="us"
for p in /sys/class/tty/tty0/active /sys/class/tty/console/active; do
  if [[ -f "$p" ]]; then
    KB_GUESS=$(localectl status 2>/dev/null | awk -F': ' '/VC Keymap/{gsub(/^[ \t]+/, "", $2); print $2}')
    [[ -z "$KB_GUESS" ]] && KB_GUESS=$(localectl status 2>/dev/null | awk '/Keymap/{print $2; exit}')
    KB_LAYOUT="${KB_GUESS:-us}"
    break
  fi
done

sed -i "s|__TIMEZONE__|$TIMEZONE|g" /mnt/setup.sh
sed -i "s|__HOSTNAME__|$HOSTNAME|g" /mnt/setup.sh
sed -i "s|__KB__|$KB_LAYOUT|g" /mnt/setup.sh
sed -i "s|__USERNAME__|$USERNAME|g" /mnt/setup.sh
printf "PWHASH='%s'\n" "$PASSWORD_HASH" > /mnt/pwhash.env
sed -i "s|__EFINUM__|$EFI_NUM|g" /mnt/setup.sh
sed -i "s|__DISK__|$DISK|g" /mnt/setup.sh
sed -i "s|__ENCRYPT__|$ENCRYPT|g" /mnt/setup.sh
sed -i "s|__CMDLINE__|$CMDLINE|g" /mnt/setup.sh
sed -i "s|__CMDLINE_FB__|$CMDLINE_FB|g" /mnt/setup.sh

chmod +x /mnt/setup.sh

if arch-chroot /mnt /setup.sh; then
  rm /mnt/setup.sh
  ok "System configured successfully."
else
  rm -f /mnt/setup.sh
  abort "System configuration failed."
fi

# Copy log to installed system
cp "$LOGFILE" /mnt/var/log/ 2>/dev/null || true

umount -R /mnt 2>/dev/null || true

# ==============================
# STEP 11: CLEANUP
# ==============================
echo
info "Installation complete!"
echo
echo "You can now:"
echo "  1) reboot"
echo "  2) Boot into Arch Linux from the UEFI menu"
echo
ask "Reboot now?" && reboot
