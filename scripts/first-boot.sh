#!/bin/bash
# Runs once after the first boot of the installed Proxmox VE ([first-boot] in the answer file).
# Placeholders between double at signs are filled in by build-iso.sh. Log: /var/log/first-boot-custom.log
set -u

LOG=/var/log/first-boot-custom.log
STATUS=/var/lib/first-boot-custom.status
exec >>"$LOG" 2>&1
echo "=== first boot $(date) ==="

TARGET="@@TARGET@@"
FQDN="@@FQDN@@"
DNS_SERVERS="@@DNS_SERVERS@@"
TEMPLATES="@@TEMPLATES@@"
HOST_AUTO_UPDATE="@@HOST_AUTO_UPDATE@@"
TEMPLATE_AUTO_REFRESH="@@TEMPLATE_AUTO_REFRESH@@"
TEMPLATES_B64="@@TEMPLATES_B64@@"
BRAND_DOCS_URL="@@BRAND_DOCS_URL@@"
BRAND_SUPPORT_URL="@@BRAND_SUPPORT_URL@@"
IP_FORWARDING="@@IP_FORWARDING@@"
MGMT_ALLOWED="@@MGMT_ALLOWED@@"
ROUTES_B64="@@ROUTES_B64@@"
SNIPPETS_B64="@@SNIPPETS_B64@@"

FAILED=()
step() {
    local name=$1
    shift
    echo "--- $name"
    if "$@"; then
        echo "ok: $name"
    else
        echo "FAILED: $name"
        FAILED+=("$name")
    fi
}

wait_for_network() {
    for _ in $(seq 1 36); do
        ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && return 0
        sleep 5
    done
    echo "no network after 3 minutes"
    return 1
}

storage_vps() {
    # One global storage: the root volume takes the whole disk
    lvextend -l +100%FREE -r /dev/pve/root || return 1
    pvesm remove local-lvm 2>/dev/null || true
    pvesm set local --content iso,vztmpl,backup,snippets,images,rootdir
}

storage_baremetal() {
    # ZFS install: "local" (directory) and "local-zfs" (VM disks) exist already
    pvesm set local --content iso,vztmpl,backup,snippets
}

ssh_hardening() {
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/10-hardening.conf <<'SSHD'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
SSHD
    sshd -t && { systemctl reload ssh 2>/dev/null || systemctl reload sshd; }
}

apt_repos() {
    local f
    for f in /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources; do
        if [ -f "$f" ] && ! grep -q '^Enabled: no' "$f"; then
            sed -i '$a Enabled: no' "$f"
        fi
    done
    cat > /etc/apt/sources.list.d/proxmox-no-subscription.sources <<'APT'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
APT
}

dns() {
    # Proxmox and glibc use at most three resolvers, the rest is ignored
    local args=(--search "${FQDN#*.}") i=1 d
    for d in $DNS_SERVERS; do
        if [ "$i" -le 3 ]; then
            args+=("--dns$i" "$d")
        else
            echo "note: resolver $d is not used (limit of three)"
        fi
        i=$((i + 1))
    done
    pvesh set "/nodes/$(hostname -s)/dns" "${args[@]}"
}

forwarding() {
    cat > /etc/sysctl.d/99-ip-forwarding.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
SYSCTL
    sysctl --system >/dev/null
}

interface_snippets() {
    mkdir -p /etc/network/interfaces.d
    echo "$SNIPPETS_B64" | base64 -d | tar -xzf - -C /etc/network/interfaces.d || return 1
    grep -q '^source /etc/network/interfaces.d/' /etc/network/interfaces \
        || echo 'source /etc/network/interfaces.d/*' >> /etc/network/interfaces
    ifreload -a
}

static_routes() {
    echo "$ROUTES_B64" | base64 -d > /etc/proxmox-static-routes.conf
    cat > /usr/local/sbin/apply-static-routes <<'APPLY'
#!/bin/bash
# Applies /etc/proxmox-static-routes.conf (syntax of "ip route", prefix "-6 " for IPv6)
rc=0
while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ "$line" == -6\ * ]]; then
        # shellcheck disable=SC2086
        ip -6 route replace ${line#-6 } || rc=1
    else
        # shellcheck disable=SC2086
        ip route replace $line || rc=1
    fi
done < /etc/proxmox-static-routes.conf
exit $rc
APPLY
    chmod 755 /usr/local/sbin/apply-static-routes
    cat > /etc/systemd/system/static-routes.service <<'UNIT'
[Unit]
Description=Apply static routes
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/apply-static-routes

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now static-routes.service
}

