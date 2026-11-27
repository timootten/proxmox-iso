#!/bin/bash
#
# Proxmox Template Generator - Pure Bash Version
# Simple, fast, and native to Proxmox environment
#
# Usage: ./generate-template.sh <config_file>
#

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# ============================================================================
# CONFIGURATION
# ============================================================================

# Load global configuration first
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GLOBAL_CONFIG="$SCRIPT_DIR/global.conf"
if [ -f "$GLOBAL_CONFIG" ]; then
    source "$GLOBAL_CONFIG"
fi

# Config file is required
if [ $# -ne 1 ]; then
    echo "Usage: $0 <config_file>"
    echo ""
    echo "Examples:"
    echo "  $0 configs/debian-13.conf"
    echo "  $0 configs/ubuntu-24.04.conf"
    echo "  $0 configs/customs/debian-13-docker.conf"
    echo ""
    echo "Available configs:"
    echo "  Base templates:   configs/*.conf"
    echo "  Custom templates: configs/customs/*.conf"
    echo "  Examples:         configs/examples/*.conf"
    exit 1
fi

CONFIG_FILE="$1"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

# Dynamic MOTD comes from motd.sh (global.conf may still override MOTD_SCRIPT)
if [ -z "${MOTD_SCRIPT:-}" ] && [ -f "$SCRIPT_DIR/motd.sh" ]; then
    MOTD_SCRIPT=$(sed -e "s|@@BRAND_DOCS_URL@@|${BRAND_DOCS_URL:-}|g" \
                      -e "s|@@BRAND_SUPPORT_URL@@|${BRAND_SUPPORT_URL:-}|g" "$SCRIPT_DIR/motd.sh")
fi
MOTD_SCRIPT="${MOTD_SCRIPT:-}"

# Validate required variables
if [ -z "${VM_ID:-}" ]; then
    echo "Error: VM_ID is not set in config file"
    exit 1
fi

if [ -z "${IMAGE_URL:-}" ]; then
    echo "Error: IMAGE_URL is not set in config file"
    exit 1
fi

# Apply global defaults for storage and bridge if not set
VM_STORAGE=${VM_STORAGE:-${DEFAULT_STORAGE:-"local-zfs"}}
VM_BRIDGE=${VM_BRIDGE:-${DEFAULT_BRIDGE:-"vmbr0"}}

# Set defaults for optional variables
ENABLE_ROOT_PASSWORD_LOGIN=${ENABLE_ROOT_PASSWORD_LOGIN:-false}
EXTRA_PACKAGES=${EXTRA_PACKAGES:-""}
POST_INSTALL_CMD1=${POST_INSTALL_CMD1:-""}
POST_INSTALL_CMD2=${POST_INSTALL_CMD2:-""}
POST_INSTALL_CMD3=${POST_INSTALL_CMD3:-""}
POST_INSTALL_CMD4=${POST_INSTALL_CMD4:-""}
POST_INSTALL_CMD5=${POST_INSTALL_CMD5:-""}
KEYBOARD_LAYOUT=${KEYBOARD_LAYOUT:-"de"}
KEYBOARD_MODEL=${KEYBOARD_MODEL:-"pc105"}
LOCALE=${LOCALE:-"de_DE.UTF-8"}
LANGUAGE=${LANGUAGE:-"de_DE:de"}

# ============================================================================
# CONSTANTS
# ============================================================================

WORK_DIR="/var/lib/vz/template/iso"
LOG_FILE="template-generator.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ============================================================================
# FUNCTIONS
# ============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${CYAN}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "$LOG_FILE"
}

print_header() {
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Proxmox Template Generator (Bash)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo
}

print_step() {
    local step=$1
    local total=$2
    local message=$3
    echo -e "${YELLOW}[${step}/${total}]${NC} ${message}"
}

