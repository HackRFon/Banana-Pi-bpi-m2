#!/bin/bash
# Builds a bootable Debian (armhf) SD-card image for the Banana Pi BPI-M2 (original, Allwinner A31s).
# Works on Debian/Ubuntu AND inside WSL2 on Windows (no loop devices or mounts needed for the image).
# Run from your Linux home folder (NOT /mnt/c):   sudo bash build-bpi-m2-image.sh
set -euo pipefail

SUITE=bookworm
IMG=bpi-m2-debian.img
IMG_MB=4096
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$HERE/rootfs-build

case "$HERE" in /mnt/*) echo "Copy these files to your Linux home (e.g. ~/bpi) first; /mnt/c breaks permissions."; exit 1;; esac
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }

apt-get update || true
apt-get install -y debootstrap e2fsprogs util-linux fdisk xz-utils
# ARM emulation packages are named differently on different Ubuntu/Debian releases
apt-get install -y qemu-user-static binfmt-support \
  || apt-get install -y qemu-user-static \
  || apt-get install -y qemu-user qemu-user-binfmt

# Make sure ARM emulation is registered (needed in WSL2)
mountpoint -q /proc/sys/fs/binfmt_misc || mount -t binfmt_misc none /proc/sys/fs/binfmt_misc || true
update-binfmts --enable qemu-arm || true
[ -e /proc/sys/fs/binfmt_misc/qemu-arm ] || { echo "ARM emulation (binfmt qemu-arm) is not active. In WSL run: wsl --update, wsl --shutdown, reopen Ubuntu, retry."; exit 1; }

cleanup() { for m in dev/pts dev proc sys; do umount -l "$ROOT/$m" 2>/dev/null || true; done; }
trap cleanup EXIT

rm -rf "$ROOT"
mkdir -p "$ROOT"
debootstrap --arch=armhf --include=ca-certificates,gnupg,wget "$SUITE" "$ROOT" http://deb.debian.org/debian

# ---- base configuration -------------------------------------------------
cat > "$ROOT/etc/apt/sources.list" <<EOF
deb http://deb.debian.org/debian $SUITE main contrib non-free non-free-firmware
deb http://deb.debian.org/debian $SUITE-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $SUITE-security main contrib non-free non-free-firmware
EOF
echo "bpi-m2" > "$ROOT/etc/hostname"
echo "127.0.1.1 bpi-m2" >> "$ROOT/etc/hosts"
echo "/dev/mmcblk0p1 / ext4 defaults,noatime 0 1" > "$ROOT/etc/fstab"

# Never prompt about config files during package installs
mkdir -p "$ROOT/etc/apt/apt.conf.d"
cat > "$ROOT/etc/apt/apt.conf.d/99noprompt" <<'EOF'
Dpkg::Options { "--force-confdef"; "--force-confold"; };
EOF

mkdir -p "$ROOT/etc/modprobe.d"
cat > "$ROOT/etc/modprobe.d/blacklist-rtl-sdr.conf" <<'EOF'
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2830
EOF

install -m 755 "$HERE/bpi-firstboot.sh" "$ROOT/usr/local/sbin/bpi-firstboot.sh"
install -m 755 "$HERE/install-feeders.sh" "$ROOT/usr/local/sbin/install-feeders.sh"
cat > "$ROOT/etc/systemd/system/bpi-firstboot.service" <<'EOF'
[Unit]
Description=Banana Pi M2 first boot setup
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/bpi-firstboot.done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/bpi-firstboot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# ---- packages inside the armhf chroot -------------------------------------
mount --bind /dev "$ROOT/dev"; mount --bind /dev/pts "$ROOT/dev/pts"
mount -t proc proc "$ROOT/proc"; mount -t sysfs sys "$ROOT/sys"
cp /etc/resolv.conf "$ROOT/etc/resolv.conf"

cat > "$ROOT/tmp/setup.sh" <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y u-boot-menu u-boot-sunxi initramfs-tools
cat > /etc/default/u-boot <<'UBEOF'
U_BOOT_PARAMETERS="ro rootwait console=ttyS0,115200 console=tty1 root=/dev/mmcblk0p1"
U_BOOT_FDT_DIR="/usr/lib/linux-image-"
UBEOF
apt-get install -y linux-image-armmp \
  systemd-sysv sudo openssh-server network-manager wpasupplicant wireless-regdb \
  usbutils pciutils parted e2fsprogs chrony
apt-get install -y firmware-linux-free firmware-misc-nonfree firmware-realtek \
  firmware-atheros firmware-brcm80211 firmware-ralink firmware-iwlwifi || true
apt-get install -y rtl-sdr librtlsdr0 git curl build-essential
u-boot-update
useradd -m -s /bin/bash -G sudo,plugdev,dialout,video,audio bpi
echo "bpi:bananapi" | chpasswd
chage -d 0 bpi
passwd -l root
systemctl enable bpi-firstboot.service ssh NetworkManager chrony
systemctl enable serial-getty@ttyS0.service
rm -f /etc/ssh/ssh_host_*
apt-get clean
EOF
chroot "$ROOT" /bin/bash /tmp/setup.sh
rm -f "$ROOT/tmp/setup.sh"
cleanup

# ---- U-Boot: use Debian's build if it has one for this board, else compile it ----
echo "U-Boot boards shipped by Debian:"; ls "$ROOT/usr/lib/u-boot/" || true
UBOOT="$ROOT/usr/lib/u-boot/Sinovoip_BPI_M2/u-boot-sunxi-with-spl.bin"
if [ -f "$UBOOT" ]; then
  cp "$UBOOT" "$HERE/u-boot-sunxi-with-spl.bin"
else
  echo "Debian has no BPI-M2 U-Boot; building from upstream source..."
  apt-get install -y gcc-arm-linux-gnueabihf make bison flex libssl-dev swig \
    python3-dev python3-setuptools python3-pyelftools device-tree-compiler bc \
    wget bzip2 uuid-dev libgnutls28-dev
  UB="$HERE/uboot-build"
  rm -rf "$UB"; mkdir -p "$UB"
  # GitHub mirror first (reachable from GitHub Actions); denx.de as a fallback
  wget --tries=5 --timeout=30 -O "$UB/u-boot.tar" https://github.com/u-boot/u-boot/archive/refs/tags/v2023.01.tar.gz \
    || wget --tries=3 --timeout=30 -O "$UB/u-boot.tar" https://ftp.denx.de/pub/u-boot/u-boot-2023.01.tar.bz2 \
    || { echo "Could not download U-Boot source"; exit 1; }
  tar -xf "$UB/u-boot.tar" -C "$UB" --strip-components=1
  make -C "$UB" CROSS_COMPILE=arm-linux-gnueabihf- Sinovoip_BPI_M2_defconfig
  make -C "$UB" CROSS_COMPILE=arm-linux-gnueabihf- -j"$(nproc)"
  [ -f "$UB/u-boot-sunxi-with-spl.bin" ] || { echo "U-Boot build failed"; exit 1; }
  cp "$UB/u-boot-sunxi-with-spl.bin" "$HERE/u-boot-sunxi-with-spl.bin"
fi

# ---- assemble the SD image WITHOUT mounting anything -----------------------
PART_MB=$((IMG_MB - 1))
truncate -s "${PART_MB}M" "$HERE/rootfs.ext4"
mkfs.ext4 -F -L rootfs -d "$ROOT" "$HERE/rootfs.ext4"

rm -f "$HERE/$IMG"
truncate -s "${IMG_MB}M" "$HERE/$IMG"
echo "label: dos
start=2048, type=83, bootable" | sfdisk "$HERE/$IMG"
dd if="$HERE/rootfs.ext4" of="$HERE/$IMG" bs=1M seek=1 conv=notrunc,sparse status=progress
dd if="$HERE/u-boot-sunxi-with-spl.bin" of="$HERE/$IMG" bs=1024 seek=8 conv=notrunc

rm -f "$HERE/rootfs.ext4"
xz -k -f -T0 "$HERE/$IMG"
echo "Done: $HERE/$IMG and $IMG.xz"


