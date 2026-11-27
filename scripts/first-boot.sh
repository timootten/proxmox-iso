#!/bin/bash
# Runs once after the first boot of the installed Proxmox VE (see [first-boot] in the answer file).
# Values marked with @@ are filled in by build-iso.sh.
set -u

LOG=/var/log/first-boot-custom.log
exec >>"$LOG" 2>&1
echo "=== first boot $(date) ==="

TEMPLATES="@@TEMPLATES@@"
GENERATOR_REPO="@@GENERATOR_REPO@@"
GENERATOR_REF="@@GENERATOR_REF@@"

# 1. One global storage: give the whole disk to the root volume
lvextend -l +100%FREE -r /dev/pve/root || echo "lvextend skipped or failed"
pvesm remove local-lvm 2>/dev/null || true
pvesm set local --content iso,vztmpl,backup,snippets,images,rootdir

# 2. SSH: key login only (root password is random and unknown)
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-hardening.conf <<'SSHD'
PermitRootLogin prohibit-password
PasswordAuthentication no
SSHD
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

# 3. Repositories: no-subscription instead of enterprise
for f in /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources; do
    [ -f "$f" ] && ! grep -q '^Enabled: no' "$f" && sed -i '$a Enabled: no' "$f"
done
cat > /etc/apt/sources.list.d/proxmox-no-subscription.sources <<'APT'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
APT

# 4. Wait for the network (max 3 minutes)
for i in $(seq 1 36); do
    ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && break
    sleep 5
done

# 5. VM templates from the template generator (optional)
if [ -n "$TEMPLATES" ]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y git libguestfs-tools wget
    rm -rf /opt/proxmox-template-generator
    git clone --depth 1 --branch "$GENERATOR_REF" "https://github.com/$GENERATOR_REPO" /opt/proxmox-template-generator
    cd /opt/proxmox-template-generator || exit 0
    for t in $TEMPLATES; do
        echo "--- template $t ---"
        DEFAULT_STORAGE=local DEFAULT_BRIDGE=vmbr0 TEMPLATE_IPCONFIG=ip=dhcp \
            bash generate-template.sh "configs/$t.conf" </dev/null || echo "template $t failed"
    done
fi

echo "=== first boot done $(date) ==="