check_requirements() {
    log_info "Checking requirements..."
    
    # Check if running as root or with sudo
    if [ "$EUID" -ne 0 ]; then 
        log_error "This script must be run as root or with sudo"
        return 1
    fi
    
    # Check if running on Proxmox
    if [ ! -f /etc/pve/.version ]; then
        log_warning "This script is designed for Proxmox VE"
        log_warning "Some features may not work on other systems"
    fi
    
    # Check available disk space (need at least 5GB for image download and processing)
    local available_space=$(df -BG "$WORK_DIR" 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ -n "$available_space" ] && [ "$available_space" -lt 5 ]; then
        log_warning "Low disk space in $WORK_DIR: ${available_space}GB available"
        log_warning "At least 5GB recommended for image operations"
    fi
    
    local missing=()
    
    for cmd in qm virt-customize wget; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_warning "Missing required commands: ${missing[*]}"
        log_info "Installing missing packages..."
        
        # Detect package manager
        if command -v apt &> /dev/null; then
            apt update >> "$LOG_FILE" 2>&1 || {
                log_error "Failed to update package lists"
                return 1
            }
            
            apt install -y libguestfs-tools wget 2>&1 | tee -a "$LOG_FILE" | grep --line-buffered -E '(Progress|Setting up|Processing triggers)'
            
            if [ ${PIPESTATUS[0]} -ne 0 ]; then
                log_error "Failed to install required packages"
                log_error "Please run manually: apt update && apt install -y libguestfs-tools wget"
                return 1
            fi
        else
            log_error "Unsupported package manager. Please install: ${missing[*]}"
            return 1
        fi
        
        log_success "Required packages installed successfully"
    fi
    
    log_success "All requirements met"
    return 0
}

download_image() {
    local filename=$(basename "$IMAGE_URL")
    local dest_path="$WORK_DIR/$filename"
    
    # Create work directory
    if ! mkdir -p "$WORK_DIR" 2>/dev/null; then
        log_error "Failed to create work directory: $WORK_DIR"
        return 1
    fi
    
    # REFRESH_IMAGE=1 always fetches the current image (used by the scheduled refresh)
    if [ "${REFRESH_IMAGE:-}" = "1" ]; then
        rm -f "$dest_path"
    fi

    # Download if not exists
    if [ -f "$dest_path" ]; then
        log_info "Image already exists: $dest_path" >&2
        
        # Verify the file is not corrupted (basic check)
        if [ ! -s "$dest_path" ]; then
            log_warning "Existing image appears to be empty, redownloading..." >&2
            rm -f "$dest_path"
        fi
    fi
    
    if [ ! -f "$dest_path" ]; then
        log_info "Downloading from: $IMAGE_URL" >&2
        
        # Try wget with timeout
        if ! wget --timeout=30 --tries=3 --progress=bar:force:noscroll --show-progress -O "$dest_path" "$IMAGE_URL" >&2; then
            log_error "Download failed" >&2
            rm -f "$dest_path"  # Clean up partial download
            return 1
        fi
        
        log_success "Download completed" >&2
    fi
    
    echo "$dest_path"
}

