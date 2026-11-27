Put extra ifupdown2 snippets here, for example `10-vmbr1.cfg`:

    auto vmbr1
    iface vmbr1 inet static
        address 10.10.0.1/24
        bridge-ports none
        bridge-stp off
        bridge-fd 0

Files ending in `.cfg` are copied to `/etc/network/interfaces.d/` on the first boot and loaded with `ifreload -a`.
