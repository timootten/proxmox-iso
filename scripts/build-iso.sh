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
IP_CIDR="${IP_CIDR:-}"
GATEWAY="${GATEWAY:-}"
DNS_SERVERS="${DNS_SERVERS:-1.1.1.1 8.8.8.8 2606:4700:4700::1111 2001:4860:4860::8888}"
DISK_LIST="${DISK_LIST:-sda}"
ZFS_RAID="${ZFS_RAID:-raid1}"
ZFS_ARC_MAX_GIB="${ZFS_ARC_MAX_GIB:-}"
SWAP_GIB="${SWAP_GIB:-4}"
ROOT_INSTALL_GIB="${ROOT_INSTALL_GIB:-20}"
IPV6_CIDR="${IPV6_CIDR:-}"
IPV6_GATEWAY="${IPV6_GATEWAY:-}"
IPV6_GATEWAY_ONLINK="${IPV6_GATEWAY_ONLINK:-true}"
PRIVATE_NET="${PRIVATE_NET:-true}"
PRIVATE_NET_CIDR="${PRIVATE_NET_CIDR:-10.10.0.1/24}"
PRIVATE_NET_NAT="${PRIVATE_NET_NAT:-true}"
PRIVATE_NET_DHCP="${PRIVATE_NET_DHCP:-true}"
HARDENING="${HARDENING:-true}"
SUBSCRIPTION_NAG="${SUBSCRIPTION_NAG:-hide}"
IP_FORWARDING="${IP_FORWARDING:-auto}"
MGMT_ALLOWED="${MGMT_ALLOWED:-}"
HOST_AUTO_UPDATE="${HOST_AUTO_UPDATE:-security}"
TEMPLATE_AUTO_REFRESH="${TEMPLATE_AUTO_REFRESH:-true}"
TEMPLATE_LANG="${TEMPLATE_LANG:-de}"
TEMPLATE_SET="${TEMPLATE_SET:-none}"
TEMPLATES="${TEMPLATES:-}"
BRAND_DOCS_URL="${BRAND_DOCS_URL:-}"
BRAND_SUPPORT_URL="${BRAND_SUPPORT_URL:-}"
EXTRA_SSH_KEYS="${EXTRA_SSH_KEYS:-}"
EXTRA_STATIC_ROUTES="${EXTRA_STATIC_ROUTES:-}"
OUT_DIR="${OUT_DIR:-out}"
OUT_NAME="${OUT_NAME:-proxmox-ve-auto.iso}"

# ---- Validation -------------------------------------------------------------
for cmd in proxmox-auto-install-assistant xorriso curl jq openssl; do
    command -v "$cmd" >/dev/null || die "missing tool: $cmd"
done

case "$TARGET" in vps|baremetal) ;; *) die "TARGET must be vps or baremetal" ;; esac
case "$HOST_AUTO_UPDATE" in security|none) ;; *) die "HOST_AUTO_UPDATE must be security or none" ;; esac
case "$TEMPLATE_AUTO_REFRESH" in true|false) ;; *) die "TEMPLATE_AUTO_REFRESH must be true or false" ;; esac
for v in IPV6_GATEWAY_ONLINK PRIVATE_NET PRIVATE_NET_NAT PRIVATE_NET_DHCP HARDENING; do
    case "${!v}" in true|false) ;; *) die "$v must be true or false" ;; esac
done
case "$SUBSCRIPTION_NAG" in hide|keep) ;; *) die "SUBSCRIPTION_NAG must be hide or keep" ;; esac
case "$IP_FORWARDING" in auto|true|false) ;; *) die "IP_FORWARDING must be auto, true or false" ;; esac

