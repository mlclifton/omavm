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
./manage-agent-vm.sh webapp ssh -- omarchy-ui shot -  > frame.png
```

`omarchy-ui` discovers the graphical session's environment itself, so it works
over SSH without a login shell or any exported variables.

## Clipboard

```bash
./manage-agent-vm.sh webapp clip pull      # guest clipboard -> host
./manage-agent-vm.sh webapp clip push      # host clipboard -> guest
```

This goes over SSH and needs no viewer attached.

**SPICE clipboard sharing does not work with a Hyprland guest**, so do not wait
for it. The packaged `spice-vdagent` is an X11 agent that syncs the XWayland
clipboard, and on a Wayland session the two do not bridge in a way that
propagates. Every component can look healthy while nothing syncs. The domain
still enables clipboard sharing, so it will start working if a Wayland-capable
agent ships later.

To watch without interfering:

```bash
./manage-agent-vm.sh webapp watch          # pulls frames over SSH, touches nothing
./manage-agent-vm.sh webapp screenshot     # one frame to a file
```

Host-side capture is not available. QEMU cannot screendump a virgl guest and
reports `no surface`, so frames come from `grim` inside the guest instead.

## Named VMs

Every VM has a name, and the name always comes first:

```bash
./manage-agent-vm.sh webapp start
./manage-agent-vm.sh api reset
```

It cannot be omitted and it cannot be mistaken for a command's own argument, so
there is no way to reset the wrong guest by forgetting a flag. An unknown name
is an error listing the VMs that do exist, never a new VM created by accident.

**One base image, many overlays.** Every VM is a copy-on-write overlay of the
same frozen base, so a second project VM costs a few hundred kilobytes rather
than another 60 GB. Patch the base once and every VM picks it up at its next
reset.

**`base` is reserved.** It is the writable guest that produces that image, and
`init`, `build`, `rebuild`, `seal`, `freeze` and `refresh` accept no other
name. It is removed automatically once you freeze, since keeping it would hold
an address and a 60 GB disk for nothing.

**VMs can reach each other by default**, like machines on a LAN, so a project
split across `webapp` and `api` can talk to itself. To stop that, set
`GUEST_ISOLATION_DEFAULT_WORKSTATION="yes"` in `config/omavm.conf`, or for one
command:

```bash
OMAVM_GUEST_ISOLATION=yes ./manage-agent-vm.sh webapp start
```

With isolation on, each VM still reaches the host and the outside, but not
other VMs. The sandbox profile turns it on by default.

It is a network-wide setting, not a per-VM one, and `config/vm/<name>.conf`
cannot change it. Bridge port isolation only blocks traffic between two
isolated ports, so an isolated VM can still talk to one that is not. Isolating a
single VM would look protective while protecting nothing. It takes effect on
each VM's next start, so after changing it restart every VM that is running.

**Memory is what limits how many you run at once**, not disk. The default is
6144 MB per VM, which fits three alongside the host on 27 GB. Override it per
VM in `config/vm/<name>.conf`.

```bash
./manage-agent-vm.sh list
./manage-agent-vm.sh new api
./manage-agent-vm.sh rm api
```

`list` shows the full status of every VM at a glance, and never asks for a
password:

```
webapp
  state        running
  address      192.168.100.10 on agent-net
  sizing       6144 MB, 4 vCPU
  share        /home/mike/Projects/omavm-share/webapp -> ~agent/Project
  disk         1.2G written since last reset

api
  state        running
  address      192.168.100.11 on agent-net
  sizing       6144 MB, 4 vCPU
  share        none
  disk         1.2G written since last reset

shared
  profile      workstation
  other VMs    reachable (GUEST_ISOLATION=no)
  base image   4.9G, frozen 2026-09-11
```

`./manage-agent-vm.sh webapp status` shows the same fields for one VM. The disk
figure is what the VM has written since its last reset, which is the space a
reset would give back.

**VMs are reachable by name.** From any terminal on the host:

```bash
ping webapp.omavm
ssh webapp                 # or ssh webapp.omavm
scp notes.txt webapp:
```

Two separate mechanisms make that work.

`ssh webapp` works because `new` and `rm` rewrite `~/.ssh/omavm/config`, an SSH
config holding one entry per VM with the omavm key, the guest account and
omavm's own known-hosts file. Your `~/.ssh/config` gains exactly one line at the
top, `Include ~/.ssh/omavm/config`, and the original is saved as
`~/.ssh/config.pre-omavm` the first time. Run `./manage-agent-vm.sh ssh-config`
to rebuild it by hand. It connects by address, so it does not depend on names
resolving.

`webapp.omavm` resolves because libvirt's DNS server on the bridge already
knows every VM's name, and the network registers the `omavm` domain with
systemd-resolved. A stopped VM does not resolve, since there is nothing there
to answer.

The suffix is `.omavm` rather than `.local` on purpose. Hosts with nss-mdns send
every `.local` lookup to mDNS and stop there, so a DNS answer for `.local` is
never consulted. A dedicated suffix also means the SSH entries match only VMs,
never printers or other machines on your LAN.

Plain `ssh agent@192.168.100.12` is refused. The guest accepts only the omavm
key and has password logins switched off, and plain `ssh` offers your personal
key instead. Use `ssh <vm>`, `omavm <vm> ssh`, or pass the key with `-i`.

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
OMAVM_PROFILE=sandbox ./manage-agent-vm.sh webapp start
```

