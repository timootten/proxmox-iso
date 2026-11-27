# proxmox-iso

Builds an unattended Proxmox VE installation ISO with GitHub Actions and publishes it as a release asset.
You get one stable URL that you can import as a custom ISO (for example at ZAP-Hosting):

```
https://github.com/timootten/proxmox-iso/releases/download/latest/proxmox-ve-auto.iso
```

## What the ISO does

| Step | Detail |
|---|---|
| Source | Official Proxmox VE ISO (latest 9.x), checksum verified |
| Install | Fully unattended on `/dev/sda`, ext4 on LVM, swap 4 GiB, no thin pool |
| Storage | After first boot the root volume takes the whole disk. `local-lvm` is removed. `local` holds disk images, ISOs, backups, templates and snippets (one global storage, snapshots with qcow2) |
| Login | **SSH key only.** Keys are read from `github.com/<owner>.keys` at build time. The root password is random and not stored |
| Repos | Enterprise repos disabled, no-subscription enabled |
| Templates | Optional VM templates through [Proxmox-Termplate-Generator](https://github.com/timootten/Proxmox-Termplate-Generator) (default: German Debian 13) |

No secrets are inside the ISO: only your public SSH keys and a hash of a random password. The repository can therefore be public.

## Build

Actions, `Build Proxmox ISO`, `Run workflow`:

| Input | Meaning |
|---|---|
| `pve_iso` | `latest` or an exact name such as `proxmox-ve_9.3-1.iso` |
| `fqdn` | Hostname of the server, with domain |
| `network_mode` | `dhcp` or `static` |
| `ip_cidr`, `gateway`, `dns_server` | Only for `static`, for example `5.175.223.10/24` |
| `templates` | Space separated configs from the generator, `none` to skip |

The workflow also runs on every push to `scripts/` and once a month (picks up new Proxmox releases).

The ISO is about 1.7 GiB. GitHub allows up to 2 GiB per release asset.

Local build on Debian or Proxmox:

```bash
apt install proxmox-auto-install-assistant xorriso curl jq openssl   # package from the Proxmox repo
NETWORK_MODE=static IP_CIDR=1.2.3.4/24 GATEWAY=1.2.3.1 ./scripts/build-iso.sh
```

## After the installation

```bash
ssh root@<server-ip>          # key login
passwd                        # set a password for the web interface (https://<ip>:8006)
tail -f /var/log/first-boot-custom.log
```

Restrict port 8006 to your own IP or a VPN.

## Notes

- The installer wipes the disk without asking.
- Network: `dhcp` only works if the provider offers DHCP. Otherwise use `static`. If the network is wrong, the server is only reachable through the VNC console of the provider.
- IPv6 and extra IPs are not part of the installer. Configure them in `/etc/network/interfaces` afterwards.
- Not tested on a real server yet.
