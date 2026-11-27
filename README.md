# proxmox-iso

Builds an unattended Proxmox VE installation ISO with GitHub Actions, tests the installation in QEMU and publishes it as a release. The VM template generator lives in the same repository (`templates/`).

## Quick start

1. Edit `config/server.env` (hostname, network, disks) and `config/authorized_keys`.
2. Actions, `Build Proxmox ISO`, `Run workflow`. The hostname and everything else can be changed in the form.
3. When the run is green, open its **Summary**. It shows a direct download URL of the ISO, valid for about one hour. Paste it into the ISO import of your hosting panel.
   Later: `./scripts/download-url.sh` prints a fresh URL for the latest release (`./scripts/download-url.sh owner/repo iso-9.3-1-12` for a specific one).
4. Boot the server from the ISO. The installation runs without questions and reboots.
5. `ssh root@<ip>`, then `passwd` (needed for the web interface on port 8006).

The repository stays private. There is no permanent public URL on purpose: the ISO contains your hostname, network settings and routes.

## What the pipeline does

| Job | Purpose |
|---|---|
| `lint` | shellcheck for all scripts |
| `plan` | Weekly run: only builds when Proxmox published a newer ISO than the last release |
| `test` | Builds a test ISO for `vps` and for `baremetal`, **installs it in QEMU** and checks the installed system over SSH (Proxmox version, web interface, storage layout, ZFS mirror, SSH hardening, DNS, routes, forwarding, update settings) |
| `build` | Builds the real ISO from your settings |
| `release` | Publishes release `iso-<version>-<run>`, keeps the five newest, writes the download URL into the summary |
| `alert` | Opens an issue when the weekly run fails |

A second workflow, `Template sources`, checks every Wednesday that all cloud image URLs of the templates still work and opens an issue if one is gone.

Pull requests run `lint` and `test` only. Renovate (`renovate.json`) updates GitHub Actions and the Debian tools, pins actions to commit hashes and merges minor and patch updates itself once the QEMU test is green. Install the [Renovate GitHub App](https://github.com/apps/renovate) for this repository to activate it.

## Targets

| Target | For | Install | Storage |
|---|---|---|---|
| `vps` | Virtual server with one disk | ext4 on LVM, swap 4 GiB, no thin pool | After the first boot the root volume takes the whole disk. One global storage `local` for VM disks (qcow2, snapshots), ISOs, backups, templates and snippets |
| `baremetal` | Physical server | ZFS (`raid1` by default, `raid0`, `raid10`, `raidz-1/2/3`) | `local` (ISOs, backups) and `local-zfs` (VM disks, snapshots). `ZFS_ARC_MAX_GIB` limits the read cache |

For `baremetal` set the disks (`nvme0n1 nvme1n1`) in the form or in `DISK_LIST`. The builder checks that the disk count fits the RAID level.

## Settings

Everything lives in `config/server.env`. The form of a manual run overrides it (`config` = take the value from the file).

| Setting | Meaning |
|---|---|
| `TARGET` | `vps` or `baremetal` |
| `FQDN` | Hostname with domain |
| `NETWORK_MODE`, `IP_CIDR`, `GATEWAY` | `dhcp`, or `static` with address and gateway |
| `DNS_SERVERS` | Default `1.1.1.1 8.8.8.8 2606:4700:4700::1111 2001:4860:4860::8888`. Proxmox and glibc use at most three, the fourth is kept as a note. Not an input of the manual run |
| `DISK_LIST`, `ZFS_RAID`, `ZFS_ARC_MAX_GIB`, `SWAP_GIB` | Disks and layout |
| `HOST_AUTO_UPDATE` | `security` (default): Debian security updates install themselves, no automatic reboot. Proxmox packages and kernels are never touched automatically |
| `IP_FORWARDING` | `true`, `false` or `auto` (true when static routes or interface snippets exist) |
| `MGMT_ALLOWED` | Optional host firewall: only these CIDRs reach SSH and port 8006. Empty = off. A wrong value locks you out |
| `TEMPLATE_SET`, `TEMPLATES`, `TEMPLATE_LANG`, `TEMPLATE_AUTO_REFRESH` | See below |
| `BRAND_DOCS_URL`, `BRAND_SUPPORT_URL` | Optional links in the template MOTD |

## Static routing and extra interfaces

- `config/static-routes.conf`: one route per line in `ip route` syntax, `-6 ` prefix for IPv6. It is installed as `/etc/proxmox-static-routes.conf` and applied at every boot by `static-routes.service` (`ip route replace`, repeatable). Change later: edit the file, then `systemctl restart static-routes`.
- `config/interfaces.d/*.cfg`: ifupdown2 snippets (for example an extra bridge `vmbr1`), copied to `/etc/network/interfaces.d/` and loaded with `ifreload -a`.
- IP forwarding is switched on automatically when either exists.

## VM templates

The generator is in `templates/` (`generate-template.sh`, `global.conf`, `motd.sh`, `configs/<lang>/`). The ISO carries the generator and only the selected configs. Nothing is downloaded from GitHub on the server, only the official cloud images.

| `TEMPLATE_SET` | Builds |
|---|---|
| `none` | nothing |
| `minimal` | Debian 13 |
| `standard` | Debian 13, Ubuntu 26.04, Debian 13 with Docker (`templates/sets.env`) |
| `all` | every config in `templates/configs/<lang>/` |

`TEMPLATES` adds single names on top, for example `fedora-45 rocky-9`. Available: `debian-12`, `debian-13`, `ubuntu-22.04`, `ubuntu-24.04`, `ubuntu-26.04`, `fedora-45`, `rocky-9`, `almalinux-9`, `archlinux`, `customs/debian-13-docker`. A wrong name fails the build.

The templates use qcow2 on directory storage (`vps`) or ZFS volumes (`baremetal`), bridge `vmbr0`, DHCP as the cloud-init default. Clone them with `qm clone <id> <new-id> --full`.

**Auto update:** with `TEMPLATE_AUTO_REFRESH=true` a monthly timer (`template-refresh.timer`) rebuilds the templates from the current cloud images. Templates that still have linked clones are kept, so use full clones. Change the list in `/etc/default/template-refresh`, run it by hand with `/usr/local/sbin/refresh-templates`.

The MOTD banner (Andotta) is `templates/motd.sh`.

## What is inside the ISO

No secrets. Only your public SSH keys and the hash of a random root password that is not stored anywhere.

- Root login by SSH key only, password login is off.
- Enterprise repositories off, no-subscription repository on.
- Automatic Debian security updates (`HOST_AUTO_UPDATE`).
- DNS set to `DNS_SERVERS`.
- Source: the official Proxmox ISO, SHA-256 verified. The build fails if the checksum does not match.
- The build also fails if no SSH key is found, because the server would be unreachable.

## After the installation

```bash
cat /var/lib/first-boot-custom.status     # OK or the list of failed steps
tail -f /var/log/first-boot-custom.log
```

## Limits

- The installer wipes the disks without asking.
- `dhcp` only works if the provider offers DHCP. With `static` the gateway must be inside the subnet of `IP_CIDR`. Gateways outside the subnet (some routed setups) have to be added afterwards through `config/interfaces.d` or the routes file.
- If the network is wrong, the server is only reachable through the VNC console of the provider.
- The ISO is about 1.7 GiB, GitHub allows 2 GiB per release asset.
- The QEMU test covers the installer and the first boot script. The template build itself (`qm`, `virt-customize`) is only checked statically and has to be tried on a real Proxmox host.
- Not tested on real hardware by the author of this repo yet. Test on an empty server first.