customize_image() {
    local image_path=$1
    
    log_info "Customizing image..."
    
    # Build packages list (base + utilities)
    local packages="qemu-guest-agent,cloud-init,cloud-initramfs-growroot"
    packages="$packages,sudo,htop,curl,vim,wget,git,net-tools,dnsutils,ncdu,tmux,rsync"
    packages="$packages,wireless-regdb,locales,console-setup,keyboard-configuration"
    
    # Add extra packages if specified
    if [ -n "$EXTRA_PACKAGES" ]; then
        local extra=$(echo "$EXTRA_PACKAGES" | tr ' ' ',')
        packages="$packages,$extra"
        log_info "Adding extra packages: $EXTRA_PACKAGES"
    fi
    
    # Create temporary script for bashrc customization
    local bashrc_script=$(mktemp)
    cat > "$bashrc_script" << 'BASHRC_EOF'
#!/bin/bash
# Add custom PS1 to /etc/skel/.bashrc and /root/.bashrc
CUSTOM_PS1='export PS1="\[\e[38;5;1m\]\u\[\e[38;5;7m\]@\[\e[38;5;14m\]\h \[\e[38;5;11m\]\w \[\033[0m\]$ "'

echo "" >> /etc/skel/.bashrc
echo "# Custom PS1 prompt" >> /etc/skel/.bashrc
echo "$CUSTOM_PS1" >> /etc/skel/.bashrc
echo "" >> /etc/skel/.bashrc
echo "# Custom aliases" >> /etc/skel/.bashrc
echo "alias ll='ls -lah'" >> /etc/skel/.bashrc
echo "alias update='apt update && apt upgrade -y'" >> /etc/skel/.bashrc
echo "alias clean='apt autoremove -y && apt autoclean'" >> /etc/skel/.bashrc

# Also apply to root
echo "" >> /root/.bashrc
echo "# Custom PS1 prompt" >> /root/.bashrc
echo "$CUSTOM_PS1" >> /root/.bashrc
echo "" >> /root/.bashrc
echo "# Custom aliases" >> /root/.bashrc
echo "alias ll='ls -lah'" >> /root/.bashrc
echo "alias update='apt update && apt upgrade -y'" >> /root/.bashrc
echo "alias clean='apt autoremove -y && apt autoclean'" >> /root/.bashrc
echo "" >> /root/.bashrc
echo "# Show dynamic MOTD on interactive login" >> /root/.bashrc
echo 'if [ -n "$PS1" ] && [ -x /usr/local/bin/dynamic-motd ]; then' >> /root/.bashrc
echo '    /usr/local/bin/dynamic-motd' >> /root/.bashrc
echo 'fi' >> /root/.bashrc

# Also add to skel for new users
echo "" >> /etc/skel/.bashrc
echo "# Show dynamic MOTD on interactive login" >> /etc/skel/.bashrc
echo 'if [ -n "$PS1" ] && [ -x /usr/local/bin/dynamic-motd ]; then' >> /etc/skel/.bashrc
echo '    /usr/local/bin/dynamic-motd' >> /etc/skel/.bashrc
echo 'fi' >> /etc/skel/.bashrc
BASHRC_EOF
    chmod +x "$bashrc_script"
    
    # Create dynamic MOTD script
    local motd_script=$(mktemp)
    cat > "$motd_script" << 'MOTD_EOF'
#!/bin/bash
# Setup dynamic MOTD system

# Create the dynamic MOTD script from global config
cat > /usr/local/bin/dynamic-motd << 'DYNAMIC_MOTD_SCRIPT'
MOTD_SCRIPT_PLACEHOLDER
DYNAMIC_MOTD_SCRIPT

chmod +x /usr/local/bin/dynamic-motd

# Clear static MOTD
> /etc/motd

# Disable default MOTD messages
rm -f /etc/update-motd.d/* || true

MOTD_EOF
    chmod +x "$motd_script"
    
    # Replace placeholder with actual MOTD script from global config
    if [ -n "$MOTD_SCRIPT" ]; then
        # Create a temporary file with the MOTD script
        local motd_content_file=$(mktemp)
        printf '%s' "$MOTD_SCRIPT" > "$motd_content_file"
        
        # Use awk to replace the placeholder line with the content from the temp file
        awk -v motd_file="$motd_content_file" '
            /MOTD_SCRIPT_PLACEHOLDER/ {
                while ((getline line < motd_file) > 0) {
                    print line
                }
                close(motd_file)
                next
            }
            { print }
        ' "$motd_script" > "${motd_script}.tmp" && mv "${motd_script}.tmp" "$motd_script"
        
        rm -f "$motd_content_file"
    fi
    
    log_info "Dynamic MOTD will be configured"
    
    # Build virt-customize command array
    local virt_args=(
        "-a" "$image_path"
        "--no-selinux-relabel"
        "--install" "$packages"
    )
    
    # Add run commands
    local run_commands=(
        "systemctl enable qemu-guest-agent || true"
        "DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades 2>/dev/null || true"
        "dpkg-reconfigure -plow unattended-upgrades 2>/dev/null || true"
        "echo 'Unattended-Upgrade::Automatic-Reboot \"false\";' >> /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null || true"
        "sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config"
        "sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config"
        "sed -i 's/#PermitRootLogin yes/PermitRootLogin yes/' /etc/ssh/sshd_config"
        "mkdir -p /etc/cloud/cloud.cfg.d"
        "echo 'datasource_list: [ NoCloud, ConfigDrive ]' > /etc/cloud/cloud.cfg.d/99_pve.cfg"
        "echo 'datasource:' >> /etc/cloud/cloud.cfg.d/99_pve.cfg"
        "echo '  NoCloud:' >> /etc/cloud/cloud.cfg.d/99_pve.cfg"
        "echo '    timeout: 2' >> /etc/cloud/cloud.cfg.d/99_pve.cfg"
        "echo '    max_wait: 2' >> /etc/cloud/cloud.cfg.d/99_pve.cfg"
        "echo '  ConfigDrive:' >> /etc/cloud/cloud.cfg.d/99_pve.cfg"
        "echo '    timeout: 2' >> /etc/cloud/cloud.cfg.d/99_pve.cfg"
        "echo '    max_wait: 2' >> /etc/cloud/cloud.cfg.d/99_pve.cfg"
        "echo 'ssh_pwauth: true' > /etc/cloud/cloud.cfg.d/99_ssh_pwauth.cfg"
        "echo 'disable_root: false' >> /etc/cloud/cloud.cfg.d/99_ssh_pwauth.cfg"
        "sed -i 's/XKBLAYOUT=.*/XKBLAYOUT=\"$KEYBOARD_LAYOUT\"/' /etc/default/keyboard || true"
        "sed -i 's/XKBMODEL=.*/XKBMODEL=\"$KEYBOARD_MODEL\"/' /etc/default/keyboard || true"
        "sed -i 's/XKBVARIANT=.*/XKBVARIANT=\"\"/' /etc/default/keyboard || true"
        "sed -i 's/XKBOPTIONS=.*/XKBOPTIONS=\"\"/' /etc/default/keyboard || true"
        "DEBIAN_FRONTEND=noninteractive dpkg-reconfigure keyboard-configuration || true"
        "setupcon --save || true"
        "loadkeys $KEYBOARD_LAYOUT || true"
        "sed -i 's/# $LOCALE/$LOCALE/' /etc/locale.gen"
        "locale-gen"
        "update-locale LANG=$LOCALE LANGUAGE=$LANGUAGE LC_ALL=$LOCALE"
        "echo 'LANG=$LOCALE' > /etc/default/locale"
        "echo 'LANGUAGE=$LANGUAGE' >> /etc/default/locale"
        "echo 'LC_ALL=$LOCALE' >> /etc/default/locale"
        "ln -sf /dev/null /etc/systemd/network/99-default.link || true"
        "echo 'net.core.default_qdisc=fq' >> /etc/sysctl.d/99-optimizations.conf"
        "echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.d/99-optimizations.conf"
        "echo 'ACTION==\"add|change\", KERNEL==\"sd[a-z]*\", ATTR{queue/scheduler}=\"none\"' > /etc/udev/rules.d/60-scheduler.rules"
        "echo 'growpart:' > /etc/cloud/cloud.cfg.d/99_growpart.cfg"
        "echo '  mode: auto' >> /etc/cloud/cloud.cfg.d/99_growpart.cfg"
        "echo '  devices: [\"/\"]' >> /etc/cloud/cloud.cfg.d/99_growpart.cfg"
        "echo '  ignore_growroot_disabled: false' >> /etc/cloud/cloud.cfg.d/99_growpart.cfg"
        "systemctl enable fstrim.timer || true"
        "mkdir -p /etc/systemd/system/networking.service.d"
        "echo '[Service]' > /etc/systemd/system/networking.service.d/reduce-timeout.conf"
        "echo 'TimeoutStartSec=15s' >> /etc/systemd/system/networking.service.d/reduce-timeout.conf"
        "mkdir -p /etc/systemd/system/systemd-networkd-wait-online.service.d"
        "echo '[Service]' > /etc/systemd/system/systemd-networkd-wait-online.service.d/reduce-timeout.conf"
        "echo 'ExecStart=' >> /etc/systemd/system/systemd-networkd-wait-online.service.d/reduce-timeout.conf"
        "echo 'ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --timeout=10' >> /etc/systemd/system/systemd-networkd-wait-online.service.d/reduce-timeout.conf"
        "systemctl disable systemd-networkd-wait-online.service || true"
        "mkdir -p /etc/systemd/system/cloud-init-local.service.d"
        "echo '[Unit]' > /etc/systemd/system/cloud-init-local.service.d/no-wait.conf"
        "echo 'After=' >> /etc/systemd/system/cloud-init-local.service.d/no-wait.conf"
        "echo '[Service]' >> /etc/systemd/system/cloud-init-local.service.d/no-wait.conf"
        "echo 'TimeoutStartSec=60s' >> /etc/systemd/system/cloud-init-local.service.d/no-wait.conf"
        "mkdir -p /etc/systemd/system/cloud-init.service.d"
        "echo '[Service]' > /etc/systemd/system/cloud-init.service.d/reduce-timeout.conf"
        "echo 'TimeoutStartSec=60s' >> /etc/systemd/system/cloud-init.service.d/reduce-timeout.conf"
        "mkdir -p /etc/systemd/system/cloud-config.service.d"
        "echo '[Service]' > /etc/systemd/system/cloud-config.service.d/reduce-timeout.conf"
        "echo 'TimeoutStartSec=30s' >> /etc/systemd/system/cloud-config.service.d/reduce-timeout.conf"
        "mkdir -p /etc/systemd/system/cloud-final.service.d"
        "echo '[Service]' > /etc/systemd/system/cloud-final.service.d/reduce-timeout.conf"
        "echo 'TimeoutStartSec=30s' >> /etc/systemd/system/cloud-final.service.d/reduce-timeout.conf"
        "echo '[Manager]' > /etc/systemd/system.conf.d/timeout.conf || mkdir -p /etc/systemd/system.conf.d && echo '[Manager]' > /etc/systemd/system.conf.d/timeout.conf"
        "echo 'DefaultTimeoutStartSec=30s' >> /etc/systemd/system.conf.d/timeout.conf"
        "echo 'DefaultTimeoutStopSec=15s' >> /etc/systemd/system.conf.d/timeout.conf"
    )
    
    # Add each run command to virt_args
    for cmd in "${run_commands[@]}"; do
        virt_args+=("--run-command" "$cmd")
    done
    
    # Copy and run bashrc script
    virt_args+=("--copy-in" "$bashrc_script:/tmp/")
    virt_args+=("--run-command" "bash /tmp/$(basename $bashrc_script)")
    
    # Copy and run dynamic MOTD setup script
    virt_args+=("--copy-in" "$motd_script:/tmp/")
    virt_args+=("--run-command" "bash /tmp/$(basename $motd_script)")
    
    # Add timezone
    virt_args+=("--timezone" "$TIMEZONE")
    
    # Add custom post-install commands
    [ -n "$POST_INSTALL_CMD1" ] && virt_args+=("--run-command" "$POST_INSTALL_CMD1")
    [ -n "$POST_INSTALL_CMD2" ] && virt_args+=("--run-command" "$POST_INSTALL_CMD2")
    [ -n "$POST_INSTALL_CMD3" ] && virt_args+=("--run-command" "$POST_INSTALL_CMD3")
    [ -n "$POST_INSTALL_CMD4" ] && virt_args+=("--run-command" "$POST_INSTALL_CMD4")
    [ -n "$POST_INSTALL_CMD5" ] && virt_args+=("--run-command" "$POST_INSTALL_CMD5")
    
    # Add cleanup
    virt_args+=("--truncate" "/etc/machine-id")
    virt_args+=("--truncate" "/var/log/wtmp")
    virt_args+=("--truncate" "/var/log/lastlog")
    
    # Run virt-customize
    log_info "Running virt-customize (this may take several minutes)..."
    
    # Execute the command with LIBGUESTFS_BACKEND environment variable
    LIBGUESTFS_BACKEND=direct virt-customize "${virt_args[@]}" 2>&1 | tee -a "$LOG_FILE"
    local result=${PIPESTATUS[0]}
    
    # Cleanup temp files
    rm -f "$bashrc_script"
    rm -f "$motd_script"
    
    if [ $result -eq 0 ]; then
        log_success "Image customization completed"
        return 0
    else
        log_error "Image customization failed"
        return 1
    fi
}

