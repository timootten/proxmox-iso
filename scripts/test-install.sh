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
    FQDN=pve-test.example.com TEMPLATE_SET="${TEST_TEMPLATES:+minimal}" TEMPLATES="" \
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
for _ in $(seq 1 150); do
    "${SSH[@]}" 'test -f /var/lib/first-boot-custom.status' 2>/dev/null && break
    sleep 10
done

BOOT_ID=$("${SSH[@]}" 'cat /proc/sys/kernel/random/boot_id')
echo "==> Waiting up to 4 minutes for the reboot into the new kernel (only happens when a newer kernel was installed)"
REBOOTED=false
for _ in $(seq 1 24); do
    NOW=$("${SSH[@]}" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || echo down)
    if [ "$NOW" != "$BOOT_ID" ]; then REBOOTED=true; break; fi
    sleep 10
done
if [ "$REBOOTED" = "true" ]; then
    echo "    rebooted, waiting for SSH and the kernel cleanup"
    for _ in $(seq 1 60); do "${SSH[@]}" true 2>/dev/null && break; sleep 5; done
    for _ in $(seq 1 60); do
        "${SSH[@]}" 'test ! -f /var/lib/kernel-cleanup.pending' 2>/dev/null && break
        sleep 5
    done
else
    echo "    no reboot (the installed kernel was already the newest)"
fi

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

echo "==> System information"
"${SSH[@]}" 'echo "running kernel: $(uname -r)"; echo "installed kernels:"; ls /boot/vmlinuz-*; apt-cache policy proxmox-default-kernel | head -4; pveversion; echo \"boot: $(uptime -s)\"; grep -E "kernel .* is installed|rebooting|could not be installed|^(ok|FAILED):" /var/log/first-boot-custom.log' || true

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
check "dnsmasq runs, serves no DNS and hands the public resolvers to the VMs" 'systemctl is-active --quiet dnsmasq && ! ss -lunH | awk "{print \$4}" | grep -qE ":53$" && grep -q "^dhcp-option=option:dns-server,1.1.1.1,8.8.8.8$" /etc/dnsmasq.d/vmbr1.conf'
check "only one kernel is installed and it is the running one" '[ "$(ls /boot/vmlinuz-* | wc -l)" = 1 ] && [ "/boot/vmlinuz-$(uname -r)" = "$(ls /boot/vmlinuz-*)" ]'
check "tools installed" 'for c in curl wget fastfetch iperf3 btop htop; do command -v $c >/dev/null || exit 1; done'
check "no pending upgrades" '[ "$(apt-get update -qq >/dev/null 2>&1; apt-get -s dist-upgrade | grep -c "^Inst ")" = 0 ]'
check "login banner installed" '[ -x /usr/local/bin/dynamic-motd ] && /usr/local/bin/dynamic-motd | grep -q "Welcome to" && [ -f /etc/profile.d/99-andotta-motd.sh ]'
check "custom prompt for root" 'bash -ic "echo \$PS1" 2>/dev/null | grep -q "38;5;1m"'
check "private IPv6 on vmbr1" 'ip -6 addr show vmbr1 | grep -q "fd10:10::1/64"'
check "NAT66 rule for vmbr1" 'ip6tables -t nat -S POSTROUTING | grep -q "fd10:10::/64.*MASQUERADE"'
check "router advertisements with the IPv6 resolvers" 'grep -q "^enable-ra" /etc/dnsmasq.d/vmbr1.conf && grep -q "option6:dns-server,\[2606:4700:4700::1111\],\[2001:4860:4860::8888\]" /etc/dnsmasq.d/vmbr1.conf'
check "unattended security updates enabled" 'grep -q "Unattended-Upgrade \"1\"" /etc/apt/apt.conf.d/20auto-upgrades'
if [ "$TARGET" = "vps" ]; then
    check "one global storage (local, no local-lvm)" 'pvesm status | awk "NR>1 {print \$1}" | grep -qx local && ! pvesm status | grep -q local-lvm'
    check "global storage holds VM disks" 'pvesm status --content images | awk "NR>1 {print \$1}" | grep -qx local'
    check "root volume uses the whole disk" '[ "$(df -BG --output=size / | tail -1 | tr -dc 0-9)" -gt 30 ]'
else
    check "ZFS mirror is online" 'zpool status rpool | grep -q "mirror-0" && zpool status rpool | grep -q ONLINE'
    check "local-zfs storage exists" 'pvesm status | awk "NR>1 {print \$1}" | grep -qx local-zfs'
fi

if [ -n "${TEST_TEMPLATES:-}" ]; then
    echo "==> Template and clone test (slow: the clone starts without hardware acceleration)"
    check "template 9013 exists on the private bridge with the SSH key" 'qm config 9013 | grep -q "^template: 1" && qm config 9013 | grep -q "bridge=vmbr1" && qm config 9013 | grep -q "^sshkeys:"'
    check "linked clone can be created" 'qm clone 9013 100 --name clonetest && qm config 100 | grep -q "base-9013"'
    check "clone starts" '! test -w /dev/kvm && qm set 100 --kvm 0 --cpu qemu64 >/dev/null; qm start 100'
    echo "    waiting for the DHCP lease of the clone (up to 15 minutes)"
    for _ in $(seq 1 90); do
        "${SSH[@]}" 'grep -q "10\.10\.0\." /var/lib/misc/dnsmasq.leases' 2>/dev/null && break
        sleep 10
    done
    check "clone got an IPv4 address of the private network" 'grep -q "10\.10\.0\." /var/lib/misc/dnsmasq.leases'
    for _ in $(seq 1 60); do
        "${SSH[@]}" 'qm agent 100 ping' >/dev/null 2>&1 && break
        sleep 10
    done
    check "clone got an IPv6 address of the private network" 'qm guest cmd 100 network-get-interfaces | grep -q "fd10:10:"'
    "${SSH[@]}" 'cat /var/lib/misc/dnsmasq.leases; qm guest cmd 100 network-get-interfaces | head -c 1500' || true
fi

if [ "$FAIL" -ne 0 ]; then
    echo "==> first-boot log"
    "${SSH[@]}" 'systemctl status dnsmasq --no-pager; ss -lunp; cat /var/log/first-boot-custom.log' || true
    exit 1
fi
echo "==> All checks passed ($TARGET)"
