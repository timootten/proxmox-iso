# proxmox-iso

Builds an unattended Proxmox VE installation ISO with GitHub Actions and publishes it as release asset `latest`.

## Quick start

1. Check `config/server.env` (hostname, network, disks) and `config/authorized_keys`.
2. Actions, `Build Proxmox ISO`, `Run workflow` (or push a change to `config/` or `scripts/`).
3. Get a download URL for your hosting panel:

   ```bash
   ./scripts/download-url.sh
   ```

   The repository is private, so the permanent release URL needs a login. The script prints a short-lived direct URL. Paste it into the ISO import of your provider straight away, it is valid for about one hour.
4. Boot the server from the ISO. The installation runs without questions and the server reboots.
5. `ssh root@<ip>`, then `passwd` (needed for the web interface on port 8006).

## Targets

| Target | For | Install | Storage |
|---|---|---|---|
| `vps` | Virtual server with one disk | ext4 on LVM, swap 4 GiB, no thin pool | After the first boot the root volume takes the whole disk. One global storage `local` for VM disks (qcow2, snapshots), ISOs, backups, templates and snippets |
| `baremetal` | Physical server | ZFS (`raid1` by default, `raid0`, `raid10`, `raidz-1/2/3` selectable) | `local` (ISOs, backups) and `local-zfs` (VM disks, snapshots). `ZFS_ARC_MAX_GIB` limits the read cache |

For `baremetal` set the disks, for example `nvme0n1 nvme1n1`, in the workflow input or `DISK_LIST`. The builder checks that the disk count fits the RAID level.

## Settings

Everything lives in `config/server.env`. The inputs of a manual run override it.

| Setting | Meaning |
|---|---|
| `TARGET` | `vps` or `baremetal` |
| `FQDN` | Hostname with domain |
| `NETWORK_MODE`, `IP_CIDR`, `GATEWAY` | `dhcp`, or `static` with address and gateway |
| `DNS_SERVERS` | Default `1.1.1.1 8.8.8.8 2606:4700:4700::1111 2001:4860:4860::8888`. Proxmox and glibc use at most three, the fourth is kept as a note. Not an input of the manual run |
| `DISK_LIST`, `ZFS_RAID`, `ZFS_ARC_MAX_GIB`, `SWAP_GIB` | Disks and layout |
| `IP_FORWARDING` | `true`, `false` or `auto` (true when static routes or interface snippets exist) |
| `MGMT_ALLOWED` | Optional host firewall: only these CIDRs reach SSH and port 8006. Empty = off. A wrong value locks you out |
| `TEMPLATES` | See below |

## Static routing and extra interfaces

- `config/static-routes.conf`: one route per line in `ip route` syntax, `-6 ` prefix for IPv6. It is installed as `/etc/proxmox-static-routes.conf` and applied at every boot by `static-routes.service` (`ip route replace`, so it can run repeatedly). Change later: edit the file, then `systemctl restart static-routes`.
- `config/interfaces.d/*.cfg`: ifupdown2 snippets (for example an extra bridge `vmbr1`). They are copied to `/etc/network/interfaces.d/` and loaded with `ifreload -a`.
- IP forwarding is switched on automatically when either exists.

## VM templates (`TEMPLATES`)

The names refer to the configs of your own repo [Proxmox-Termplate-Generator](https://github.com/timootten/Proxmox-Termplate-Generator): `de/debian-13` means `configs/de/debian-13.conf`. Examples: `de/debian-13`, `de/ubuntu-24.04`, `de/customs/debian-13-docker`, `en/debian-13`. Separate several with spaces, `none` skips it.

On the first boot the server clones the generator (public repo needed, there are no credentials on the server) and builds the templates on `local` (vps) or `local-zfs` (baremetal) with bridge `vmbr0`. It takes a few minutes and needs internet. Clone them afterwards with `qm clone`.

## What is inside the ISO

No secrets. Only your public SSH keys and the hash of a random root password that is not stored anywhere.

- Root login by SSH key only, password login is off.
- Enterprise repositories off, no-subscription repository on.
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
- Not tested on real hardware by the author of this repo yet. Test on an empty server first.
