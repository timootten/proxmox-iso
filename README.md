# proxmox-iso

Builds an unattended Proxmox VE installation ISO with GitHub Actions and publishes it as a release. The VM template generator lives in the same repository (`templates/`).

## Quick start

1. Actions, `Build Proxmox ISO`, `Run workflow`. Fill in the form: server type, hostname, IPv4 and/or IPv6 with gateway, disks for bare metal.
2. When the run is green, the **Summary** shows the full download URL of exactly that build, for example
   `https://github.com/timootten/proxmox-iso/releases/download/iso-9.3-1-ff36288a/proxmox-ve-auto.iso`
   The tag ends with the first 8 characters of the ISO's SHA-256, so a URL always points to one single file. Paste it into the ISO import of your hosting panel. Panels that ask for a file name get `proxmox-ve-auto.iso`.
3. Boot the server from the ISO. The installation runs without questions and then **powers the server off** (not a reboot, because the ISO is still mounted and would start the installation again).
   Unmount the ISO in the panel, then start the server. The first start runs the setup script.
4. `ssh root@<ip>`, then `passwd` (needed for the web interface on port 8006).

Set your SSH key once in `config/authorized_keys`. The repository is **public** so that the download URL works without a login. There are no secrets in it or in the ISO: only your public SSH key, the hostname and the addresses (which are in DNS anyway) and the hash of a random root password that is stored nowhere. Never put passwords or tokens into `config/`.

## The form

| Field | Meaning |
|---|---|
| Server type | `vps` (one virtual disk, ext4 + LVM, one global storage) or `baremetal` (ZFS) |
| Hostname | FQDN, default `hydrogen.timootten.com` |
| IPv4 address, gateway | For example `192.0.2.10/24` and `192.0.2.1`. Empty for an IPv6-only server |
| IPv6 address, gateway | For example `2001:db8::10/64`. Empty for an IPv4-only server |
| Disks, ZFS layout | Bare metal only, for example `nvme0n1 nvme1n1` with `raid1`. `vps` uses `sda` |
| Private network | Address of the host on the private bridge `vmbr1`, `none` switches it off |
| Firewall | CIDRs that may reach SSH and the web interface. Empty = no host firewall |
| Templates | `minimal` (Debian 13), `standard`, `all` or `none` |

The network is **always static**, DHCP is not supported. At least one of IPv4 or IPv6 is required. Empty fields fall back to `config/server.env`, which also holds everything that is not in the form.

## Workflows

| Job | Purpose |
|---|---|
| `Build Proxmox ISO` | **Only runs when you start it by hand.** Builds the ISO and checks every input first (disk count against RAID level, addresses, names of templates), publishes release `iso-<version>-<run>`, keeps the five newest and writes the download URL into the summary |
| `Lint` | shellcheck for all scripts, on every push and pull request |
| `Proxmox update check` | Weekly: opens an issue when Proxmox published a newer ISO than the last release. Builds nothing |
| `Template sources` | Wednesday: opens an issue when a cloud image URL of a template is gone |

`Test installation (manual)` installs a test ISO in QEMU and checks the system over SSH (about 12 minutes). It only runs when you start it, for example before a bigger change.