The sandbox profile is documented in `OPERATIONS.md`. The rest of this file
describes the workstation profile.

## What is in here

| Path | What it is |
|---|---|
| `install.sh` | Puts `omavm` on your PATH, and `remove` takes omavm off the host. |
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
| `config/vm/<name>.conf` | Optional per-VM overrides. None needed by default. |
| `TUTORIAL.md` | **Start here.** A worked walkthrough of driving the desktop. |
| `OPERATIONS.md` | Every recurring manual task, with its trigger. |

---

## Step 0 — put `omavm` on your PATH

```bash
cd ~/Projects/omavm
./install.sh
```

That links `~/.local/bin/omavm` to `manage-agent-vm.sh` in this repository, so
from then on `omavm webapp start` does the same as
`./manage-agent-vm.sh webapp start`, from any directory. It is a link, not a
copy, so pulling new commits updates the command too. Nothing here needs a
password.

Use `--bin-dir DIR` to link somewhere else, and `--with-host` to run step 1 as
part of it. The examples in this documentation spell out `./manage-agent-vm.sh`
so they work before you install; after installing, type `omavm` instead.

To take omavm off the host again:

```bash
./install.sh remove --dry-run    # see exactly what it would remove
./install.sh remove              # the command, proxy, firewall rules, networks
./install.sh remove --purge      # also every VM, the images and the SSH key
```

`remove` refuses while VMs still exist, unless you pass `--purge`, because
deleting the networks under them would break them. It deliberately leaves the
packages, your `libvirt` group membership and your share folders, since those
may be used by other things or hold your own files.