host_firewall() {
    local c
    {
        echo "[OPTIONS]"
        echo "enable: 1"
        echo "policy_in: DROP"
        echo "policy_out: ACCEPT"
        echo
        echo "[IPSET mgmt]"
        for c in $MGMT_ALLOWED; do echo "$c"; done
        echo
        echo "[RULES]"
        echo "IN ACCEPT -source +mgmt -p tcp -dport 22"
        echo "IN ACCEPT -source +mgmt -p tcp -dport 8006"
        echo "IN ACCEPT -p icmp"
        echo "IN ACCEPT -p ipv6-icmp"
        echo "IN ACCEPT -p udp -sport 67 -dport 68"
    } > /etc/pve/firewall/cluster.fw
    systemctl enable --now pve-firewall
}

vm_templates() {
    local storage=local
    [ "$TARGET" = "baremetal" ] && storage=local-zfs
    apt-get update || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y libguestfs-tools wget || return 1
    rm -rf /opt/template-generator
    mkdir -p /opt/template-generator
    echo "$TEMPLATES_B64" | base64 -d | tar -xzf - -C /opt/template-generator || return 1
    cd /opt/template-generator || return 1
    local t rc=0
    for t in $TEMPLATES; do
        echo "--- template $t"
        DEFAULT_STORAGE=$storage DEFAULT_BRIDGE=vmbr0 TEMPLATE_IPCONFIG=ip=dhcp \
            BRAND_DOCS_URL="$BRAND_DOCS_URL" BRAND_SUPPORT_URL="$BRAND_SUPPORT_URL" \
            bash generate-template.sh "$t" </dev/null || { echo "template $t failed"; rc=1; }
    done
    return $rc
}

host_auto_updates() {
    # Debian security updates only, no automatic reboot. Proxmox packages are updated by hand.
    apt-get update || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades || return 1
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APTC'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APTC
    cat > /etc/apt/apt.conf.d/52host-unattended <<'APTC'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
APTC
}

template_refresh() {
    local storage=local
    [ "$TARGET" = "baremetal" ] && storage=local-zfs
    cat > /etc/default/template-refresh <<ENVF
DEFAULT_STORAGE="$storage"
DEFAULT_BRIDGE="vmbr0"
TEMPLATE_IPCONFIG="ip=dhcp"
BRAND_DOCS_URL="$BRAND_DOCS_URL"
BRAND_SUPPORT_URL="$BRAND_SUPPORT_URL"
TEMPLATES="$TEMPLATES"
ENVF
    cat > /usr/local/sbin/refresh-templates <<'REFRESH'
#!/bin/bash
# Rebuilds the VM templates from the current cloud images (monthly, by template-refresh.timer).
# Templates that still have linked clones are kept: Proxmox refuses to destroy them.
set -u
. /etc/default/template-refresh
export DEFAULT_STORAGE DEFAULT_BRIDGE TEMPLATE_IPCONFIG BRAND_DOCS_URL BRAND_SUPPORT_URL ASSUME_YES=1 REFRESH_IMAGE=1
cd /opt/template-generator || exit 1
rc=0
for t in $TEMPLATES; do
    echo "--- $(date) refreshing $t"
    bash generate-template.sh "$t" </dev/null || { echo "failed: $t"; rc=1; }
done
exit $rc
REFRESH
    chmod 755 /usr/local/sbin/refresh-templates
    cat > /etc/systemd/system/template-refresh.service <<'UNIT'
[Unit]
Description=Rebuild VM templates from current cloud images
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
TimeoutStartSec=2h
ExecStart=/usr/local/sbin/refresh-templates
UNIT
    cat > /etc/systemd/system/template-refresh.timer <<'UNIT'
[Unit]
Description=Monthly VM template refresh

[Timer]
OnCalendar=monthly
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
UNIT
    systemctl daemon-reload
    systemctl enable --now template-refresh.timer
}

if [ "$TARGET" = "vps" ]; then
    step "storage (one global storage)" storage_vps
else
    step "storage (zfs)" storage_baremetal
fi
step "ssh hardening" ssh_hardening
step "apt repositories" apt_repos
step "dns" dns
step "network" wait_for_network
[ "$HOST_AUTO_UPDATE" = "security" ] && step "automatic security updates" host_auto_updates
[ "$IP_FORWARDING" = "true" ] && step "ip forwarding" forwarding
[ -n "$SNIPPETS_B64" ] && step "interface snippets" interface_snippets
[ -n "$ROUTES_B64" ] && step "static routes" static_routes
[ -n "$MGMT_ALLOWED" ] && step "host firewall" host_firewall
if [ -n "$TEMPLATES" ]; then
    step "vm templates" vm_templates
    [ "$TEMPLATE_AUTO_REFRESH" = "true" ] && step "monthly template refresh" template_refresh
fi

if [ "${#FAILED[@]}" -eq 0 ]; then
    echo "OK $(date)" > "$STATUS"
    echo "=== first boot finished without errors ==="
else
    echo "FAILED: ${FAILED[*]}" > "$STATUS"
    echo "=== first boot finished with errors: ${FAILED[*]} ==="
fi
