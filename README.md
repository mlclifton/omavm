# omavm — a second Omarchy desktop for GUI agents

A hardware-accelerated Omarchy guest on QEMU/KVM, so an agent can drive a real
Hyprland desktop, its menu bar and its widgets without competing with you for
the cursor on your own machine.

## The problem this actually solves

An agent doing GUI work needs to move a pointer, click things and read the
screen. If it does that on your host, you cannot use your machine at the same
time. Put it in a VM and the two stop fighting: the guest has its own
compositor, its own cursor and its own input stack, and nothing the agent does
inside it reaches your host pointer.

There is exactly one way the two can still collide, and it is worth
understanding because it is the difference between this working and not.

**A viewer window couples the two pointers.** SPICE with an absolute pointing
device forwards your host pointer position into the guest whenever your pointer
is over that window. So an attached viewer is for watching, and touching the
mouse while it is focused will fight the agent.

**The agent should drive the guest over SSH with no viewer attached.** Then the
coupling does not exist at all.

## How an agent drives the desktop

Sealing installs `omarchy-ui`, a single command that wraps the tools that
actually work on Hyprland, and an agent skill that teaches an agent to use it.
The skill lands in `~/.claude/skills/omarchy-ui/` for the guest user, so an
agent running in the guest picks it up without being told about it.

| Task | Command |
|---|---|
| Check the environment | `omarchy-ui doctor` |
| Window geometry | `omarchy-ui windows`, `omarchy-ui focused` |
| Bar, menus and pickers | `omarchy-ui layers` |
| Screenshot | `omarchy-ui shot`, `omarchy-ui shot --window Spotify` |
| Click a window | `omarchy-ui click-window foot` |
| Pointer and keys | `omarchy-ui at X Y`, `omarchy-ui key ctrl+c` |
| Open an Omarchy menu | `omarchy-ui menu system` |
| Wait for something | `omarchy-ui wait-window foot 5` |

Two design points are worth knowing, because they are what makes this reliable.

**It asks the compositor rather than reading pixels.** Hyprland knows exactly
where every window and panel is. `omarchy-ui windows` is faster than a
screenshot and cannot misread anti-aliased text. Screenshots are for judging
what something looks like, not for working out where to click.

**Input originates inside the guest.** `ydotool` injects through
`/dev/uinput`, so its events do not come from a viewer and are unaffected by
whatever your host pointer is doing.

The Omarchy bar and menu are layer surfaces, not windows, so they never show up
in `windows`. `omarchy-ui menu <route>` summons a menu by name rather than
chording keys, and waits for it to appear.

An agent on the host can use the same tool over SSH:

```bash
./manage-agent-vm.sh ssh -- omarchy-ui shot -  > frame.png
```

To watch without interfering:

```bash
./manage-agent-vm.sh watch          # pulls frames over SSH, touches nothing
./manage-agent-vm.sh screenshot     # one frame to a file
```

Host-side capture is not available. QEMU cannot screendump a virgl guest and
reports `no surface`, so frames come from `grim` inside the guest instead.

## Profiles

One switch, `PROFILE` in `config/omavm.conf`, decides the network, the
clipboard and whether file sharing is possible. These move together, so they
are one setting rather than several you have to keep consistent.

| | `workstation` (default) | `sandbox` |
|---|---|---|
| Network | NAT, real internet, DNS | Isolated, no route out, no DNS |
| Clipboard | Shared | Off |
| File sharing | Available | Off |
| Egress control | None | Host proxy, hostname allowlist |
| For | Your own agents doing UI work | Something you do not trust |

Override for one command without editing anything:

```bash
OMAVM_PROFILE=sandbox ./manage-agent-vm.sh start
```

The sandbox profile is documented in `OPERATIONS.md`. The rest of this file
describes the workstation profile.

## What is in here

| Path | What it is |
|---|---|
| `install_host_deps.sh` | One-time host provisioning. Idempotent, has `--dry-run`. |
| `manage-agent-vm.sh` | The lifecycle command you use every day. |
| `verify-isolation.sh` | Asserts containment. Sandbox profile only. |
| `config/omavm.conf` | Every name, path and address. Change things here. |
| `libvirt/agent-net.xml` | The NAT network. |
| `libvirt/agent-sandbox-net.xml` | The isolated network. |
| `libvirt/omarchy-agent.xml.in` | The domain template. |
| `proxy/` | Allowlisting proxy and credential gateway. Sandbox profile only. |
| `guest/seal-guest.sh` | Runs once inside the guest to prepare it. |
| `guest/skills/omarchy-ui/` | The agent skill and the `omarchy-ui` command. |
| `OPERATIONS.md` | **Read this.** Every recurring manual task, with its trigger. |

---

## Step 1 — provision the host

```bash
cd ~/Projects/omavm
./install_host_deps.sh --dry-run    # read the plan first
./install_host_deps.sh
```

**Then log out and back in.** Group membership does not apply to your current
Hyprland session. To test without logging out, run `newgrp libvirt` first.

