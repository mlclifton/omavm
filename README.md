# omavm — a sandboxed Omarchy VM for GUI agents

A hardware-accelerated Omarchy guest on QEMU/KVM, isolated from the network,
resettable to a known-clean state in about two seconds, and reachable from the
host over SSH.

It exists so you can point an AI agent at a real Hyprland desktop and let it
click things, without that agent being able to reach your LAN, your files, or
the internet at large.

## The threat model, stated plainly

The control that actually holds is **the network**. The guest sits on a libvirt
network with no `<forward>` element, which means there is no routing, no NAT and
no path off the bridge. It is not a firewall rule that could be flushed; it is a
property of the network definition. The only things the guest can reach are the
three host ports ufw permits: DHCP, and the two proxy listeners.

The control that is **weaker than it looks** is the VM boundary itself. This
guest runs virgl for 3D acceleration, which hands guest OpenGL calls to your
host's amdgpu driver. That interface has had escape-grade bugs before and will
again. A guest with 3D acceleration is not a security boundary you should bet
your host on.

So: treat the network isolation as the real control, keep the host patched, and
do not put anything on this host you would mind an agent seeing if virgl broke.

## What is in here

| Path | What it is |
|---|---|
| `install_host_deps.sh` | One-time host provisioning. Idempotent, has `--dry-run`. |
| `manage-agent-vm.sh` | The lifecycle command you use every day. |
| `verify-isolation.sh` | Asserts the sandbox is still a sandbox. |
| `config/omavm.conf` | Every name, path and address. Change things here. |
| `libvirt/agent-sandbox-net.xml` | The isolated network. |
| `libvirt/agent-build-net.xml` | A NAT network, used only while installing. |
| `libvirt/omarchy-agent.xml.in` | The domain template. |
| `proxy/agent-proxy.py` | Allowlisting proxy and credential gateway. |
| `guest/seal-guest.sh` | Runs once inside the guest to prepare it. |
| `OPERATIONS.md` | **Read this.** Every recurring manual task, with its trigger. |

## Before you start

You need an Arch-family host with AMD-V or VT-x, roughly 120 GB free under
`/var/lib`, and a DRM render node. `install_host_deps.sh` checks all of these
and refuses to continue if one is missing.

---

## Step 1 — provision the host

```bash
cd ~/Projects/omavm
./install_host_deps.sh --dry-run    # read the plan first
./install_host_deps.sh
```

It installs libvirt and QEMU, creates the `libvirt` group membership, generates
an SSH keypair used only by this VM, installs the proxy as a hardened systemd
service, defines both networks, and adds three narrow ufw rules.

Two notes on what it deliberately does **not** do:

- It installs `qemu-desktop`, not `qemu-full`. `qemu-full` adds emulators for
  every foreign architecture, none of which this VM uses.
- It does not install `iptables-nft`. On current Arch the `iptables` package is
  already the nftables-backed build, and swapping it would remove a dependency
  of your running ufw.

**Then log out and back in.** Group membership does not apply to your current
Hyprland session. To test without logging out, run `newgrp libvirt` first.

## Step 2 — get the ISO

Download the Omarchy ISO from <https://omarchy.org>, then either pass it with
`--iso` or set `OMARCHY_ISO` in `config/omavm.conf`.

## Step 3 — install Omarchy

```bash
./manage-agent-vm.sh init
./manage-agent-vm.sh build --iso ~/Downloads/omarchy.iso
```

To throw away a part-finished install and start over, use `rebuild` with the
same arguments. Do not use `reset` for this: it restores a frozen base image,
which does not exist until step 5.

This boots the installer on the **build network**, which has real NAT to the
internet because the Omarchy installer needs it. A display window opens
automatically.

The ISO is first copied into `/var/lib/libvirt/images/omavm/`. QEMU does not run
as you, and the unprivileged user libvirt starts it as cannot traverse a `0700`
home directory, so an ISO left in `~/Downloads` is unreadable to it whatever
mode the file itself has. Staging also keeps libvirt's dynamic ownership from
chowning your copy away from you. On a filesystem with reflink support the copy
is instant.

Install Omarchy as you normally would, with two constraints:

1. **Create the user account named `agent`.** If you prefer another name, change
   `GUEST_USER` in `config/omavm.conf` before you seal.
2. **Do not enable disk encryption.** It works, but you would have to type the
   passphrase at every boot, which makes unattended resets impossible.

While the build network is up, the guest has unrestricted internet. That is
expected during this step and only this step.

## Step 4 — seal the guest

With the guest booted to its desktop:

```bash
./manage-agent-vm.sh seal
```

It prints one command to type into a terminal **inside the guest**:

```
curl -fsSL http://192.168.101.1:8765/seal.sh | sudo bash
```

The seal step installs `openssh`, `qemu-guest-agent` and `spice-vdagent`,
installs your public key, switches SSH to key-only, configures sddm autologin so
the desktop comes up unattended after every reset, points the guest at the host
proxy, and clears per-install state. The host command waits until the guest
accepts the new key, then tells you it is done.