create_vm() {
    log_info "Creating VM..."
    
    # Check if VM already exists
    if qm status "$VM_ID" &>/dev/null; then
        log_warning "VM $VM_ID already exists!"
        log_warning "This will DESTROY the existing VM $VM_ID and all its data!"
        if [ "${ASSUME_YES:-}" != "1" ]; then
            read -p "Continue? (yes/no): " -r
            echo
            if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
                log_info "Aborted by user"
                exit 0
            fi
        fi
        log_info "Destroying existing VM $VM_ID..."
        qm destroy "$VM_ID"
        sleep 2
    fi
    
    # Set hardware defaults from config (can be overridden per distro)
    VM_MACHINE="${VM_MACHINE:-q35}"
    VM_BIOS="${VM_BIOS:-ovmf}"
    VM_CPU_TYPE="${VM_CPU_TYPE:-host}"
    VM_SCSI_CONTROLLER="${VM_SCSI_CONTROLLER:-virtio-scsi-single}"
    
    # Create VM with settings from config
    qm create "$VM_ID" \
        --name "$VM_NAME" \
        --memory "$VM_MEMORY" \
        --cores "$VM_CORES" \
        --sockets "${VM_SOCKETS:-1}" \
        --cpu "$VM_CPU_TYPE" \
        --machine "$VM_MACHINE" \
        --bios "$VM_BIOS" \
        --scsihw "$VM_SCSI_CONTROLLER" \
        --net0 "virtio,bridge=$VM_BRIDGE" \
        --ostype l26 \
        2>&1 | tee -a "$LOG_FILE"
    
    log_success "VM created with machine=$VM_MACHINE, bios=$VM_BIOS, cpu=$VM_CPU_TYPE"
}

