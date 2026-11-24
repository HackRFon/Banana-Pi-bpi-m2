#!/bin/bash
# Installs dump1090-fa + PiAware (FlightAware) and rbfeeder (AirNav Radar) on Debian armhf.
# Usage:  sudo install-feeders.sh [all|flightaware|airnav]
# Needs an RTL-SDR USB dongle (e.g. FlightAware Pro Stick) with a 1090 MHz antenna.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }
WHAT=${1:-all}
export DEBIAN_FRONTEND=noninteractive

install_flightaware() {
  echo "=== FlightAware: dump1090-fa + piaware ==="
  apt-get update
  apt-get install -y wget ca-certificates
  cd /tmp
  # Check https://www.flightaware.com/adsb/piaware/install for the current repository package version
  REPO_DEB="flightaware-apt-repository_1.2_all.deb"
  wget -O "$REPO_DEB" "https://www.flightaware.com/adsb/piaware/files/packages/pool/piaware/f/flightaware-apt-repository/$REPO_DEB"
  dpkg -i "$REPO_DEB"
  apt-get update
  apt-get install -y piaware dump1090-fa
  piaware-config allow-auto-updates yes
  piaware-config allow-manual-updates yes
  systemctl enable --now dump1090-fa piaware
  echo "PiAware installed. Claim this feeder at https://flightaware.com/adsb/piaware/claim"
  echo "(use the same account from the same public IP, or check 'sudo piaware-status')."
}

install_airnav() {
  echo "=== AirNav Radar: rbfeeder ==="
  apt-get update
  apt-get install -y wget gnupg ca-certificates
  # Official AirNav installer script. Review it first if you prefer: http://apt.rb24.com/inst_rbfeeder.sh
  bash -c "$(wget -qO - http://apt.rb24.com/inst_rbfeeder.sh)"
  # Point rbfeeder at the local dump1090 (Beast on port 30005)
  systemctl enable --now rbfeeder
  echo "Run 'sudo rbfeeder --showkey' for your sharing key and sign up at https://www.airnavradar.com"
  echo "Check status with: sudo systemctl status rbfeeder"
}

case "$WHAT" in
  flightaware) install_flightaware ;;
  airnav)      install_airnav ;;
  all)         install_flightaware; install_airnav ;;
  *) echo "Usage: $0 [all|flightaware|airnav]"; exit 1 ;;
esac

echo "Plug in the RTL-SDR dongle, then check:  rtl_test -t   and   sudo piaware-status"
