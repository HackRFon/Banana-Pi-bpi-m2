#!/bin/bash
# Runs once on first boot of the Banana Pi M2.
set -u
LOG=/var/log/bpi-firstboot.log
exec >>"$LOG" 2>&1
echo "== First boot $(date) =="

# 1. Grow the root partition/filesystem to fill the SD card
ROOTDEV=$(findmnt -n -o SOURCE /)          # e.g. /dev/mmcblk0p1
DISK=/dev/$(lsblk -no PKNAME "$ROOTDEV")
echo ", +" | sfdisk -N 1 --no-reread "$DISK"
partx -u "$DISK" || true
resize2fs "$ROOTDEV"

# 2. SSH host keys
ssh-keygen -A
systemctl restart ssh

# 3. Hardware: refresh packages and pull in firmware for whatever is attached
export DEBIAN_FRONTEND=noninteractive
if ping -c1 -W5 deb.debian.org >/dev/null 2>&1; then
  apt-get update
  apt-get -y upgrade
  # Install firmware packages matching detected USB/SDIO devices
  apt-get install -y isenkram-cli 2>/dev/null && isenkram-autoinstall-firmware || true
  # Rebuild boot menu in case the kernel was upgraded
  u-boot-update || true
else
  echo "No network on first boot; run 'sudo apt update && sudo apt upgrade' later."
fi

# 4. Log what the kernel detected
{ echo "--- lsusb ---"; lsusb; echo "--- ip link ---"; ip -br link; echo "--- DRM/HDMI ---"; ls /sys/class/drm; echo "--- sound ---"; aplay -l 2>&1; } || true

touch /var/lib/bpi-firstboot.done
systemctl disable bpi-firstboot.service