storage_is_file_based() {
    local type
    type=$(pvesm status --storage "$VM_STORAGE" 2>/dev/null | awk 'NR==2 {print $2}')
    case "$type" in
        dir|nfs|cifs|glusterfs|cephfs) return 0 ;;
        *) return 1 ;;
    esac
}

import_disk() {
    local image_path=$1
    local format_args=()

    log_info "Importing disk..."

    # File based storages (dir, nfs, ...) need qcow2 for snapshots
    if storage_is_file_based; then
        VM_DISK_FORMAT="qcow2"
        format_args=(--format qcow2)
        log_info "File based storage detected, using qcow2"
    else
        VM_DISK_FORMAT=""
    fi

    qm importdisk "$VM_ID" "$image_path" "$VM_STORAGE" "${format_args[@]}" 2>&1 | tee -a "$LOG_FILE"

    # Look up the real volume ID, it differs per storage type
    IMPORTED_VOLUME=$(qm config "$VM_ID" | awk '/^unused0:/ {print $2}')
    if [ -z "$IMPORTED_VOLUME" ]; then
        log_error "Could not find imported disk (unused0) in VM config"
        return 1
    fi

    log_success "Disk imported as $IMPORTED_VOLUME"
}

configure_vm() {
    log_info "Configuring VM..."
    
    # Set disk performance defaults from config
    VM_DISK_CACHE="${VM_DISK_CACHE:-writeback}"
    VM_DISK_IOTHREAD="${VM_DISK_IOTHREAD:-1}"
    VM_DISK_SSD="${VM_DISK_SSD:-1}"
    VM_DISK_DISCARD="${VM_DISK_DISCARD:-on}"
    
    # Build disk options string dynamically from config
    local disk_opts="${IMPORTED_VOLUME}"
    disk_opts="${disk_opts},iothread=${VM_DISK_IOTHREAD}"
    disk_opts="${disk_opts},discard=${VM_DISK_DISCARD}"
    disk_opts="${disk_opts},ssd=${VM_DISK_SSD}"
    disk_opts="${disk_opts},cache=${VM_DISK_CACHE}"
    
    log_info "Disk options: $disk_opts"
    
    # Attach disk with performance settings from config
    qm set "$VM_ID" --scsi0 "$disk_opts"
    
    # Add Cloud-Init drive on SCSI1 (required for Debian cloud images)
    qm set "$VM_ID" --scsi1 "${VM_STORAGE}:cloudinit"
    
    # Configure boot with UEFI
    qm set "$VM_ID" \
        --boot order=scsi0 \
        --bootdisk scsi0
    
    # Add EFI disk for UEFI boot
    local efi_opts="${VM_STORAGE}:1,pre-enrolled-keys=0"
    if [ -n "${VM_DISK_FORMAT:-}" ]; then
        efi_opts="${efi_opts},format=${VM_DISK_FORMAT}"
    fi
    qm set "$VM_ID" --efidisk0 "$efi_opts"
    
    # Enable QEMU Guest Agent with fstrim
    qm set "$VM_ID" --agent enabled=1,fstrim_cloned_disks=1
    
    # CPU type already set during creation (host)
    
    # Enable hotplug (CPU, memory, disk, network, USB) - allows MAC address change while running
    qm set "$VM_ID" --hotplug disk,network,usb,cpu,memory
    
    # Enable NUMA for better memory locality
    qm set "$VM_ID" --numa 1
    
    # Set default cloud-init network config (override with TEMPLATE_IPCONFIG)
    qm set "$VM_ID" --ipconfig0 "${TEMPLATE_IPCONFIG:-ip=10.0.0.254/24,gw=10.0.0.2}"
    
    # Set cloud-init user and enable root login
    qm set "$VM_ID" --ciuser "$CLOUD_INIT_USER"

    # Name servers (TEMPLATE_NAMESERVER, space separated): clones inherit them as cloud-init DNS settings
    if [ -n "${TEMPLATE_NAMESERVER:-}" ]; then
        qm set "$VM_ID" --nameserver "$TEMPLATE_NAMESERVER"
    fi

    # SSH keys (SSH_KEYS_FILE): clones inherit them, so they can be started and used right away
    if [ -n "${SSH_KEYS_FILE:-}" ] && [ -s "$SSH_KEYS_FILE" ]; then
        qm set "$VM_ID" --sshkeys "$SSH_KEYS_FILE"
    fi
    
    # Set keyboard layout for noVNC console
    qm set "$VM_ID" --keyboard "$KEYBOARD_LAYOUT"
    
    # Resize disk if specified
    if [ -n "${VM_DISK_SIZE:-}" ]; then
        log_info "Resizing disk to $VM_DISK_SIZE"
        qm resize "$VM_ID" scsi0 "$VM_DISK_SIZE" 2>&1 | tee -a "$LOG_FILE"
        if [ ${PIPESTATUS[0]} -ne 0 ]; then
            log_error "Failed to resize disk"
            return 1
        fi
    fi
    
    log_success "VM configured"
}

