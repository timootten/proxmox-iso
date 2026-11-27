#!/bin/bash
# Installs the tools needed to build the ISO on a Debian or Ubuntu CI runner.
set -euo pipefail

SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

$SUDO apt-get update
$SUDO apt-get install -y --no-install-recommends ca-certificates curl gnupg xorriso jq openssl
$SUDO curl -fsSL https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
    -o /usr/share/keyrings/proxmox-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/proxmox-archive-keyring.gpg] http://download.proxmox.com/debian/pve trixie pve-no-subscription" \
    | $SUDO tee /etc/apt/sources.list.d/pve.list >/dev/null
# Only this one package may come from the Proxmox repository
printf 'Package: *\nPin: origin download.proxmox.com\nPin-Priority: 100\n\nPackage: proxmox-auto-install-assistant\nPin: origin download.proxmox.com\nPin-Priority: 600\n' \
    | $SUDO tee /etc/apt/preferences.d/proxmox >/dev/null
$SUDO apt-get update
$SUDO apt-get install -y --no-install-recommends proxmox-auto-install-assistant
proxmox-auto-install-assistant --version || true
