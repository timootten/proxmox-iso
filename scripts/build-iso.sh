#!/bin/bash
#
# Builds an unattended Proxmox VE installation ISO.
# Used by the GitHub Action and runnable locally on Debian/Proxmox:
#   apt install proxmox-auto-install-assistant xorriso curl jq openssl
#   ./scripts/build-iso.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

# ---- Settings (override with environment variables) -------------------------
PVE_ISO="${PVE_ISO:-latest}"                       # file name, or "latest"
FQDN="${FQDN:-pve.timootten.com}"
MAILTO="${MAILTO:-hi@timootten.com}"
COUNTRY="${COUNTRY:-de}"
KEYBOARD="${KEYBOARD:-de}"
TIMEZONE="${TIMEZONE:-Europe/Berlin}"
GITHUB_KEYS_USER="${GITHUB_KEYS_USER:-timootten}"  # SSH keys are read from github.com/<user>.keys
NETWORK_MODE="${NETWORK_MODE:-dhcp}"               # dhcp | static
IP_CIDR="${IP_CIDR:-}"                             # static only, e.g. 5.175.223.10/24
GATEWAY="${GATEWAY:-}"                             # static only
DNS_SERVER="${DNS_SERVER:-1.1.1.1}"
SWAP_GIB="${SWAP_GIB:-4}"
TEMPLATES="${TEMPLATES:-de/debian-13}"             # space separated, "none" = no templates
GENERATOR_REPO="${GENERATOR_REPO:-timootten/Proxmox-Termplate-Generator}"
GENERATOR_REF="${GENERATOR_REF:-main}"
[ "$TEMPLATES" = "none" ] && TEMPLATES=""
OUT_DIR="${OUT_DIR:-out}"
OUT_NAME="${OUT_NAME:-proxmox-ve-auto.iso}"
# -----------------------------------------------------------------------------

for cmd in proxmox-auto-install-assistant xorriso curl jq openssl; do
    command -v "$cmd" >/dev/null || { echo "Missing tool: $cmd" >&2; exit 1; }
done

mkdir -p "$OUT_DIR" work
BASE_URL="https://download.proxmox.com/iso"

if [ "$PVE_ISO" = "latest" ]; then
    PVE_ISO=$(curl -fsSL "$BASE_URL/" | grep -oE 'proxmox-ve_[0-9]+\.[0-9]+-[0-9]+\.iso' | sort -uV | tail -1)
fi
[ -n "$PVE_ISO" ] || { echo "Could not determine Proxmox ISO" >&2; exit 1; }
echo "==> Source ISO: $PVE_ISO"

if [ ! -f "work/$PVE_ISO" ]; then
    curl -fL --retry 3 -o "work/$PVE_ISO" "$BASE_URL/$PVE_ISO"
fi
echo "==> Verifying checksum"
EXPECTED=$(curl -fsSL "$BASE_URL/SHA256SUMS" | awk -v f="$PVE_ISO" '$2==f {print $1}')
[ -n "$EXPECTED" ] || { echo "No checksum found for $PVE_ISO" >&2; exit 1; }
echo "$EXPECTED  work/$PVE_ISO" | sha256sum -c -

echo "==> Reading SSH keys from github.com/$GITHUB_KEYS_USER.keys"
KEYS_JSON=$(curl -fsSL "https://github.com/$GITHUB_KEYS_USER.keys" | grep -E '^(ssh|ecdsa|sk-)' | jq -R . | jq -cs .)
if [ "$(echo "$KEYS_JSON" | jq length)" -eq 0 ]; then
    echo "No SSH keys found for $GITHUB_KEYS_USER. The server would be unreachable. Aborting." >&2
    exit 1
fi

# The root password is random and never stored: login is by SSH key only.
# Set a password later with 'passwd' to use the web interface.
ROOT_HASH=$(openssl passwd -6 "$(openssl rand -base64 48)")

if [ "$NETWORK_MODE" = "static" ]; then
    [ -n "$IP_CIDR" ] && [ -n "$GATEWAY" ] || { echo "static needs IP_CIDR and GATEWAY" >&2; exit 1; }
    NETWORK_BLOCK=$(cat <<NET
[network]
source = "from-answer"
cidr = "$IP_CIDR"
dns = "$DNS_SERVER"
gateway = "$GATEWAY"
filter.ID_NET_NAME_MAC = "*"
NET
)
else
    NETWORK_BLOCK=$(cat <<NET
[network]
source = "from-dhcp"
NET
)
fi

cat > work/answer.toml <<TOML
[global]
keyboard = "$KEYBOARD"
country = "$COUNTRY"
fqdn = "$FQDN"
mailto = "$MAILTO"
timezone = "$TIMEZONE"
root-password-hashed = "$ROOT_HASH"
root-ssh-keys = $KEYS_JSON
reboot-mode = "reboot"

$NETWORK_BLOCK

[disk-setup]
filesystem = "ext4"
disk-list = ["sda"]
lvm.swapsize = $SWAP_GIB
lvm.maxvz = 0

[first-boot]
source = "from-iso"
ordering = "fully-up"
TOML

sed -e "s|@@TEMPLATES@@|$TEMPLATES|" \
    -e "s|@@GENERATOR_REPO@@|$GENERATOR_REPO|" \
    -e "s|@@GENERATOR_REF@@|$GENERATOR_REF|" \
    scripts/first-boot.sh > work/first-boot.sh
bash -n work/first-boot.sh

echo "==> Validating answer file"
proxmox-auto-install-assistant validate-answer work/answer.toml

echo "==> Preparing ISO"
rm -f "$OUT_DIR/$OUT_NAME"
proxmox-auto-install-assistant prepare-iso "work/$PVE_ISO" \
    --fetch-from iso \
    --answer-file work/answer.toml \
    --on-first-boot work/first-boot.sh \
    --output "$OUT_DIR/$OUT_NAME"

( cd "$OUT_DIR" && sha256sum "$OUT_NAME" > "$OUT_NAME.sha256" )
echo "PVE_ISO=$PVE_ISO" > "$OUT_DIR/build-info.env"
echo "==> Done: $OUT_DIR/$OUT_NAME"
ls -lh "$OUT_DIR"