Two notes on what it deliberately does not do. It installs `qemu-desktop`, not
`qemu-full`, because `qemu-full` adds emulators for every foreign architecture,
none of which this VM uses. And it does not install `iptables-nft`, because on
current Arch the `iptables` package is already the nftables-backed build and
swapping it would remove a dependency of your running ufw.

## Step 2 — install Omarchy

Download the ISO from <https://omarchy.org>, then:

```bash
./manage-agent-vm.sh init
./manage-agent-vm.sh build --iso ~/Downloads/omarchy.iso
```

The ISO is copied into `/var/lib/libvirt/images/omavm/` first. QEMU does not run
as you, and the unprivileged user libvirt starts it as cannot traverse a `0700`
home directory, so an ISO left in `~/Downloads` is unreadable to it whatever
mode the file itself has.

Install Omarchy as you normally would, with two constraints:

1. **Create the user account named `agent`.** If you prefer another name, change
   `GUEST_USER` in `config/omavm.conf` before you seal.
2. **Do not enable disk encryption.** It works, but you would have to type the
   passphrase at every boot, which makes unattended starts impossible.

To throw away a part-finished install and start over, use `rebuild` with the
same arguments. Do not use `reset` for that: it restores a frozen base image,
which does not exist until step 4.

## Step 3 — seal the guest

With the guest booted to its desktop:

```bash
./manage-agent-vm.sh seal
```

It prints one command to run in a terminal inside the guest.

**Pasting will not work yet.** SPICE clipboard sharing needs `spice-vdagent`
running in the guest, and that is one of the things this step installs, so it
cannot be there before the step runs. Either type the command, or have the host
type it for you:

```bash
./manage-agent-vm.sh paste 'curl -sL 192.168.100.1:8765/s | sudo bash' --enter
```

`paste` injects keystrokes at the virtual keyboard through qemu, below anything
the guest is running, so it works from the firmware screen onwards and needs no
guest agent. Click into the guest window first so the keys land there. With no
argument it types whatever is on your host clipboard.

After sealing, ordinary clipboard sharing works in both directions.

Sealing installs SSH and the agent control kit, switches SSH to key-only, sets
up `ydotoold` in the user session, configures sddm autologin so the desktop
comes up unattended, adds the file share mount point, and clears per-install
state.

It prints the guest's SSH host key fingerprint. Write it down. It should never
change again, so if it ever does, that is a real signal.

## Step 4 — freeze the base

```bash
./manage-agent-vm.sh stop
./manage-agent-vm.sh freeze
```

`freeze` compacts the installed disk into a read-only base image and performs
the first reset. From here the base is never booted directly; every run boots a
copy-on-write overlay of it.

---

## Daily use

```bash
./manage-agent-vm.sh start        # boot, no viewer, agent has the cursor
./manage-agent-vm.sh ssh          # shell in the guest
./manage-agent-vm.sh watch        # see what it is doing, touch nothing
./manage-agent-vm.sh gui          # attach a viewer, takes the pointer when focused
./manage-agent-vm.sh status
./manage-agent-vm.sh stop
```

**The guest is persistent.** The overlay survives stop and start, so tools the
agent installs and work in progress carry over. `reset` is the explicit way back
to the frozen base:

```bash
./manage-agent-vm.sh reset
```

That destroys the running domain without asking, deletes the overlay, creates a
fresh one, and restores the UEFI variables file. NVRAM lives outside the disk
image, so a reset that only replaced the qcow2 would leave firmware state
behind. It takes about as long as creating a small file.

## Sharing files with the guest

Off by default. There is no share device at all unless you configure one.

```bash
mkdir -p ~/Projects/omavm-share
```

Then set `SHARE_DIR="${HOME}/Projects/omavm-share"` in `config/omavm.conf`, or
for one session:

```bash
OMAVM_SHARE_DIR=~/Projects/omavm-share ./manage-agent-vm.sh start
```

It appears in the guest at `/mnt/omavm` over virtiofs. `SHARE_READONLY="yes"`
makes it read-only from the guest side.

Share a purpose-made directory, not your home. The guest writes into it as the
guest user, and everything in it is reachable by whatever runs in there. The
share is ignored entirely in the sandbox profile, where a shared filesystem
would bypass the network controls.

## Reference

| Setting | Default | Notes |
|---|---|---|
| Memory | 12288 MB | `VM_MEM_MB` |
| vCPUs | 6 | `VM_VCPUS` |
| Resolution | 1920x1080 | `VIDEO_WIDTH`, `VIDEO_HEIGHT` |
| Guest address | 192.168.100.10 | Reserved by MAC |
| Guest user | `agent` | `GUEST_USER` |

Keep the resolution fixed. An agent clicking at coordinates needs the viewport
to be the same size on every run, and screenshots are only comparable across
runs if the geometry does not move.

## Known limits

- **virgl is a guest-to-host escape surface.** It hands guest OpenGL to your
  amdgpu driver and has had escape-grade bugs. That is an acceptable trade for
  your own agents on a machine you control. It is the reason the sandbox
  profile exists for anything you do not trust.
- **The base image is only as trustworthy as the install.** Everything you
  installed before sealing is in every reset, forever.
- **A viewer window couples the pointers.** Covered above. Use `watch` when you
  only want to observe.
