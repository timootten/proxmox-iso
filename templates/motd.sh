#!/bin/bash
# Dynamic MOTD - Shows real-time system information

# Colors
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
NC="\033[0m" # No Color

# ASCII Art Banner
echo -e "${CYAN}"
cat << 'BANNER'
    _    _   _ ____   ___ _____ _____  _
   / \  | \ | |  _ \ / _ \_   _|_   _|/ \
  / _ \ |  \| | | | | | | || |   | | / _ \
 / ___ \| |\  | |_| | |_| || |   | |/ ___ \
/_/   \_\_| \_|____/ \___/ |_|   |_/_/   \_\

BANNER
echo -e "${NC}"
echo ""

# Get OS info
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="$PRETTY_NAME"
else
    OS_NAME=$(uname -s)
fi

echo -e "${GREEN}Welcome to $OS_NAME${NC}"
if [ -d /etc/pve ]; then
    if [ -f /var/lib/first-boot-custom.status ]; then
        FB=$(cat /var/lib/first-boot-custom.status)
        case "$FB" in
            OK*) echo -e "${GREEN}Setup: OK${NC}" ;;
            *)   echo -e "${RED}Setup: $FB (see /var/log/first-boot-custom.log)${NC}" ;;
        esac
    else
        echo -e "${YELLOW}Setup: first boot script has not finished (see /var/log/first-boot-custom.log)${NC}"
    fi
fi
if command -v pveversion >/dev/null 2>&1; then
    echo -e "${GREEN}$(pveversion 2>/dev/null | head -n1)  |  kernel $(uname -r)${NC}"
fi
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# System Information Header
echo -e "${YELLOW}System Information as of $(date '+%a %d %b %Y %H:%M:%S %Z')${NC}"
echo ""

# Get primary network interface (exclude lo)
PRIMARY_IF=$(ip route | grep default | head -n1 | awk '{print $5}')

# Get IPv4 address
IPV4=$(ip -4 addr show $PRIMARY_IF 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
[ -z "$IPV4" ] && IPV4="N/A"

# Get IPv6 address (global scope)
IPV6=$(ip -6 addr show $PRIMARY_IF 2>/dev/null | grep "scope global" | awk '{print $2}' | cut -d'/' -f1 | head -n1)
[ -z "$IPV6" ] && IPV6="N/A"

# CPU Usage (1 minute average load)
LOAD=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,$//' )
CPU_CORES=$(nproc)
CPU_USAGE=$(awk -v load="$LOAD" -v cores="$CPU_CORES" 'BEGIN {printf "%.1f", (load/cores)*100}')

# Memory Usage
MEM_TOTAL_MB=$(free -m | awk 'NR==2{print $2}')
MEM_USED_MB=$(free -m | awk 'NR==2{print $3}')
MEM_TOTAL_GB=$(awk -v mem="$MEM_TOTAL_MB" 'BEGIN {printf "%.0f", mem/1024}')
MEM_USED_GB=$(awk -v mem="$MEM_USED_MB" 'BEGIN {printf "%.1f", mem/1024}')
MEM_PERCENT=$(awk -v used="$MEM_USED_MB" -v total="$MEM_TOTAL_MB" 'BEGIN {printf "%.0f", (used/total)*100}')

# Swap Usage
SWAP_TOTAL_MB=$(free -m | awk 'NR==3{print $2}')
SWAP_USED_MB=$(free -m | awk 'NR==3{print $3}')
SWAP_TOTAL_GB=$(awk -v swap="$SWAP_TOTAL_MB" 'BEGIN {printf "%.0f", swap/1024}')
SWAP_USED_GB=$(awk -v swap="$SWAP_USED_MB" 'BEGIN {printf "%.1f", swap/1024}')
if [ "$SWAP_TOTAL_MB" -gt 0 ]; then
    SWAP_PERCENT=$(awk -v used="$SWAP_USED_MB" -v total="$SWAP_TOTAL_MB" 'BEGIN {printf "%.0f", (used/total)*100}')
else
    SWAP_PERCENT=0
fi

# Disk Usage (root filesystem)
DISK_USED=$(df -BG / | awk 'NR==2{print $3}' | sed 's/G//')
DISK_TOTAL=$(df -BG / | awk 'NR==2{print $2}' | sed 's/G//')
DISK_PERCENT=$(df / | awk 'NR==2{print $5}' | sed 's/%//')

# Process count
PROCESSES=$(ps aux | wc -l)

# Users logged in
USERS=$(who | wc -l)

# Uptime
UPTIME=$(uptime -p | sed 's/up //')

# Print system stats in two columns
printf "  ${BLUE}System Load:${NC}  %-20s ${BLUE}Processes:${NC}        %s\n" "$LOAD (${CPU_USAGE}%)" "$PROCESSES"
printf "  ${BLUE}CPU Cores:${NC}    %-20s ${BLUE}Users logged in:${NC}  %s\n" "$CPU_CORES" "$USERS"
printf "  ${BLUE}Memory:${NC}       %-20s ${BLUE}Uptime:${NC}           %s\n" "${MEM_USED_GB}GB/${MEM_TOTAL_GB}GB (${MEM_PERCENT}%)" "$UPTIME"
printf "  ${BLUE}Swap:${NC}         %-20s ${BLUE}IPv4:${NC}             %s\n" "${SWAP_USED_GB}GB/${SWAP_TOTAL_GB}GB (${SWAP_PERCENT}%)" "$IPV4"
printf "  ${BLUE}Disk /:${NC}       %-20s ${BLUE}IPv6:${NC}             %s\n" "${DISK_USED}GB/${DISK_TOTAL}GB (${DISK_PERCENT}%)" "${IPV6:0:25}"

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Links (only shown when configured at build time)
BRAND_DOCS_URL="@@BRAND_DOCS_URL@@"
BRAND_SUPPORT_URL="@@BRAND_SUPPORT_URL@@"
if [ -n "$BRAND_DOCS_URL" ] || [ -n "$BRAND_SUPPORT_URL" ]; then
    echo -e "${YELLOW}Resources:${NC}"
    [ -n "$BRAND_DOCS_URL" ] && echo -e "   - Documentation:  $BRAND_DOCS_URL"
    [ -n "$BRAND_SUPPORT_URL" ] && echo -e "   - Support:        $BRAND_SUPPORT_URL"
    echo ""
fi

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

