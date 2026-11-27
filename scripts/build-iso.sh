#!/bin/bash
#
# Builds an unattended Proxmox VE installation ISO.
# Used by the GitHub Action and runnable locally on Debian or Proxmox:
#   apt install proxmox-auto-install-assistant xorriso curl jq openssl
#   ./scripts/build-iso.sh
#
# Settings come from the environment first, then from config/server.env.
set -euo pipefail

cd "$(dirname "$0")/.."

die() { echo "ERROR: $*" >&2; exit 1; }

# ---- Load config/server.env (only for variables that are unset or empty) ----
if [ -f config/server.env ]; then
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
        value="${value%\"}"; value="${value#\"}"
        if [ -z "${!key:-}" ]; then
            export "$key=$value"
        fi
    done < <(grep -vE '^[[:space:]]*(#|$)' config/server.env)
fi

PVE_ISO="${PVE_ISO:-latest}"
TARGET="${TARGET:-vps}"
FQDN="${FQDN:?FQDN is not set}"
MAILTO="${MAILTO:-root@localhost}"
COUNTRY="${COUNTRY:-de}"
KEYBOARD="${KEYBOARD:-de}"
TIMEZONE="${TIMEZONE:-Europe/Berlin}"
GITHUB_KEYS_USER="${GITHUB_KEYS_USER:-}"
NETWORK_MODE="${NETWORK_MODE:-dhcp}"
IP_CIDR="${IP_CIDR:-}"
GATEWAY="${GATEWAY:-}"
DNS_SERVERS="${DNS_SERVERS:-1.1.1.1 8.8.8.8 2606:4700:4700::1111 2001:4860:4860::8888}"
DISK_LIST="${DISK_LIST:-sda}"
ZFS_RAID="${ZFS_RAID:-raid1}"
ZFS_ARC_MAX_GIB="${ZFS_ARC_MAX_GIB:-}"
SWAP_GIB="${SWAP_GIB:-4}"
IP_FORWARDING="${IP_FORWARDING:-auto}"
MGMT_ALLOWED="${MGMT_ALLOWED:-}"
TEMPLATES="${TEMPLATES:-none}"
GENERATOR_REPO="${GENERATOR_REPO:-timootten/Proxmox-Termplate-Generator}"
GENERATOR_REF="${GENERATOR_REF:-main}"
OUT_DIR="${OUT_DIR:-out}"
OUT_NAME="${OUT_NAME:-proxmox-ve-auto.iso}"
[ "$TEMPLATES" = "none" ] && TEMPLATES=""

# ---- Validation -------------------------------------------------------------
for cmd in proxmox-auto-install-assistant xorriso curl jq openssl; do
    command -v "$cmd" >/dev/null || die "missing tool: $cmd"
done

case "$TARGET" in vps|baremetal) ;; *) die "TARGET must be vps or baremetal" ;; esac
case "$NETWORK_MODE" in dhcp|static) ;; *) die "NETWORK_MODE must be dhcp or static" ;; esac
case "$IP_FORWARDING" in auto|true|false) ;; *) die "IP_FORWARDING must be auto, true or false" ;; esac