[[ "$FQDN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] \
    || die "FQDN needs a hostname and a domain, got '$FQDN'"
[[ "$SWAP_GIB" =~ ^[0-9]+$ ]] || die "SWAP_GIB must be a number"
[[ "$ROOT_INSTALL_GIB" =~ ^[0-9]+$ && "$ROOT_INSTALL_GIB" -ge 8 ]] || die "ROOT_INSTALL_GIB must be a number of at least 8"
[[ "$KEYBOARD" =~ ^[a-z-]+$ && "$COUNTRY" =~ ^[a-z]{2}$ ]] || die "invalid KEYBOARD or COUNTRY"
[[ "$PVE_ISO" == "latest" || "$PVE_ISO" =~ ^proxmox-ve_[0-9]+\.[0-9]+-[0-9]+\.iso$ ]] || die "invalid PVE_ISO"

ip_re='^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9A-Fa-f:]+$'
if [ -z "$IP_CIDR$IPV6_CIDR" ]; then
    die "set an IPv4 address (IP_CIDR + GATEWAY) or an IPv6 address (IPV6_CIDR + IPV6_GATEWAY), or both. DHCP is not supported."
fi
if [ -n "$IP_CIDR$GATEWAY" ]; then
    [[ "$IP_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die "IP_CIDR needs the prefix as well, like 192.0.2.10/24 (got '$IP_CIDR')"
    [[ "$GATEWAY" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "GATEWAY is required together with IP_CIDR, for example 192.0.2.1"
fi
if [ -n "$IPV6_CIDR$IPV6_GATEWAY" ]; then
    [[ "$IPV6_CIDR" =~ ^[0-9A-Fa-f:]+:[0-9A-Fa-f:]*/[0-9]{1,3}$ ]] || die "IPV6_CIDR needs the prefix as well, like 2001:db8::10/64 (got '$IPV6_CIDR')"
    [[ "$IPV6_GATEWAY" =~ ^[0-9A-Fa-f:]+$ ]] || die "IPV6_GATEWAY is required together with IPV6_CIDR"
fi
command -v python3 >/dev/null || die "missing tool: python3"
if [ -n "$IP_CIDR" ]; then
    python3 -c 'import ipaddress,sys; i=ipaddress.ip_interface(sys.argv[1]); sys.exit(0 if ipaddress.ip_address(sys.argv[2]) in i.network else 1)' "$IP_CIDR" "$GATEWAY" \
        || echo "WARNING: the IPv4 gateway $GATEWAY is outside of $IP_CIDR. The installer may reject this, see README (routed gateways)." >&2
fi

[ "$PRIVATE_NET_CIDR" = "none" ] && PRIVATE_NET=false
if [ "$PRIVATE_NET" = "true" ] && [ -z "$IP_CIDR" ] && [ "$PRIVATE_NET_NAT" = "true" ]; then
    echo "NOTE: no IPv4 uplink, source NAT for the private network is switched off." >&2
    PRIVATE_NET_NAT=false
fi

# Private network: derive network, mask and DHCP range from PRIVATE_NET_CIDR
PRIVATE_NET_NETWORK="" PRIVATE_NET_ADDRESS="" PRIVATE_NET_MASK="" PRIVATE_NET_DHCP_START="" PRIVATE_NET_DHCP_END=""
if [ "$PRIVATE_NET" = "true" ]; then
    command -v python3 >/dev/null || die "missing tool: python3"
    # shellcheck disable=SC2034  # exported through the generated settings below
    read -r PRIVATE_NET_NETWORK PRIVATE_NET_ADDRESS PRIVATE_NET_MASK PRIVATE_NET_DHCP_START PRIVATE_NET_DHCP_END < <(
        python3 - "$PRIVATE_NET_CIDR" <<'PY' || true
import ipaddress, sys
i = ipaddress.ip_interface(sys.argv[1])
n = i.network
if not (n.version == 4 and 16 <= n.prefixlen <= 24 and n.is_private):
    sys.exit(1)
print(n, i.ip, n.netmask, n.network_address + 100, n.network_address + 200)
PY
    ) || true
    [ -n "$PRIVATE_NET_NETWORK" ] || die "PRIVATE_NET_CIDR must be a private IPv4 address with a /16 to /24 prefix, like 10.10.0.1/24"
fi

read -r -a DNS_ARRAY <<< "$DNS_SERVERS"
[ "${#DNS_ARRAY[@]}" -ge 1 ] || die "DNS_SERVERS is empty"
for d in "${DNS_ARRAY[@]}"; do [[ "$d" =~ $ip_re ]] || die "invalid DNS server '$d'"; done
if [ -z "$IP_CIDR" ]; then
    # IPv6 only: IPv6 resolvers first, IPv4 resolvers cannot be reached anyway
    DNS_SERVERS=$(printf '%s\n' "${DNS_ARRAY[@]}" | awk '/:/ {print "6 " $0; next} {print "4 " $0}' | sort -s -k1,1r | cut -d' ' -f2 | tr '\n' ' ' | sed 's/ $//')
    read -r -a DNS_ARRAY <<< "$DNS_SERVERS"
fi

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

[[ "$TEMPLATE_LANG" =~ ^(de|en)$ ]] || die "TEMPLATE_LANG must be de or en"
[[ "$BRAND_DOCS_URL$BRAND_SUPPORT_URL" =~ ^[A-Za-z0-9:/._?=#%+~-]*$ ]] || die "invalid characters in BRAND_*_URL"

# Resolve the template set and the extra names into one list
SET_NAMES=""
case "$TEMPLATE_SET" in
    none) ;;
    all)  SET_NAMES=$(cd "templates/configs/$TEMPLATE_LANG" && find . -name '*.conf' | sed 's|^\./||; s|\.conf$||' | sort | tr '\n' ' ') ;;
    *)    SET_NAMES=$(awk -F= -v k="$TEMPLATE_SET" '$1==k {print $2}' templates/sets.env)
          [ -n "$SET_NAMES" ] || die "unknown TEMPLATE_SET '$TEMPLATE_SET' (see templates/sets.env)" ;;
esac
TEMPLATE_LIST=$(echo "$SET_NAMES $TEMPLATES" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed 's/ $//')
TEMPLATE_FILES=()
for t in $TEMPLATE_LIST; do
    [[ "$t" =~ ^[A-Za-z0-9._/-]+$ && "$t" != *..* ]] || die "invalid template name '$t'"
    [ -f "templates/configs/$TEMPLATE_LANG/$t.conf" ] || die "template '$t' does not exist in templates/configs/$TEMPLATE_LANG/"
    TEMPLATE_FILES+=("configs/$TEMPLATE_LANG/$t.conf")
done
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
KEY_SOURCES="$EXTRA_SSH_KEYS"
[ -f config/authorized_keys ] && KEY_SOURCES+=$'\n'"$(cat config/authorized_keys)"
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
# The installer takes one address. IPv4 if there is one, the IPv6 address is added on the first boot.
if [ -n "$IP_CIDR" ]; then
    INSTALL_CIDR="$IP_CIDR"; INSTALL_GATEWAY="$GATEWAY"
    INSTALL_DNS=$(printf '%s\n' "${DNS_ARRAY[@]}" | grep -v ':' | head -1)
else
    INSTALL_CIDR="$IPV6_CIDR"; INSTALL_GATEWAY="$IPV6_GATEWAY"
    INSTALL_DNS="${DNS_ARRAY[0]}"
fi
[ -n "$INSTALL_DNS" ] || die "DNS_SERVERS needs at least one resolver of the address family you use"
NETWORK_BLOCK=$(cat <<NET
[network]
source = "from-answer"
cidr = "$INSTALL_CIDR"
dns = "$INSTALL_DNS"
gateway = "$INSTALL_GATEWAY"
filter.ID_NET_NAME_MAC = "*"
NET
)

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
lvm.maxroot = $ROOT_INSTALL_GIB
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
reboot-mode = "power-off"

$NETWORK_BLOCK

$DISK_BLOCK

[first-boot]
source = "from-iso"
ordering = "fully-up"
TOML

# ---- First boot script ------------------------------------------------------
ROUTES_B64=$({ cat config/static-routes.conf 2>/dev/null || true; printf '\n%s\n' "$EXTRA_STATIC_ROUTES"; } | grep -vE '^[[:space:]]*(#|$)' | base64 -w0 || true)
SNIPPETS=$(find config/interfaces.d -maxdepth 1 -name '*.cfg' -type f 2>/dev/null | sort || true)
SNIPPETS_B64=""
if [ -n "$SNIPPETS" ]; then
    SNIPPETS_B64=$(cd config/interfaces.d && tar -czf - -- *.cfg | base64 -w0)
fi

TEMPLATES_B64=""
if [ "${#TEMPLATE_FILES[@]}" -gt 0 ]; then
    # shellcheck disable=SC2034
    TEMPLATES_B64=$(tar -czf - -C templates generate-template.sh global.conf motd.sh "${TEMPLATE_FILES[@]}" | base64 -w0)
fi

if [ "$IP_FORWARDING" = "auto" ]; then
    if [ -n "$ROUTES_B64" ] || [ -n "$SNIPPETS_B64" ] || [ "$PRIVATE_NET" = "true" ]; then IP_FORWARDING=true; else IP_FORWARDING=false; fi
fi

# Settings are written with printf %q, so every value is quoted safely
{
    echo "# --- generated by build-iso.sh ---"
    for v in TARGET FQDN KEYBOARD DNS_SERVERS HOST_AUTO_UPDATE HARDENING SUBSCRIPTION_NAG IP_FORWARDING MGMT_ALLOWED \
             IP_CIDR IPV6_CIDR IPV6_GATEWAY IPV6_GATEWAY_ONLINK \
             PRIVATE_NET PRIVATE_NET_NETWORK PRIVATE_NET_ADDRESS PRIVATE_NET_MASK PRIVATE_NET_NAT PRIVATE_NET_DHCP \
             PRIVATE_NET_DHCP_START PRIVATE_NET_DHCP_END \
             TEMPLATE_AUTO_REFRESH BRAND_DOCS_URL BRAND_SUPPORT_URL \
             ROUTES_B64 SNIPPETS_B64 TEMPLATES_B64; do
        printf '%s=%q\n' "$v" "${!v}"
    done
    printf 'PRIVATE_NET_CIDR=%q\n' "$PRIVATE_NET_CIDR"
    printf 'TEMPLATES=%q\n' "${TEMPLATE_FILES[*]:-}"
    echo "# --- end of generated settings ---"
} > work/settings.sh

awk 'FNR==NR { settings = settings $0 "\n"; next } /^#@@SETTINGS@@$/ { printf "%s", settings; next } { print }' \
    work/settings.sh scripts/first-boot.sh > work/first-boot.sh
bash -n work/first-boot.sh
grep -q '^TARGET=' work/first-boot.sh || die "settings were not inserted into first-boot.sh"
FB_SIZE=$(stat -c %s work/first-boot.sh)
[ "$FB_SIZE" -lt 1000000 ] || die "first-boot.sh is $FB_SIZE bytes, the limit is 1 MiB"
echo "==> first-boot.sh: $FB_SIZE bytes, templates: ${TEMPLATE_FILES[*]:-none}"

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
FQDN=$FQDN
TEMPLATE_LIST="${TEMPLATE_LIST:-none}"
INFO
echo "==> Done"
ls -lh "$OUT_DIR"
