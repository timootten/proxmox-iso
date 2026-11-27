#!/bin/bash
# shellcheck disable=SC2016  # remote commands are single-quoted on purpose
#
# Installs a freshly built test ISO in QEMU and checks the installed system.
#   scripts/test-install.sh vps|baremetal
# Needs: qemu-system-x86, qemu-utils, openssh-client and the build tools (scripts/install-tools.sh).
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
TARGET="${1:?usage: test-install.sh vps|baremetal}"
WORK="test-$TARGET"
SSH_PORT=2222
rm -rf "$WORK"
mkdir -p "$WORK"

ssh-keygen -q -t ed25519 -N '' -f "$WORK/key"

DISKS="sda"
DISK_COUNT=1
if [ "$TARGET" = "baremetal" ]; then DISKS="sda sdb"; DISK_COUNT=2; fi

echo "==> Building test ISO ($TARGET)"
TARGET="$TARGET" IP_CIDR=10.0.2.15/24 GATEWAY=10.0.2.2 IPV6_CIDR=fec0::10/64 IPV6_GATEWAY=fec0::2 \
    FQDN=pve-test.example.com TEMPLATE_SET=none TEMPLATES="" \
    DISK_LIST="$DISKS" ZFS_RAID=raid1 ZFS_ARC_MAX_GIB="" OUT_DIR="$WORK/out" \
    EXTRA_SSH_KEYS="$(cat "$WORK/key.pub")" EXTRA_STATIC_ROUTES="10.99.0.0/24 via 10.0.2.2" \
    MGMT_ALLOWED="" IP_FORWARDING=auto \
    ./scripts/build-iso.sh
ISO="$WORK/out/proxmox-ve-auto.iso"

ACCEL=(-accel tcg -cpu max)
INSTALL_TIMEOUT=3600
if [ -w /dev/kvm ]; then
    ACCEL=(-enable-kvm -cpu host)
    INSTALL_TIMEOUT=1500
else
    echo "WARNING: no /dev/kvm, falling back to slow software emulation"
fi

DISK_ARGS=()
for i in $(seq "$DISK_COUNT"); do
    qemu-img create -q -f qcow2 "$WORK/disk$i.qcow2" 40G
    DISK_ARGS+=(-drive "if=none,id=d$i,file=$WORK/disk$i.qcow2,format=qcow2" -device "scsi-hd,drive=d$i,bus=scsi0.0")
done

COMMON=("${ACCEL[@]}" -m 6144 -smp 2 -display none -monitor none
        -device "virtio-scsi-pci,id=scsi0" "${DISK_ARGS[@]}")

echo "==> Installing (timeout ${INSTALL_TIMEOUT}s)"
timeout "$INSTALL_TIMEOUT" qemu-system-x86_64 "${COMMON[@]}" -no-reboot \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -cdrom "$ISO" -boot order=d \
    || { echo "FAIL: installation did not finish (exit $?)"; exit 1; }

echo "==> Booting the installed system"
qemu-system-x86_64 "${COMMON[@]}" -boot order=c \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" -device virtio-net-pci,netdev=n0 \
    -daemonize -pidfile "$WORK/qemu.pid"
trap 'kill "$(cat "$WORK/qemu.pid")" 2>/dev/null || true' EXIT

SSH=(ssh -i "$WORK/key" -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes root@127.0.0.1)

echo "==> Waiting for SSH"
for _ in $(seq 1 120); do
    "${SSH[@]}" true 2>/dev/null && break
    sleep 10
done
"${SSH[@]}" true || { echo "FAIL: SSH is not reachable"; exit 1; }

echo "==> Waiting for the first boot script"
for _ in $(seq 1 90); do
    "${SSH[@]}" 'test -f /var/lib/first-boot-custom.status' 2>/dev/null && break
    sleep 10
done

FAIL=0
check() {
    local desc=$1 cmd=$2
    if "${SSH[@]}" "$cmd" >/dev/null 2>&1; then
        echo "ok    $desc"
    else
        echo "FAIL  $desc"
        FAIL=1
    fi
}

echo "==> Checks"
check "first boot finished without errors" 'grep -q "^OK" /var/lib/first-boot-custom.status'
check "Proxmox VE installed" 'pveversion | grep -q "^pve-manager/9"'
check "web interface answers on 8006" '[ "$(curl -sk -o /dev/null -w "%{http_code}" https://localhost:8006)" = 200 ]'
check "SSH password login is off" 'sshd -T | grep -qi "^passwordauthentication no"'
check "DNS resolvers set" 'grep -q "nameserver 1.1.1.1" /etc/resolv.conf && grep -q "nameserver 8.8.8.8" /etc/resolv.conf'
check "enterprise repository disabled" 'grep -q "^Enabled: no" /etc/apt/sources.list.d/pve-enterprise.sources'
check "static route applied" 'ip route | grep -q "^10.99.0.0/24"'
check "IP forwarding on" '[ "$(sysctl -n net.ipv4.ip_forward)" = 1 ]'
check "subscription pop-up hidden" 'grep -q "void({ //Ext.Msg.show" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js'
check "fail2ban jails sshd and proxmox" 'fail2ban-client status | grep -q sshd && fail2ban-client status | grep -q proxmox'
check "rpcbind is off" '! systemctl is-active --quiet rpcbind'
check "static IPv4 on vmbr0" 'ip -4 addr show vmbr0 | grep -q "10.0.2.15/24"'
check "static IPv6 on vmbr0" 'ip -6 addr show vmbr0 | grep -q "fec0::10/64"'
check "private network vmbr1 is up" 'ip -4 addr show vmbr1 | grep -q "10.10.0.1/24"'
check "NAT rule for vmbr1" 'iptables -t nat -S POSTROUTING | grep -q "10.10.0.0/24.*MASQUERADE"'
check "dnsmasq runs and DNS is bound to vmbr1 only" 'systemctl is-active --quiet dnsmasq && ! ss -lunH | awk "{print \$4}" | grep -E ":53$" | grep -vE "^(10\.10\.0\.1|127\.0\.0\.1|\[::1\]):53$" | grep -q .'
check "unattended security updates enabled" 'grep -q "Unattended-Upgrade \"1\"" /etc/apt/apt.conf.d/20auto-upgrades'
if [ "$TARGET" = "vps" ]; then
    check "one global storage (local, no local-lvm)" 'pvesm status | awk "NR>1 {print \$1}" | grep -qx local && ! pvesm status | grep -q local-lvm'
    check "global storage holds VM disks" 'pvesm status --content images | awk "NR>1 {print \$1}" | grep -qx local'
    check "root volume uses the whole disk" '[ "$(df -BG --output=size / | tail -1 | tr -dc 0-9)" -gt 30 ]'
else
    check "ZFS mirror is online" 'zpool status rpool | grep -q "mirror-0" && zpool status rpool | grep -q ONLINE'
    check "local-zfs storage exists" 'pvesm status | awk "NR>1 {print \$1}" | grep -qx local-zfs'
fi

if [ "$FAIL" -ne 0 ]; then
    echo "==> first-boot log"
    "${SSH[@]}" 'systemctl status dnsmasq --no-pager; ss -lunp; cat /var/log/first-boot-custom.log' || true
    exit 1
fi
echo "==> All checks passed ($TARGET)"