It prints the guest's SSH host key fingerprint. Write it down. It should never
change again, so if it ever does, that is a real signal rather than noise.

## Step 5 — freeze the base

```bash
./manage-agent-vm.sh stop
./manage-agent-vm.sh freeze
```

`freeze` compacts the installed disk into a read-only base image at mode `0444`,
closes the build network, and immediately performs the first reset. From here
on the base is never booted directly; every run boots a copy-on-write overlay of
it.

---

## Daily use

```bash
./manage-agent-vm.sh reset        # discard everything, back to the clean base
./manage-agent-vm.sh start --gui  # boot on the isolated network, open a display
./manage-agent-vm.sh ssh          # shell in the guest
./manage-agent-vm.sh ssh -- hyprctl clients   # or run one command
./manage-agent-vm.sh stop
./manage-agent-vm.sh status
```

`reset` is the important one. It destroys the running domain without asking,
deletes the overlay, creates a fresh one over the base, and **also restores the
UEFI variables file**. That last part matters: NVRAM lives outside the disk
image, so a reset that only replaced the qcow2 would leave boot entries and any
other firmware state the guest had written.

Resetting takes about as long as creating a small file, because a fresh overlay
is a few hundred kilobytes. The base image is never copied.

## Giving the agent access to an API

Two mechanisms, and they are not interchangeable.

**The gateway, for LLM APIs.** The guest talks plain HTTP to
`http://192.168.100.1:8889/anthropic`, and the host attaches your API key on the
way out. The key never exists inside the guest, so an agent that reads every
file and environment variable in its own VM still cannot exfiltrate it. Put the
key in `/etc/omavm/credentials.env` and the route is already defined in
`/etc/omavm/routes.conf`. The seal step already set `ANTHROPIC_BASE_URL` in the
guest, so the Anthropic SDK picks this up with no code changes.

**The allowlist, for everything else.** Add a hostname to
`/etc/omavm/allowlist.conf` and reload. The guest can then reach that host
through the proxy on port 8888, which the seal step already exported as
`HTTPS_PROXY`. The allowlist starts empty, which means the guest reaches nothing.
That is the intended starting state.

The allowlist matches the hostname the guest asked for, which is the name in the
TLS SNI. It cannot restrict paths or methods, and it cannot distinguish two
sites that share a hostname. Prefer a gateway route whenever you want the guest
to reach exactly one API.

TLS is never decrypted. There is no certificate authority to generate, install
in the guest, or rotate.

## Checking that it still works

```bash
./verify-isolation.sh
```

It checks the network definition, the packet filter, the proxy's bind
addresses, the image permissions, and then drives real escape attempts from
inside the guest: direct TCP to a public address, DNS resolution, reaching your
LAN router, reaching the host's SSH port, and asking the proxy for a host that
is not allowlisted. It exits non-zero if any of those succeed when they should
not.

Run it after anything that could move the network under you. `OPERATIONS.md`
lists exactly when.

## Reference

| Network | Subnet | Guest address | Purpose |
|---|---|---|---|
| `agent-sandbox-net` | 192.168.100.0/24 | 192.168.100.10 | Normal operation. Isolated, no DNS. |
| `agent-build-net` | 192.168.101.0/24 | 192.168.101.10 | Installs and base refreshes only. NAT. |

| Guest display | Value |
|---|---|
| Resolution before the display agent starts | `VIDEO_WIDTH` x `VIDEO_HEIGHT` in `config/omavm.conf`, default 1920x1080 |
| Resolution once sealed | Follows the viewer window, via `spice-vdagent` |

| Host port on 192.168.100.1 | Service |
|---|---|
| 8888 | Allowlisting forward proxy |
| 8889 | Credential-injecting gateway |

| File | Purpose |
|---|---|
| `/etc/omavm/allowlist.conf` | Hostnames the guest may reach |
| `/etc/omavm/routes.conf` | Gateway routes and which credential each uses |
| `/etc/omavm/credentials.env` | API keys, mode 0640, host-only |
| `/var/log/omavm/agent-proxy.log` | Every ALLOW and DENY decision |
| `/var/lib/libvirt/images/omavm/` | Base image and overlay |

## Known limits

- **virgl is an escape surface.** Covered above. It is the reason the network
  isolation is the primary control.
- **A hostname allowlist is not a URL allowlist.** Allowing a host allows the
  whole host.
- **The build network is a real hole.** It is opened explicitly, closed by
  `freeze` and `close-build`, and `verify-isolation.sh` fails while it is open.
- **Clipboard and file transfer follow the network.** They are on during a
  build, where you need to paste commands and no agent is running, and off on
  the sandbox network, where they would be host-to-guest data channels that
  bypass every network control. Turning them on for the sandbox widens it.
- **The base image is only as trustworthy as the install.** Everything you
  installed before sealing is in every reset, forever.