It is `./install.sh remove` rather than `omavm remove` on purpose. `omavm rm`
already deletes a single VM, and the command that deletes everything should not
be one letter away from it.

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
./manage-agent-vm.sh base init
./manage-agent-vm.sh base build --iso ~/Downloads/omarchy.iso
```

The ISO is copied into `/var/lib/libvirt/images/omavm/` first. QEMU does not run
as you, and the unprivileged user libvirt starts it as cannot traverse a `0700`
home directory, so an ISO left in `~/Downloads` is unreadable to it whatever
mode the file itself has.

Install Omarchy as you normally would, with two constraints:

1. **Create a user account.** The name is yours to choose, with two
   conditions.

   It must match `GUEST_USER` in `config/omavm.conf`, which ships as `agent`.
   Use a different name and change that setting to match, either before you
   seal or when sealing reports the mismatch, which it does automatically.

   It is baked into the frozen base, so **every VM shares this one account**.
   Changing it afterwards means sealing and freezing again, so it is worth
   deciding now rather than later.

   Everything in this documentation uses `agent`.
2. **Turn off disk encryption**, which is on by default and is not offered as a
   menu item. On the final confirmation screen, the one that says everything
   will be overwritten, there is a dim grey line reading **"Press Ctrl+C for
   unencrypted install."** Press Ctrl+C and the button changes to **"Yes,
   install without encryption"**. Press that.

   Encryption works, but you would have to type the passphrase at every boot,
   which makes unattended starts impossible and stops `reset` being usable.

   Ctrl+C does not interrupt anything here. The installer uses it as a toggle
   because its prompt library exits on only two keys.

To throw away a part-finished install and start over, use `rebuild` with the
same arguments. Do not use `reset` for that: it restores a frozen base image,
which does not exist until step 4.

## Step 3 — seal the guest

**You will be asked for a password at the first boot after installing.** That is
the desktop login, not disk encryption, even though it does not look like one:
Omarchy's login theme is a single password box with no username field, so it is
easily mistaken for a passphrase prompt. Omarchy does not enable autologin on an
unencrypted install, because the passphrase it would otherwise have replaced is
not there. Log in with the account password you chose. Sealing configures
autologin, so this is the only time you need it.

If you want to be sure the disk really is unencrypted:

```bash
./manage-agent-vm.sh base ssh -- lsblk -o NAME,FSTYPE
```

No `crypto_LUKS` row means it worked.

With the guest booted to its desktop:

```bash
./manage-agent-vm.sh base seal
```

It prints one command to run in a terminal inside the guest.

**Pasting will not work yet.** SPICE clipboard sharing needs `spice-vdagent`
running in the guest, and that is one of the things this step installs, so it
cannot be there before the step runs. Either type the command, or have the host
type it for you:

```bash
./manage-agent-vm.sh webapp paste --enter 'curl -sL 192.168.100.1:8765/s | sudo bash'
```

If the punctuation arrives wrong, for instance a pipe appearing as a tilde, the
guest is not on a US keyboard layout. Set `KEYBOARD_LAYOUT` in
`config/omavm.conf`, or for one run:

```bash
OMAVM_KEYBOARD_LAYOUT=gb ./manage-agent-vm.sh webapp paste --enter 'curl -sL ...'
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
./manage-agent-vm.sh webapp stop
./manage-agent-vm.sh base freeze
```

`freeze` compacts the installed disk into a read-only base image and performs
the first reset. From here the base is never booted directly; every run boots a
copy-on-write overlay of it.

---

## Step 5 — create your VMs

```bash
./manage-agent-vm.sh new webapp
./manage-agent-vm.sh new api
```

Each gets the next free address, a DHCP reservation, its own overlay and its
own UEFI variables. The reservation is the registry: there is no separate file
to drift out of sync with libvirt, and `virsh net-dumpxml agent-net` shows the
same truth the script works from.

Each VM takes its hostname from that reservation, so a shell inside `webapp`
says `webapp` rather than all of them sharing one name. That relies on the base
having no static hostname, which sealing arranges. If two guests report the
same name, see the runbook entry on hostnames.

## Daily use

```bash
./manage-agent-vm.sh webapp start        # boot, no viewer, agent has the cursor
./manage-agent-vm.sh webapp ssh          # shell in the guest
./manage-agent-vm.sh webapp watch        # see what it is doing, touch nothing
./manage-agent-vm.sh webapp gui          # attach a viewer, takes the pointer when focused
./manage-agent-vm.sh webapp status
./manage-agent-vm.sh webapp stop
```

**The guest is persistent.** The overlay survives stop and start, so tools the
agent installs and work in progress carry over. `reset` is the explicit way back
to the frozen base:

```bash
./manage-agent-vm.sh webapp reset
```

That destroys the running domain without asking, deletes the overlay, creates a
fresh one, and restores the UEFI variables file. NVRAM lives outside the disk
image, so a reset that only replaced the qcow2 would leave firmware state
behind. It takes about as long as creating a small file.

## Sharing a project folder with a VM

Each VM can have a folder on the host that appears inside it at
`~agent/Project`, owned by `agent`. The folder lives on the host, so it
**survives `reset`**. The VM's own disk goes back to the base image, while
everything in `Project` stays. That makes it the place for work you want to
keep, while the rest of the VM stays disposable.

It is off until you create the folder, named after the VM:

```bash
mkdir -p ~/Projects/omavm-share/webapp
./manage-agent-vm.sh webapp stop && ./manage-agent-vm.sh webapp start
./manage-agent-vm.sh webapp ssh -- ls -la Project
```

**Stop and start, not reboot.** The folder is attached as a device on the VM.
A reboot keeps the VM's existing devices, so a newly created folder only
appears after a full stop and start.

**Ownership follows the numeric user ID.** What `agent` writes in the guest is
owned by you on the host, and what you write on the host is owned by `agent` in
the guest. That relies on both accounts having the same UID. It is the normal
case, because each is the first account on its machine, UID 1000, but
`./manage-agent-vm.sh webapp sync-share` checks and warns if they differ.

**To share an existing project directory** instead of one under
`omavm-share`, point that VM at it in its override file:

```bash
# config/vm/webapp.conf
SHARE_DIR="${HOME}/Projects/myapp"
```

`SHARE_READONLY="yes"` in `config/omavm.conf` makes shares read-only from the
guest side. Share a directory made for the purpose, never your whole home: the
guest can write to anything in it.

The sandbox profile never shares a folder, whatever a VM's override file says.
A shared folder is a direct channel between host and guest that sidesteps every
network control.

**Where it mounts is part of the base image.** A base sealed before shares
moved to `~agent/Project` mounts them at `/mnt/omavm` instead. To move a running
VM over without resetting it:

```bash
./manage-agent-vm.sh webapp sync-share
```

It asks for `agent`'s sudo password, then updates the mount and moves the share
straight away. That lasts until the VM's next reset. To make it permanent for
every VM, re-seal the base: `base refresh`, `base seal`, `base stop` and
`base freeze`.

## Reference

| Setting | Default | Notes |
|---|---|---|
| Addresses | 192.168.100.10 to .99 | Allocated in order as VMs are created |
| Memory | 12288 MB | `VM_MEM_MB` |
| vCPUs | 6 | `VM_VCPUS` |
| Resolution | 1920x1080 | `VIDEO_WIDTH`, `VIDEO_HEIGHT` |
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
