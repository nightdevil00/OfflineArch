#!/usr/bin/env bash
set -euo pipefail

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'
info() { echo -e "${B}INFO:${N} $1"; }
ok()   { echo -e "${G}OK:${N} $1"; }
warn() { echo -e "${R}WARNING:${N} $1"; }
abort() { warn "$1"; exit 1; }

# ==============================
# LOGGING SETUP
# ==============================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGFILE="$SCRIPT_DIR/build_iso.log"
exec > >(tee -a "$LOGFILE") 2>&1
info "Build log: $LOGFILE"

# Packages install_arch.sh installs to the target (pulled into offline repo)
TARGET_PACKAGES=(
  arch-install-scripts
  base base-devel linux linux-firmware
  sudo btrfs-progs git nano
  iwd networkmanager plymouth limine efibootmgr binutils
  amd-ucode intel-ucode dhcpcd
  cryptsetup
  pipewire pipewire-alsa pipewire-pulse wireplumber
  sof-firmware dhcpcd
  zram-generator vim
)

# Extra packages for the ISO environment (on top of releng defaults)
ISO_PACKAGES_EXTRA=(
  networkmanager
  limine
)

# ==============================
# Prerequisites
# ==============================
command -v mkarchiso >/dev/null || { warn "archiso not found. Installing..."; pacman -S --noconfirm archiso; }
command -v repo-add >/dev/null || { warn "pacman-utils not found. Installing..."; pacman -S --noconfirm pacman-contrib; }

# ==============================
# Work directory (clean start)
# ==============================
WORK_DIR="$SCRIPT_DIR/archiso-work"
info "Cleaning $WORK_DIR for fresh build..."
rm -rf "$WORK_DIR"
PROFILE="$WORK_DIR/profile"
OUT_DIR="$WORK_DIR/out"
CACHE_DIR="$WORK_DIR/pkg-cache"
mkdir -p "$WORK_DIR" "$OUT_DIR" "$CACHE_DIR" "$PROFILE"

# ==============================
# Copy releng profile as base
# ==============================
RELENG="/usr/share/archiso/configs/releng"
if [[ ! -d "$RELENG" ]]; then
  abort "Releng profile not found at $RELENG. Is archiso installed?"
fi
cp -r "$RELENG"/* "$PROFILE/"

# ==============================
# Create automated startup script (runs install_arch.sh at boot)
# ==============================
mkdir -p "$PROFILE/airootfs/root"
cat > "$PROFILE/airootfs/root/.automated_script.sh" << 'AUTOMATED'
#!/usr/bin/env bash
if [[ $(tty) == "/dev/tty1" ]]; then
  /root/install_arch.sh
fi
AUTOMATED
chmod 755 "$PROFILE/airootfs/root/.automated_script.sh"

# ==============================
# Add extra packages to ISO
# ==============================
for pkg in "${ISO_PACKAGES_EXTRA[@]}"; do
  if ! grep -qx "$pkg" "$PROFILE/packages.x86_64" 2>/dev/null; then
    echo "$pkg" >> "$PROFILE/packages.x86_64"
  fi
done

# ==============================
# Download target packages + deps
# ==============================
# Use a clean config with online mirrors + DownloadUser = root (avoids
# both the local-mirror-only system config and alpm traverse issues)
DL_CONF="$WORK_DIR/pacman-dl.conf"
cat > "$DL_CONF" << PACDL
[options]
HoldPkg = pacman glibc
Architecture = auto
CheckSpace
ParallelDownloads = 8
DownloadUser = root
SigLevel = Never
LocalFileSigLevel = Optional

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist
PACDL

# Use temp dbpath so pacman thinks nothing is installed → downloads ALL deps
TMP_DB="$WORK_DIR/tmp-db"
mkdir -p "$TMP_DB"

info "Syncing repos into temporary database..."
pacman -Sy --config "$DL_CONF" --cachedir "$CACHE_DIR" --dbpath "$TMP_DB" --noconfirm

info "Downloading packages with all dependencies for offline repo..."
pacman -Sw --config "$DL_CONF" --cachedir "$CACHE_DIR" --dbpath "$TMP_DB" --noconfirm "${TARGET_PACKAGES[@]}"

rm -rf "$TMP_DB"

# ==============================
# Create offline repo in airootfs
# ==============================
OFFLINE_REPO="$PROFILE/airootfs/var/cache/offline-repo"
mkdir -p "$OFFLINE_REPO"

info "Creating offline repository..."
find "$CACHE_DIR" -name '*.pkg.tar.zst' -exec cp {} "$OFFLINE_REPO/" \;
repo-add "$OFFLINE_REPO/offline.db.tar.gz" "$OFFLINE_REPO"/*.pkg.tar.zst

# ==============================
# ISO pacman.conf (online only — no offline repo, no deprecated community)
# ==============================
mkdir -p "$PROFILE/airootfs/etc"
cat > "$PROFILE/airootfs/etc/pacman.conf" << 'PACMAN_EOF'
[options]
HoldPkg = pacman glibc
Architecture = auto
CheckSpace
ParallelDownloads = 8
SigLevel = Never
LocalFileSigLevel = Optional

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist
PACMAN_EOF

# Offline-only pacman.conf (for install_arch.sh to use with pacstrap -C)
cat > "$PROFILE/airootfs/etc/pacman-offline.conf" << 'PACOFF_EOF'
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
PACOFF_EOF

# ==============================
# Copy install_arch.sh into ISO
# ==============================
if [[ -f "$SCRIPT_DIR/install_arch.sh" ]]; then
  cp "$SCRIPT_DIR/install_arch.sh" "$PROFILE/airootfs/root/install_arch.sh"
  chmod 755 "$PROFILE/airootfs/root/install_arch.sh"
else
  warn "install_arch.sh not found in current directory"
fi

# ==============================
# Update profiledef.sh
# ==============================
# Add file permissions for install_arch.sh (if not already present)
if ! grep -q '"/root/install_arch.sh"' "$PROFILE/profiledef.sh" 2>/dev/null; then
  sed -i '/^file_permissions=(/a\  ["\/root\/install_arch.sh"]="0:0:755"' "$PROFILE/profiledef.sh"
fi

# ISO metadata
sed -i 's/^iso_name=.*/iso_name="arch-offline-installer"/' "$PROFILE/profiledef.sh"
sed -i 's/^iso_label=.*/iso_label="ARCH_OFFLINE"/' "$PROFILE/profiledef.sh"
sed -i 's/^iso_publisher=.*/iso_publisher="Custom Arch Offline Installer"/' "$PROFILE/profiledef.sh"
sed -i 's/^iso_application=.*/iso_application="Arch Linux Offline Installer"/' "$PROFILE/profiledef.sh"

# ==============================
# Build ISO
# ==============================
info "Building ISO with mkarchiso..."
mkarchiso -w "$WORK_DIR/work" -o "$OUT_DIR" "$PROFILE"

# ==============================
# Copy result
# ==============================
ISO_FILE=$(ls "$OUT_DIR"/*.iso 2>/dev/null | head -1)
if [[ -n "$ISO_FILE" ]]; then
  DEST="$SCRIPT_DIR/$(basename "$ISO_FILE")"
  cp "$ISO_FILE" "$DEST"
  ok "ISO created: $DEST"
  ls -lh "$DEST"
else
  warn "ISO not found in $OUT_DIR"
  ls -la "$OUT_DIR"
fi