[[ "$FQDN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] \
    || die "FQDN needs a hostname and a domain, got '$FQDN'"
[[ "$SWAP_GIB" =~ ^[0-9]+$ ]] || die "SWAP_GIB must be a number"
[[ "$KEYBOARD" =~ ^[a-z-]+$ && "$COUNTRY" =~ ^[a-z]{2}$ ]] || die "invalid KEYBOARD or COUNTRY"
[[ "$PVE_ISO" == "latest" || "$PVE_ISO" =~ ^proxmox-ve_[0-9]+\.[0-9]+-[0-9]+\.iso$ ]] || die "invalid PVE_ISO"

ip_re='^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9A-Fa-f:]+$'
if [ "$NETWORK_MODE" = "static" ]; then
    [[ "$IP_CIDR" =~ ^(([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}|[0-9A-Fa-f:]+/[0-9]{1,3})$ ]] \
        || die "static mode needs IP_CIDR like 192.0.2.10/24"
    [[ "$GATEWAY" =~ $ip_re ]] || die "static mode needs GATEWAY"
fi

read -r -a DNS_ARRAY <<< "$DNS_SERVERS"
[ "${#DNS_ARRAY[@]}" -ge 1 ] || die "DNS_SERVERS is empty"
for d in "${DNS_ARRAY[@]}"; do [[ "$d" =~ $ip_re ]] || die "invalid DNS server '$d'"; done

read -r -a DISK_ARRAY <<< "$DISK_LIST"
[ "${#DISK_ARRAY[@]}" -ge 1 ] || die "DISK_LIST is empty"
for d in "${DISK_ARRAY[@]}"; do [[ "$d" =~ ^[a-z0-9]+$ ]] || die "invalid disk name '$d'"; done

if [ "$TARGET" = "baremetal" ]; then
    n=${#DISK_ARRAY[@]}
    case "$ZFS_RAID" in
        raid0)    [ "$n" -ge 1 ] || die "raid0 needs 1 or more disks" ;;
        raid1)    [ "$n" -ge 2 ] || die "raid1 needs 2 or more disks" ;;
        raid10)   [ "$n" -ge 4 ] && [ $((n % 2)) -eq 0 ] || die "raid10 needs 4 or more disks, an even number" ;;
        raidz-1)  [ "$n" -ge 3 ] || die "raidz-1 needs 3 or more disks" ;;
        raidz-2)  [ "$n" -ge 4 ] || die "raidz-2 needs 4 or more disks" ;;
        raidz-3)  [ "$n" -ge 5 ] || die "raidz-3 needs 5 or more disks" ;;
        *) die "invalid ZFS_RAID '$ZFS_RAID'" ;;
    esac
    [ -z "$ZFS_ARC_MAX_GIB" ] || [[ "$ZFS_ARC_MAX_GIB" =~ ^[0-9]+$ ]] || die "ZFS_ARC_MAX_GIB must be a number"
else
    [ "${#DISK_ARRAY[@]}" -eq 1 ] || die "TARGET=vps expects exactly one disk in DISK_LIST"
fi

for t in $TEMPLATES; do
    [[ "$t" =~ ^[A-Za-z0-9._/-]+$ && "$t" != *..* ]] || die "invalid template name '$t'"