Renovate (`renovate.json`) pins GitHub Actions to commit hashes and opens update pull requests. Only hash pins merge by themselves. Install the [Renovate GitHub App](https://github.com/apps/renovate) for this repository to activate it.

## Targets

| Target | Install | Storage |
|---|---|---|
| `vps` | ext4 on LVM, swap 4 GiB, no thin pool. The root volume is only 20 GiB during the installation (fast on network storage) | After the first boot the root volume takes the whole disk. One global storage `local` for VM disks (qcow2, snapshots), ISOs, backups, templates and snippets |
| `baremetal` | ZFS (`raid1` by default, `raid0`, `raid10`, `raidz-1/2/3`) | `local` (ISOs, backups) and `local-zfs` (VM disks, snapshots). `ZFS_ARC_MAX_GIB` limits the read cache |

## Network

- **vmbr0**: the public uplink with the host address (IPv4 and/or IPv6).
- **vmbr1**: private network for VMs with IPv4 (`10.10.0.1/24`) and IPv6 (`fd10:10::1/64`, a private unique local range). Source NAT (and NAT66) through vmbr0 lets the VMs reach the internet. `dnsmasq` only does DHCP (`.100` to `.200`) and IPv6 router advertisements on this bridge, **its DNS function is off**. The VMs get the public resolvers directly (`1.1.1.1`, `8.8.8.8`, and the Cloudflare and Google IPv6 addresses when the host has IPv6). IPv4 NAT is off on IPv6-only servers.
- **IPv6**: the installer takes one address, IPv4 if there is one. The IPv6 address is added on the first boot. With a gateway outside of the prefix (routed /64) the default route is set with `onlink`.
- **DNS**: `1.1.1.1`, `8.8.8.8`, Cloudflare IPv6, Google IPv6. Linux uses at most three, so the fourth is only a note. On IPv6-only servers the IPv6 resolvers come first.
- **Static routes**: `config/static-routes.conf`, one `ip route` line each (`-6 ` prefix for IPv6). It becomes `/etc/proxmox-static-routes.conf`, applied at every boot by `static-routes.service`. Change it later, then `systemctl restart static-routes`.
- **Extra interfaces**: `config/interfaces.d/*.cfg` (ifupdown2 snippets) are copied to `/etc/network/interfaces.d/`.
- IP forwarding is switched on when the private network, routes or snippets exist.

## Security and defaults

All of it can be switched in `config/server.env`.

- Root login by SSH key only. The ISO holds only your public keys and the hash of a random password that is stored nowhere.
- `HARDENING=true`: SSH limits (3 tries, no X11 and agent forwarding), kernel network settings, `rpcbind` off (only needed for NFSv3), mail stays local, `fail2ban` for SSH and the web interface (3 failed logins = 1 hour ban).
- `HOST_AUTO_UPDATE=security`: Debian security updates install themselves, no automatic reboot. Proxmox packages and kernels are never touched automatically.
- `SUBSCRIPTION_NAG=hide`: the "No valid subscription" pop-up is removed. An apt hook repeats this after updates of the web interface package.
- Enterprise repositories are off, the no-subscription repository is on.
- `MGMT_ALLOWED`: host firewall that only lets these addresses reach SSH and port 8006. A wrong value locks you out, keep it empty if unsure.
- The build verifies the SHA-256 of the Proxmox ISO and fails without an SSH key.

## VM templates

The generator is in `templates/` (`generate-template.sh`, `global.conf`, `motd.sh`, `configs/<lang>/`). The ISO carries the generator and only the selected configs, nothing is cloned from GitHub on the server.

| `TEMPLATE_SET` | Builds |
|---|---|
| `none` | nothing |
| `minimal` | Debian 13 |
| `standard` | Debian 13, Ubuntu 26.04, Debian 13 with Docker (`templates/sets.env`) |
| `all` | every config in `templates/configs/<lang>/` |

`TEMPLATES` in `config/server.env` adds single names, for example `fedora-45 rocky-9`. Available: `debian-12`, `debian-13`, `ubuntu-22.04`, `ubuntu-24.04`, `ubuntu-26.04`, `fedora-45`, `rocky-9`, `almalinux-9`, `archlinux`, `customs/debian-13-docker`.

Templates use qcow2 on directory storage (`vps`) or ZFS volumes (`baremetal`). They sit on the private bridge `vmbr1` (IPv4 by DHCP, IPv6 by router advertisement) and carry your SSH key and all four name servers as cloud-init DNS settings (`1.1.1.1`, `8.8.8.8`, Cloudflare and Google IPv6), so a clone can be started and used right away:

```bash
qm clone 9013 100 --name test     # linked clone, ready in seconds
qm start 100
```

Full independent copy: add `--full`. The VM gets `10.10.0.x` and an `fd10:10::` address, `ssh root@<address>` from the host works with your key.

**Auto update:** with `TEMPLATE_AUTO_REFRESH=true` a monthly timer rebuilds the templates from the current cloud images. Templates with linked clones are kept, so use full clones. The list is in `/etc/default/template-refresh`, run it by hand with `/usr/local/sbin/refresh-templates`. The MOTD banner (Andotta) is `templates/motd.sh`.

## After the installation

```bash
cat /var/lib/first-boot-custom.status     # OK or the list of failed steps
tail -f /var/log/first-boot-custom.log
```

## Production checklist for customer VMs

What the ISO does not decide for you:

1. **Two-factor login** for every web interface user (Datacenter, Permissions, Two Factor) and **API tokens** instead of the root password for automation.
2. **Restrict port 8006** with `MGMT_ALLOWED` or a VPN.
3. **Backups to another location** (Proxmox Backup Server). Ceph, ZFS mirrors and snapshots are no backup.
4. **VM firewall**: enable the Proxmox firewall on every customer NIC with IP filter and MAC filter, and use a routed or NAT setup, never a shared bridge with foreign MACs on a provider network.
5. **Limits per VM**: CPU limit, memory, disk IOPS and bandwidth (`rate` on the NIC), so one customer cannot starve the rest.
6. **No nested virtualization** and no PCI passthrough for customers unless needed.
7. **Monitoring and mail**: set up a metrics server and an SMTP relay (Datacenter, Notifications) so failed backups and ZFS or SMART warnings reach you.
8. **Updates**: install Proxmox updates and kernels by hand in a maintenance window and reboot.
9. **Abuse handling**: outbound DDoS and spam from customer VMs can get the whole server blocked at the provider. Block outbound port 25 and watch the traffic.

## Limits

- The installer wipes the disks without asking.
- With a gateway outside of the IPv4 subnet (some routed setups) the installer may reject the address. The build warns about it. Then add the gateway afterwards through `config/interfaces.d` or the routes file.
- If the network is wrong, the server is only reachable through the VNC console of the provider.
- The ISO is about 1.7 GiB, GitHub allows 2 GiB per release asset.
- The template build itself (`qm`, `virt-customize`) is not tested automatically. Try it on a real Proxmox host with `minimal` first.
- Not tested on real hardware by the author of this repo yet. Test on an empty server first.