convert_to_template() {
    log_info "Converting VM to template..."
    
    qm template "$VM_ID"
    
    log_success "VM converted to template"
}

print_summary() {
    echo
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✓ TEMPLATE CREATED SUCCESSFULLY!${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo
    echo -e "${YELLOW}Template Details:${NC}"
    echo "  Name: $VM_NAME"
    echo "  ID: $VM_ID"
    echo "  Default User: $CLOUD_INIT_USER"
    echo "  Root Login: Password + SSH key (both enabled)"
    echo "  Auto-Update: $([ "${CLOUD_INIT_AUTO_UPDATE:-true}" = "true" ] && echo "Enabled" || echo "Disabled")"
    echo
    echo -e "${YELLOW}Features Enabled:${NC}"
    echo "  ✓ Cloud-Init with hotplug support"
    echo "  ✓ QEMU Guest Agent"
    echo "  ✓ Automatic disk resize"
    echo "  ✓ Security auto-updates"
    echo "  ✓ Custom colorized bash prompt"
    echo "  ✓ Network resilience"
    if [ "${CLOUD_INIT_AUTO_UPDATE:-true}" = "true" ]; then
        echo "  ✓ Package updates on every boot"
    fi
    echo
    echo -e "${YELLOW}Quick Start - Clone & Configure:${NC}"
    echo "  # 1. Clone the template"
    echo "  qm clone $VM_ID 100 --name my-vm --full"
    echo
    echo "  # 2. Set SSH key (recommended)"
    echo "  qm set 100 --sshkeys ~/.ssh/id_rsa.pub"
    echo
    echo "  # OR set password (less secure)"
    echo "  qm set 100 --cipassword 'YourSecurePassword'"
    echo
    echo "  # 3. Configure network (optional, DHCP is default)"
    echo "  qm set 100 --ipconfig0 ip=192.168.1.100/24,gw=192.168.1.1"
    echo "  qm set 100 --nameserver 1.1.1.1"
    echo
    echo "  # 4. Start the VM"
    echo "  qm start 100"
    echo
    echo "  # 5. Connect via SSH"
    echo "  ssh $CLOUD_INIT_USER@<vm-ip>"
    if [ "$ENABLE_ROOT_PASSWORD_LOGIN" = "true" ]; then
        echo "  # or: ssh root@<vm-ip>"
    fi
    echo
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    print_header
    
    # Step 1: Check requirements
    print_step 1 7 "Checking requirements..."
    check_requirements || exit 1
    echo
    
    # Step 2: Download image
    print_step 2 7 "Downloading image..."
    image_path=$(download_image) || exit 1
    echo
    
    # Step 3: Customize image
    print_step 3 7 "Customizing image..."
    customize_image "$image_path" || exit 1
    echo
    
    # Step 4: Create VM
    print_step 4 7 "Creating VM..."
    create_vm || exit 1
    echo
    
    # Step 5: Import disk
    print_step 5 7 "Importing disk..."
    import_disk "$image_path" || exit 1
    echo
    
    # Step 6: Configure VM
    print_step 6 7 "Configuring VM..."
    configure_vm || exit 1
    echo
    
    # Step 7: Convert to template
    print_step 7 7 "Converting to template..."
    convert_to_template || exit 1
    echo
    
    # Cleanup: Remove temporary cloud image
    log_info "Cleaning up temporary files..."
    rm -f "$image_path"
    log_success "Temporary cloud image removed: $image_path"
    echo
    
    # Print summary
    print_summary
}

# Run main function
main "$@"