done
[[ "$GENERATOR_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "$GENERATOR_REF" =~ ^[A-Za-z0-9._/-]+$ ]] \
    || die "invalid GENERATOR_REPO or GENERATOR_REF"
for c in $MGMT_ALLOWED; do
    [[ "$c" =~ ^[0-9A-Fa-f.:]+(/[0-9]{1,3})?$ ]] || die "invalid MGMT_ALLOWED entry '$c'"
done

# ---- Source ISO -------------------------------------------------------------
mkdir -p "$OUT_DIR" work
BASE_URL="https://download.proxmox.com/iso"

if [ "$PVE_ISO" = "latest" ]; then
    PVE_ISO=$(curl -fsSL "$BASE_URL/" | grep -oE 'proxmox-ve_[0-9]+\.[0-9]+-[0-9]+\.iso' | sort -uV | tail -1)
fi
[ -n "$PVE_ISO" ] || die "could not determine the Proxmox ISO"
echo "==> Source ISO: $PVE_ISO"

if [ ! -f "work/$PVE_ISO" ]; then
    curl -fL --retry 3 --retry-delay 5 -o "work/$PVE_ISO" "$BASE_URL/$PVE_ISO"
fi
echo "==> Verifying checksum"
EXPECTED=$(curl -fsSL "$BASE_URL/SHA256SUMS" | awk -v f="$PVE_ISO" '$2==f {print $1}')
[ -n "$EXPECTED" ] || die "no checksum published for $PVE_ISO"
echo "$EXPECTED  work/$PVE_ISO" | sha256sum -c -

# ---- SSH keys ---------------------------------------------------------------
echo "==> Collecting SSH keys"
KEY_SOURCES=""
[ -f config/authorized_keys ] && KEY_SOURCES=$(cat config/authorized_keys)
if [ -n "$GITHUB_KEYS_USER" ]; then
    KEY_SOURCES+=$'\n'"$(curl -fsSL "https://github.com/$GITHUB_KEYS_USER.keys" || true)"
fi
KEYS_JSON=$(printf '%s\n' "$KEY_SOURCES" | grep -E '^(ssh-|ecdsa-|sk-)' | sort -u | jq -R . | jq -cs .)
KEY_COUNT=$(echo "$KEYS_JSON" | jq length)
[ "$KEY_COUNT" -gt 0 ] || die "no SSH keys found (config/authorized_keys). The server would be unreachable."
echo "    $KEY_COUNT key(s)"

# The root password is random and never stored: login is by SSH key only.
# Set a password later with 'passwd' to use the web interface.
ROOT_HASH=$(openssl passwd -6 "$(openssl rand -base64 48)")

# ---- Answer file ------------------------------------------------------------
if [ "$NETWORK_MODE" = "static" ]; then
    NETWORK_BLOCK=$(cat <<NET
[network]
source = "from-answer"
cidr = "$IP_CIDR"
dns = "${DNS_ARRAY[0]}"
gateway = "$GATEWAY"
filter.ID_NET_NAME_MAC = "*"
NET
)
else
    NETWORK_BLOCK=$'[network]\nsource = "from-dhcp"'
fi

DISKS_JSON=$(printf '%s\n' "${DISK_ARRAY[@]}" | jq -R . | jq -cs .)
if [ "$TARGET" = "baremetal" ]; then
    DISK_BLOCK=$(cat <<DISK
[disk-setup]
filesystem = "zfs"
zfs.raid = "$ZFS_RAID"
disk-list = $DISKS_JSON
DISK
)
    [ -n "$ZFS_ARC_MAX_GIB" ] && DISK_BLOCK+=$'\n'"zfs.arc-max = $((ZFS_ARC_MAX_GIB * 1024))"
else
    DISK_BLOCK=$(cat <<DISK
[disk-setup]
filesystem = "ext4"
disk-list = $DISKS_JSON
lvm.swapsize = $SWAP_GIB
lvm.maxvz = 0
DISK
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

$DISK_BLOCK

[first-boot]
source = "from-iso"
ordering = "fully-up"
TOML

# ---- First boot script ------------------------------------------------------
ROUTES_B64=$(grep -vE '^[[:space:]]*(#|$)' config/static-routes.conf 2>/dev/null | base64 -w0 || true)
SNIPPETS=$(find config/interfaces.d -maxdepth 1 -name '*.cfg' -type f 2>/dev/null | sort || true)
SNIPPETS_B64=""
if [ -n "$SNIPPETS" ]; then
    SNIPPETS_B64=$(cd config/interfaces.d && tar -czf - -- *.cfg | base64 -w0)
fi

if [ "$IP_FORWARDING" = "auto" ]; then
    if [ -n "$ROUTES_B64" ] || [ -n "$SNIPPETS_B64" ]; then IP_FORWARDING=true; else IP_FORWARDING=false; fi
fi

sed -e "s|@@TARGET@@|$TARGET|" \
    -e "s|@@FQDN@@|$FQDN|" \
    -e "s|@@DNS_SERVERS@@|$DNS_SERVERS|" \
    -e "s|@@TEMPLATES@@|$TEMPLATES|" \
    -e "s|@@GENERATOR_REPO@@|$GENERATOR_REPO|" \
    -e "s|@@GENERATOR_REF@@|$GENERATOR_REF|" \
    -e "s|@@IP_FORWARDING@@|$IP_FORWARDING|" \
    -e "s|@@MGMT_ALLOWED@@|$MGMT_ALLOWED|" \
    -e "s|@@ROUTES_B64@@|$ROUTES_B64|" \
    -e "s|@@SNIPPETS_B64@@|$SNIPPETS_B64|" \
    scripts/first-boot.sh > work/first-boot.sh
bash -n work/first-boot.sh
if grep -q '@@' work/first-boot.sh; then die "unreplaced placeholder in first-boot.sh"; fi
[ "$(stat -c %s work/first-boot.sh)" -lt 1048576 ] || die "first-boot.sh exceeds 1 MiB"

# ---- Build ------------------------------------------------------------------
echo "==> Validating answer file"
proxmox-auto-install-assistant validate-answer work/answer.toml

echo "==> Preparing ISO"
rm -f "${OUT_DIR:?}/$OUT_NAME"
proxmox-auto-install-assistant prepare-iso "work/$PVE_ISO" \
    --fetch-from iso \
    --answer-file work/answer.toml \
    --on-first-boot work/first-boot.sh \
    --output "$OUT_DIR/$OUT_NAME"

echo "==> Inspecting result (secrets are redacted)"
proxmox-auto-install-assistant inspect-iso "$OUT_DIR/$OUT_NAME" || echo "(inspect-iso not available in this version)"

( cd "$OUT_DIR" && sha256sum "$OUT_NAME" > "$OUT_NAME.sha256" )
cat > "$OUT_DIR/build-info.env" <<INFO
PVE_ISO=$PVE_ISO
TARGET=$TARGET
NETWORK_MODE=$NETWORK_MODE
FQDN=$FQDN
INFO
echo "==> Done"
ls -lh "$OUT_DIR"
