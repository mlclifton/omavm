# Operations runbook

Every task in this system that needs a human, what makes it necessary, and what
to type. If a task is not in here and you find yourself doing it twice, add it.

Entries marked **sandbox only** apply to the `sandbox` profile. Under the
default `workstation` profile the guest has ordinary internet and there is no
proxy, no allowlist and no isolation to maintain, so most of the recurring work
below simply does not arise.

## At a glance

| Trigger | Task | Roughly how often |
|---|---|---|
| An agent run fails with a proxy denial | [Allowlist a host](#an-agent-is-blocked-by-the-proxy) | Sandbox only |
| You want an agent to use a new API without holding its key | [Add a gateway route](#add-a-gateway-route-for-a-new-api) | Sandbox only |
| Base image is more than a month old, or lacks a package you need | [Refresh the base](#the-base-image-is-stale) | Monthly |
| You need a VM for a new project, or want one gone | [Add or remove a VM](#adding-and-removing-vms) | As projects come and go |
| `pacman -Syu` touched mesa, the kernel, libvirt, qemu or ufw | [Re-verify isolation](#after-a-host-system-update) | Every host update |
| `verify-isolation.sh` exits non-zero | [Triage a failed verification](#isolation-verification-failed) | Sandbox only |
| You reloaded, reset or reinstalled ufw | [Reapply the bridge rules](#ufw-was-reloaded-or-reset) | On change |
| An API key is compromised or expiring | [Rotate a credential](#rotate-an-api-key) | Sandbox only |
| The guest SSH fingerprint changed | [Investigate a fingerprint change](#the-guest-ssh-host-key-changed) | Should be never |
| Guest boots to a black screen after a host update | [Fall back to software rendering](#the-guest-boots-to-a-black-screen) | Rare |
| Guest resolution is wrong or will not follow the window | [Fix the guest resolution](#the-guest-resolution-is-wrong) | Rare |
| The agent and your cursor are fighting | [Detach the viewer](#the-agent-and-your-cursor-are-fighting) | Whenever it happens |
| Pasting into the guest does nothing | [Type it from the host instead](#you-cannot-paste-into-the-guest) | During an install |
| Typed punctuation comes out wrong | [Set the keyboard layout](#typed-punctuation-is-wrong) | Once per guest |
| Seal stops partway with errors | [Get in over SSH and finish it](#seal-stopped-partway) | Rare |
| Clipboard does not move between host and guest | [Use the SSH route](#clipboard-does-not-work-between-host-and-guest) | Whenever you need it |
| Seal reports the wrong guest account | [Set GUEST_USER](#the-guest-account-name-does-not-match) | After an install |
| Seal keeps failing the same way after a fix | [Check for a stale seal server](#seal-keeps-running-an-old-script) | After an interrupted seal |
| The agent cannot click or type in the guest | [Repair the input path](#the-agent-cannot-click-or-type) | Rare |
| Clicks land in the wrong place | [Recalibrate the pointer](#clicks-land-in-the-wrong-place) | After a display change |
| You changed the agent skill or `omarchy-ui` | [Push the change into the guest](#updating-the-agent-skill) | Whenever you edit it |
| The file share is missing in the guest | [Fix the share](#the-file-share-is-not-mounted) | Rare |
| Guest is unreachable at its usual address | [Fix DHCP addressing](#the-guest-got-the-wrong-address) | Rare |
| Guest has no IP address at all | [Diagnose a missing lease](#the-guest-never-gets-an-ip-address) | Rare |
| The installer offers no way to skip encryption | [Press Ctrl+C to toggle it](#the-installer-shows-no-encryption-option) | Every base build |
| A file you passed to the VM gives "Permission denied" | [Stage it where qemu can read it](#permission-denied-on-a-file-you-passed-to-the-vm) | Whenever it happens |
| `/var/lib` is filling up | [Reclaim overlay space](#disk-is-filling-up) | As needed |

---

## An agent is blocked by the proxy

**Trigger.** An agent run fails with a connection error, or you see a `DENY`
line while following the log. This is the most common recurring task in the
whole system, because the allowlist starts empty on purpose.

**Why it happens.** `/etc/omavm/allowlist.conf` is default-deny. Anything not
named in it is refused.

**Steps.**

1. Find what was refused, and why:

   ```bash
   sudo grep DENY /var/log/omavm/agent-proxy.log | tail -20
   ```

   The `reason` field tells you which of these it was:

   | reason | Meaning |
   |---|---|
   | `not-in-allowlist` | The host is not listed, or is listed on a different port. |
   | `non-global-address` | The name resolves to a private or loopback address. |
   | `dns-failure` | The host does not resolve from the host machine. |
   | `no-matching-route` | A gateway request whose path prefix has no route. |

2. Decide whether the agent should reach it. A `non-global-address` denial is
   almost never something to allow: it means something asked the proxy to reach
   into your own LAN.

3. Add the host, one per line, port after the name:

   ```bash
   sudoedit /etc/omavm/allowlist.conf
   ```

   ```
   github.com 443
   *.githubusercontent.com 443
   ```

   `*.example.com` matches subdomains only, not `example.com` itself.

4. Validate before reloading, so a typo does not take the proxy down:

   ```bash
   sudo -u omavm-proxy /usr/local/lib/omavm/agent-proxy.py --check
   ```

5. Reload:

   ```bash
   sudo systemctl reload omavm-agent-proxy
   ```

**Confirm.** Retry the agent, and check the log now shows `ALLOW` for that host.

**Remember.** Allowing a host allows the entire host, every path and method. If
what you actually want is one API with a credential the guest never sees, add a
gateway route instead.

---

## Add a gateway route for a new API

**Trigger.** You want an agent to call an API, and you do not want the API key
to exist inside the guest.

**Steps.**

1. Add the key to `/etc/omavm/credentials.env`:

   ```bash
   sudoedit /etc/omavm/credentials.env
   ```

   ```
   OPENAI_API_KEY=sk-...
   ```

2. Add the route to `/etc/omavm/routes.conf`. The columns are path prefix,
   upstream, header name, and value template:

   ```
   /openai  https://api.openai.com  Authorization  Bearer ${OPENAI_API_KEY}
   ```

3. Validate and restart. A **restart** is needed, not a reload, because
   credentials are read from the environment at start:

   ```bash
   sudo -u omavm-proxy /usr/local/lib/omavm/agent-proxy.py --check
   sudo systemctl restart omavm-agent-proxy
   ```

4. Point the guest at it. Either export the base URL in the guest, or add it to
   `guest/seal-guest.sh` and re-seal so it survives resets:

   ```
   OPENAI_BASE_URL=http://192.168.100.1:8889/openai
   ```

**Confirm.**

```bash
sudo journalctl -u omavm-agent-proxy -n 5 | grep 'gateway routes'
```

A route whose environment variable is unset is **disabled and logged at
startup** rather than forwarded without authentication. If your route count is
lower than you expect, that is why.

---

## Adding and removing VMs

**Trigger.** A new project needs its own guest, or an old one is finished with.

**Steps.**

```bash
./manage-agent-vm.sh new api          # next free address, fresh overlay
./manage-agent-vm.sh list             # what exists and what it is doing
./manage-agent-vm.sh rm api           # asks you to type the name to confirm
```

`new` costs almost nothing in disk, because every VM is a copy-on-write overlay
of the same base. Memory is the real limit: at the default 6144 MB you can run
three alongside the host on 27 GB. Override per VM in `config/vm/<name>.conf`.

**If you run out of addresses**, the range is `.10` to `.99` on the active
network, so ninety VMs. Long before that you would run out of memory.

**To share files with one VM**, create the directory named after it. Nothing is
shared unless the directory exists:

```bash
mkdir -p ~/Projects/omavm-share/api
./manage-agent-vm.sh api stop && ./manage-agent-vm.sh api start
```

The share is a device on the domain, so it needs a restart rather than a mount.

**Confirm what a VM is:**

```bash
./manage-agent-vm.sh api status
```

**Note.** `rm` deletes the overlay, which is everything that VM has written
since its last reset. There is no undo, which is why it asks you to type the
name rather than pressing y.

---

## The base image is stale

**Trigger.** Any of:

- The base is more than about a month old. Check with
  `./manage-agent-vm.sh webapp status`.
- An agent needs a package that is not in the base.
- An Omarchy release you want to test against has shipped.

**Why it matters.** Every reset returns to the base exactly. Nothing an agent
installs survives, by design, so the only way to change what the guest has is to
rebuild the base.

**This affects every VM.** They all overlay the same base, so a refresh reaches
all of them at their next reset. That is usually the point, since you patch
once. It also means a mistake in the base reaches everything, so freeze only
what you have checked.

**Steps.**

```bash
./manage-agent-vm.sh base refresh          # boots a writable copy of the base on the NAT network
./manage-agent-vm.sh webapp ssh
```

Inside the guest:

```bash
sudo pacman -Syu
omarchy-update
# install anything else the agent needs
exit
```

Back on the host:

```bash
./manage-agent-vm.sh webapp stop
./manage-agent-vm.sh base freeze           # compacts, replaces the base, closes the build network, resets
```

**Confirm.**

```bash
./manage-agent-vm.sh webapp status
```

**Note.** The old base is not deleted until `freeze` succeeds, so a refresh that
goes wrong costs you nothing. If you abandon a refresh halfway, run
`./manage-agent-vm.sh webapp reset` to go back to the frozen base.

---

## After a host system update

**Trigger.** `pacman -Syu` upgraded any of: `mesa`, `linux`, `libvirt`, `qemu-*`,
`edk2-ovmf`, `ufw`, `iptables`, `nftables`, or `incus`.

**Why it matters.** libvirt and incus both write nftables rules. ufw rewrites
its chains on reload. A mesa or kernel change can break virgl. An `edk2-ovmf`
change can leave the per-domain NVRAM file inconsistent with the new firmware.

**Steps.**

```bash
./verify-isolation.sh --host-only     # before booting anything
./manage-agent-vm.sh webapp start
./verify-isolation.sh                 # full check with the guest up
```

If the guest fails to boot after an `edk2-ovmf` upgrade, reset. That restores
NVRAM from the new firmware template:

```bash
./manage-agent-vm.sh webapp reset
```

If the display is black, see [black screen](#the-guest-boots-to-a-black-screen).

---

## Isolation verification failed

**Trigger.** `./verify-isolation.sh` exited non-zero.

**Do not run untrusted agents until this is resolved.**

Work through by the failing check.

**`agent-sandbox-net has a <forward> element`.** Something redefined the
network, most likely virt-manager. Restore it:

```bash
sudo virsh net-destroy agent-sandbox-net
sudo virsh net-undefine agent-sandbox-net
sudo virsh net-define libvirt/agent-sandbox-net.xml
sudo virsh net-autostart agent-sandbox-net
sudo virsh net-start agent-sandbox-net
```

**`agent-net is running`.** The NAT network is up while you are asking for
containment. Stop it:

```bash
sudo virsh net-destroy agent-net
```

**`A masquerade or SNAT rule references virbr-agent`.** Something is NATting the
sandbox bridge. Find it and remove whatever created it:

```bash
sudo nft list ruleset | grep -B5 -A5 virbr-agent
```

**`ufw default forward policy is ACCEPT`.** Set it back:

```bash
sudo sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="DROP"/' /etc/default/ufw
sudo ufw reload
```

Then reapply the bridge rules, below.

**`Guest opened a direct TCP connection`.** The most serious failure. Stop the
guest immediately, then work back through the network definition and the
nftables ruleset:

```bash
./manage-agent-vm.sh webapp stop --force
```

**`Base image mode is not 444`.** Resets are no longer deterministic, because
something has been able to write to the base:

```bash
sudo chmod 0444 /var/lib/libvirt/images/omavm/omarchy-agent-base.qcow2
./manage-agent-vm.sh webapp reset
```

Treat the base as suspect if you cannot explain how it became writable.

---

## ufw was reloaded or reset

**Trigger.** You ran `ufw reset`, reinstalled ufw, or edited its rules and
noticed the omavm entries are gone. Check with:

```bash
sudo ufw status | grep -i virbr
```

**Why it happens.** The bridge rules are ordinary ufw rules and do not survive a
reset.

**Steps.** Re-running the installer reapplies them and changes nothing else:

```bash
./install_host_deps.sh --yes
./verify-isolation.sh --host-only
```

You should see three rules on `virbr-agent`: DHCP on 67/udp, and TCP on 8888 and
8889. If any others appear on that bridge, remove them. Every additional
permitted port is a host service the agent can reach.

---

## Rotate an API key

**Trigger.** A key expired, leaked, or your rotation schedule came round.

**Steps.**

```bash
sudoedit /etc/omavm/credentials.env
sudo systemctl restart omavm-agent-proxy
sudo journalctl -u omavm-agent-proxy -n 5
```

A restart, not a reload. Credentials are read from the environment at start.

**Confirm.** The startup line reports the number of active gateway routes. If a
route silently disappeared, the variable name in `routes.conf` no longer matches
the one in `credentials.env`.

**No guest action is needed.** The key was never in the guest, so nothing inside
it has to change and nothing inside it was exposed.

---

## Rotate the guest SSH key

**Trigger.** The host key material may have been exposed, or your policy says so.

**Steps.**

```bash
rm -f ~/.ssh/omavm_agent_ed25519 ~/.ssh/omavm_agent_ed25519.pub
./install_host_deps.sh --yes          # regenerates the keypair
./manage-agent-vm.sh base refresh          # boot the base writable
./manage-agent-vm.sh base seal             # reinstalls the new public key
./manage-agent-vm.sh webapp stop
./manage-agent-vm.sh base freeze
```

The new key has to go into the base, otherwise the next reset restores the old
one.

---

## The guest SSH host key changed

**Trigger.** SSH warns that the host identification has changed.

**This should never happen.** The seal step deliberately keeps the guest's SSH
host keys, so the fingerprint is stable across every reset. That is what makes a
change meaningful instead of routine.

**What it means.** Either the base was rebuilt, in which case you know you did
it, or you are not talking to the guest you think you are.

**Steps.** If you rebuilt the base, clear the stored key and record the new
fingerprint that the seal step printed:

```bash
ssh-keygen -R 192.168.100.10 -f ~/.ssh/known_hosts_omavm
```

If you did not rebuild the base, stop and investigate before connecting.

---

## The guest boots to a black screen

**Trigger.** After a host `mesa` or kernel update, the guest starts but the
display never appears, or `virt-viewer` shows nothing.

**Why it happens.** virgl spans the host mesa stack and the guest driver. A
version skew between them shows up exactly this way.

**Steps.** First confirm it is graphics and not the guest by checking SSH:

```bash
./manage-agent-vm.sh webapp ssh -- uptime
```

If SSH works, the guest is fine and the problem is rendering. Boot without 3D:

```bash
./manage-agent-vm.sh webapp stop --force
ACCEL3D=no GL_ENABLE=no ./manage-agent-vm.sh webapp start --gui
```

That gives you a working, slow desktop with software rendering, which is enough
to keep working while the host packages catch up. Retry the normal path after
the next update.

To make the fallback the default for a while, set `ACCEL3D=no` and
`GL_ENABLE=no` in your shell profile rather than editing the template, so you do
not forget you changed it.

**Check the host log for the real error:**

```bash
sudo journalctl -u libvirtd -n 50
sudo cat /var/log/libvirt/qemu/omarchy-agent.log | tail -40
```

---

## Seal keeps running an old script

**Trigger.** You corrected something on the host, re-ran `seal`, ran the command
in the guest again, and got the identical error. The symptom is that a fix
appears to have no effect at all.

**Why it happens.** `seal` serves the script from a short-lived HTTP server. If
an earlier run was interrupted, its server is still holding the port. The new
one cannot bind, and the guest fetches the previous script, with the previous
settings compiled into it. From the guest there is nothing to see: the command
runs, it is just the wrong copy.

**Confirm.** More than one line here, or a directory you do not recognise, means
a leftover:

```bash
pgrep -af 'http.server'
```

To see which account the served script actually carries:

```bash
grep -m1 '^GUEST_USER=' /tmp/tmp.XXXXXX/s
```

**Steps.** Current versions stop leftovers automatically and refuse to continue
if the server does not come up. If you are on an older checkout, clear them by
hand:

```bash
pkill -f 'http.server 8765 --bind'
./manage-agent-vm.sh base seal
```

**Confirm.** `seal` now prints `Serving on 192.168.100.1:8765` once it has
verified the socket is listening. If you do not see that line, the script it
serves is not the one you think.

**The general lesson.** When a fix has no effect at all, suspect that the thing
you fixed is not the thing being executed, before suspecting the fix.

---

## The guest account name does not match

**Trigger.** The seal command fails in the guest with `no such user 'agent'`,
or `manage-agent-vm.sh ssh` cannot log in after a successful seal.

**Why it happens.** The account name is chosen during the Omarchy install, and
the host has no way to know it in advance. The configured `GUEST_USER` and the
account you actually created have drifted apart.

**Steps.** Sealing recovers on its own: the guest script falls back to the
account that invoked `sudo`, reports that name back to the host, and the host
switches to it for the rest of the run. It prints a warning saying which name
it found.

Make it permanent, or every later command will keep looking for the old name:

```bash
sed -i 's/^GUEST_USER=.*/GUEST_USER="thename"/' config/omavm.conf
```

**Confirm.**

```bash
./manage-agent-vm.sh webapp ssh -- id -un
```

**If you have already frozen a base** with the wrong name in the config, only
the config is wrong, not the image. Change it and carry on; there is no need to
re-seal or rebuild.

---

## Typed punctuation is wrong

**Trigger.** `manage-agent-vm.sh paste` puts the right letters in the guest but
the wrong symbols. A pipe arriving as a tilde is the classic one.

**Why it happens.** `paste` types at the virtual keyboard, so it sends key
positions, not characters. Which symbol a position produces is decided by the
layout configured **in the guest**, chosen during the Omarchy install. Letters
and digits are the same on every layout. Punctuation is not.

A pipe becoming a tilde means the guest is on a UK layout while the host is
sending US positions. On US, the key next to Enter is `\` and shifted gives
`|`. On UK, that same key is `#` and shifted gives `~`; the pipe lives on the
key to the left of Z instead.

**Steps.**

```bash
sed -i 's/^KEYBOARD_LAYOUT=.*/KEYBOARD_LAYOUT="${OMAVM_KEYBOARD_LAYOUT:-gb}"/' config/omavm.conf
```

Or for a single run, without changing anything:

```bash
OMAVM_KEYBOARD_LAYOUT=gb ./manage-agent-vm.sh webapp paste --enter 'some | text'
```

Supported values are `us` and `gb`. Add more in `apply_keyboard_layout` in
`manage-agent-vm.sh`.

**Confirm.**

```bash
./manage-agent-vm.sh webapp paste --dry-run 'a|b'
```

Under `gb` the pipe should be `KEY_LEFTSHIFT KEY_102ND`, under `us`
`KEY_LEFTSHIFT KEY_BACKSLASH`.

**Note.** This setting affects nothing except `paste`. Once the guest is sealed,
real clipboard sharing takes over and the layout stops mattering.

---

## Clipboard does not work between host and guest

**Trigger.** Copying in the guest and pasting on the host does nothing, or the
reverse.

**Use the SSH route. It works.**

```bash
./manage-agent-vm.sh webapp clip pull      # guest clipboard -> host
./manage-agent-vm.sh webapp clip push      # host clipboard -> guest
```

This does not involve SPICE at all, so it works with no viewer attached, which
is the normal state for an agent-driven guest.

**Why SPICE clipboard sharing does not work here.** The packaged
`spice-vdagent` is an X11 agent. Its own help says `guest session guest agent:
X11`, it depends on `libx11` and takes an X `--display`, and it syncs the
XWayland clipboard rather than the Wayland one. On a Hyprland guest the two are
not bridged in a way that propagates, so neither direction works even when
every part looks healthy:

| Check | Result on a working-looking guest |
|---|---|
| `spice-vdagentd` | active |
| `spice-vdagent` session client | running, `DISPLAY=:0` |
| XWayland | running |
| virt-viewer attached | yes |
| Clipboard actually syncing | **no** |

So do not spend time on the agent. Every component being healthy is consistent
with the clipboard not working, because the missing piece is Wayland support in
`spice-vdagent` itself.

**If you are trying keyboard shortcuts inside the guest**, Omarchy binds
`SUPER + C` for universal copy and `SUPER + V` for universal paste, not
`SUPER + SHIFT + C`. Check what is bound:

```bash
./manage-agent-vm.sh webapp ssh -- 'grep -rn "Universal" /usr/share/omarchy/default/hypr/bindings/clipboard.lua'
```

Those move text within the guest. Getting it to the host is the `clip` command
above.

**Confirm the round trip:**

```bash
./manage-agent-vm.sh webapp ssh -- 'printf hello | omarchy-ui clip-set'
./manage-agent-vm.sh webapp clip pull
wl-paste
```

**Note.** `clip` transfers text. It uses `wl-paste --no-newline`, so a trailing
newline is not preserved, and it is not a route for images or binary data.

---

## Seal stopped partway

**Trigger.** The seal script printed errors in the guest and the host is still
sitting at `waiting for ssh`.

**First, find out how far it got.** If SSH answers, the script got past the
remote access step and everything else can be fixed from the host:

```bash
./manage-agent-vm.sh webapp ssh -- true && echo "ssh is up"
```

**If SSH answers**, the seal script prints a summary of what did not complete.
Work through it from the host rather than re-running the whole thing:

```bash
./manage-agent-vm.sh webapp ssh -- omarchy-ui doctor
./manage-agent-vm.sh webapp ssh -- 'sudo pacman -S --needed grim ydotool wtype jq'
```

**If SSH does not answer but the seal script reported no errors**, the guest's
own firewall is the likely cause. Omarchy ships ufw with `default deny
incoming`, so a running sshd is still unreachable until the port is opened.
From inside the guest:

```
sudo ufw allow 22/tcp
```

Recent versions of the seal script do this for you, scoped to the host subnets.

**If SSH does not answer and the script did report errors**, the failure was in
the first step, which is almost always package installation. Check from inside
the guest:

```
ping -c1 archlinux.org
sudo pacman -Sy openssh
```

The usual causes are no working internet on the guest, or a pacman keyring that
needs initialising after a long-unused ISO:

```
sudo pacman-key --init && sudo pacman-key --populate archlinux
```

Fix that, then re-run `seal` on the host and the command in the guest.

**Why SSH comes first.** Everything after remote access is optional and
recoverable over SSH, so the seal script installs and starts sshd before doing
anything else. A guest that is half-sealed but reachable is a much better place
to be than one that is nearly ready and locked.

---

## You cannot paste into the guest

**Trigger.** Copying on the host and pasting into the guest does nothing.
Usually during an install or on a guest that has not been sealed.

**Why it happens.** SPICE clipboard sharing is not a property of the hypervisor
alone. It needs an agent at each end, and the guest end is `spice-vdagent`,
which the seal step installs. Before sealing there is nothing in the guest to
receive the clipboard, so the host side being configured correctly changes
nothing.

**Confirm the host side is not the problem:**

```bash
virsh --connect qemu:///system dumpxml omarchy-agent | grep clipboard
```

`copypaste='yes'` means the hypervisor is willing. If it says `no`, you are on
the sandbox profile, where clipboard sharing is off by design.

**Steps.** Have the host type it instead. This injects keystrokes at the
virtual keyboard through qemu, below anything the guest is running, so it needs
no guest agent and works from the firmware screen onwards:

```bash
./manage-agent-vm.sh webapp paste 'the text to type' --enter
./manage-agent-vm.sh webapp paste                    # or whatever is on your clipboard
```

Click into the guest window first, so the keystrokes land where you want them.

**Two limits worth knowing.** It assumes a US keyboard layout in the guest:
letters and digits are safe on any layout, but symbols are not, because a
symbol's keycode depends on the layout. And it types one key at a time, so a
long paste is visibly slow and anything non-ASCII is skipped with a warning.

**The permanent fix** is to finish sealing. After that `spice-vdagent` is
running and ordinary clipboard sharing works in both directions:

```bash
./manage-agent-vm.sh webapp ssh -- systemctl is-active spice-vdagentd
```

---

## The agent and your cursor are fighting

**Trigger.** The pointer in the guest jumps away from where the agent put it, or
the agent's clicks land in the wrong place while you are using your machine.

**Why it happens.** SPICE with an absolute pointing device forwards your host
pointer position into the guest whenever your pointer is over a focused viewer
window. The guest cursor then snaps to wherever your hand is. This is the only
path by which the two machines share input.

**Steps.** Close the viewer. The agent keeps working, because it drives the
guest over SSH and does not need one:

```bash
./manage-agent-vm.sh webapp watch
```

That pulls frames from the guest over SSH so you can see what is happening
without your pointer ever entering it.

**If you need a viewer open anyway**, minimise it or move it to a workspace you
are not using. An unfocused window with your pointer elsewhere does not forward
motion.

**Confirm.** Ask the compositor in the guest where its cursor is, rather than
trusting what you see:

```bash
./manage-agent-vm.sh webapp ssh -- hyprctl cursorpos
```

---

## Clicks land in the wrong place

**Trigger.** `omarchy-ui at X Y` moves the pointer somewhere other than X,Y, or
clicks land at the wrong spot, often near a screen edge.

**Why it happens.** ydotool units are not screen pixels. On this guest a
request to move 100 lands the pointer 200 pixels away, for absolute and
relative moves alike, and nothing in the compositor's input configuration
accounts for it. Positions past half the screen get clamped to the edge, which
is why the symptom often looks like "everything ends up bottom right".

`omarchy-ui` measures the factor once per session and then verifies each move
against `hyprctl cursorpos`, so it should be pixel exact regardless.

**Check it:**

```bash
./manage-agent-vm.sh webapp ssh -- 'omarchy-ui move 960 540 && omarchy-ui cursor'
# 960 540
```

Anything other than the requested numbers means the correction is not working.

**Steps.** Drop the cached calibration and let it measure again. It is keyed to
the compositor instance, so a restarted session recalibrates on its own, but a
resolution change within one session will not:

```bash
./manage-agent-vm.sh webapp ssh -- 'rm -f $XDG_RUNTIME_DIR/omarchy-ui-pointer-scale'
./manage-agent-vm.sh webapp ssh -- 'omarchy-ui move 960 540 && omarchy-ui cursor'
```

**If it is still wrong**, confirm the compositor is reporting sensibly:

```bash
./manage-agent-vm.sh webapp ssh -- omarchy-ui monitors
```

The coordinate space is the full monitor layout, so a second output placed to
the left gives negative x values.

---

## The agent cannot click or type

**Trigger.** `ydotool` reports it cannot connect to its socket, or commands run
without error but nothing moves in the guest.

**Why it happens.** `ydotool` needs a daemon holding `/dev/uinput`, and the
client finds it through `YDOTOOL_SOCKET`. Both are set up during sealing. A
guest built before that, or one where the agent user was changed afterwards,
will not have them.

**Steps.** Check the daemon is running in the user session, not as root:

```bash
./manage-agent-vm.sh webapp ssh -- systemctl --user status ydotoold
./manage-agent-vm.sh webapp ssh -- 'echo $YDOTOOL_SOCKET'
```

Or ask the tool itself, which checks every part of the path:

```bash
./manage-agent-vm.sh webapp ssh -- omarchy-ui doctor
```

If the unit is missing, the base predates the control kit and needs re-sealing:

```bash
./manage-agent-vm.sh base refresh
./manage-agent-vm.sh base seal
./manage-agent-vm.sh webapp stop && ./manage-agent-vm.sh base freeze
```

If the unit is present but failing, the uinput device is usually the cause:

```bash
./manage-agent-vm.sh webapp ssh -- 'ls -l /dev/uinput; id'
```

The agent user must be in the `input` group, and the device must be mode 0660
owned by that group. Group membership needs a fresh login, so reboot the guest
rather than just retrying.

**Note.** A command issued over SSH picks up `YDOTOOL_SOCKET` only through the
login shell. Run agent commands with `bash -lc` if you are invoking them in a
way that skips profile scripts.

---

## Updating the agent skill

**Trigger.** You edited `guest/skills/omarchy-ui/SKILL.md` or the `omarchy-ui`
script and want the guest to have the change.

**Why it needs doing.** The skill is installed into the base image at seal
time. Editing the repository changes nothing in a running guest, and a `reset`
would discard anything you copied in by hand.

**For a quick iteration**, push it into the running guest:

```bash
./manage-agent-vm.sh webapp sync-ui
```

It copies the tool and the skill in, installs them, and then checks that the
guest is running the build you just sent. That check matters: a stale copy is
invisible otherwise, because it runs perfectly well and simply lacks whatever
you added since. Compare by hand any time you are unsure:

```bash
sha256sum guest/skills/omarchy-ui/scripts/omarchy-ui | cut -c1-12
./manage-agent-vm.sh webapp ssh -- omarchy-ui build
```

`sync-ui` survives until the next `reset`, which is what you want while you are
still changing the tool.

**To make it permanent**, put it in the base:

```bash
./manage-agent-vm.sh base refresh
./manage-agent-vm.sh base seal
./manage-agent-vm.sh base stop
./manage-agent-vm.sh base freeze
```

**Confirm.**

```bash
./manage-agent-vm.sh webapp reset
./manage-agent-vm.sh webapp start
./manage-agent-vm.sh webapp ssh -- omarchy-ui --help | head -3
```

Running `reset` first is the point: it proves the change is in the base rather
than in a copy that a reset would throw away.

---

## The file share is not mounted

**Trigger.** `/mnt/omavm` is empty in the guest, or the mount is missing.

**First, is a share configured at all?** It is off by default:

```bash
./manage-agent-vm.sh webapp status
```

If it says `disabled`, set `SHARE_DIR` in `config/omavm.conf` and restart the
guest. The device is only added to the domain when a share is configured, so
this needs a stop and start rather than a mount command.

**If it says enabled but the guest has nothing:**

```bash
./manage-agent-vm.sh webapp ssh -- 'mount | grep virtiofs; sudo mount -a'
```

The fstab entry uses `nofail`, deliberately, so the guest still boots when the
share is absent. That means a failed mount is quiet rather than fatal, and you
have to look for it.

**Two things that will not work.** The share is ignored entirely in the sandbox
profile, where a shared filesystem would bypass the network controls. And
changing `SHARE_READONLY` requires a restart, because it is a property of the
device rather than of the mount.

---

## The guest resolution is wrong

**Trigger.** The guest desktop is smaller than you expect, typically 1280x800,
or resizing the viewer window does not change the guest resolution.

**Why it happens.** There are two mechanisms and they apply at different times.

Before the display agent is running, the resolution comes from the EDID the
virtual GPU presents. That covers the UEFI console, the installer, and every
boot up to the point the guest session starts. Without an explicit setting the
virtio-gpu default is 1280x800.

Once the guest is sealed, `spice-vdagent` is installed and running, and it
resizes the guest to match the viewer window.

**Steps, for the fixed resolution.** Change the values in
`config/omavm.conf`:

```bash
VIDEO_WIDTH="1920"
VIDEO_HEIGHT="1080"
```

The domain is re-rendered on every boot, so this applies at the next start. It
does **not** affect a running guest:

```bash
./manage-agent-vm.sh webapp stop
./manage-agent-vm.sh webapp start --gui
```

**Steps, for dynamic resizing.** This only works on a sealed guest, because the
installer media does not run a display agent. Check the agent is up:

```bash
./manage-agent-vm.sh webapp ssh -- systemctl is-active spice-vdagentd
```

Then enable automatic resizing in the viewer, under View, "Automatically resize".
Without it `virt-viewer` scales the image instead of asking the guest to change
resolution, which looks blurry rather than sharp.

**Confirm.**

```bash
./manage-agent-vm.sh webapp ssh -- hyprctl monitors
```

**Worth keeping in mind.** A fixed resolution is a feature for agent work, not a
limitation. Coordinate based clicking depends on the viewport being the same
size on every reset, and screenshots are only comparable across runs if the
geometry does not move. Prefer changing the configured resolution over letting
the window size decide it.

---

## The installer shows no encryption option

**Trigger.** Building the base, you are looking for a way to install without
disk encryption and there is no menu item for it.

**Why it happens.** Encryption is on by default and the way to turn it off is a
keypress, not a choice in a list. The installer's prompt library exits on only
two keys, so Ctrl+C is reused as a toggle rather than meaning cancel.

**Steps.** Continue to the final confirmation, the screen that says everything
will be overwritten and there is no recovery possible. Below that line is a dim
grey hint:

```
Press Ctrl+C for unencrypted install.
```

Press Ctrl+C. The confirm button changes from "Yes, install" to **"Yes, install
without encryption"**. Press that.

Pressing Ctrl+C again toggles back, so you can check which mode you are in by
reading the button rather than guessing.

**Confirm after installing:**

```bash
./manage-agent-vm.sh base ssh -- lsblk -o NAME,FSTYPE
```

No `crypto_LUKS` row means it worked.

**Why it matters here.** An encrypted guest asks for a passphrase at every
boot, so it cannot start unattended and `reset` stops being useful. On the host
it is the right default; in a disposable VM whose disk is an overlay of a
public base image, it protects nothing.

---

## The guest never gets an IP address

**Trigger.** The guest has no address on the expected subnet. Symptoms include
`curl` in the guest reporting it cannot connect to the host address, and SSH
timing out with the domain running.

**First, confirm it is a lease problem** rather than a routing one. An empty
lease table with the guest transmitting is the signature:

```bash
virsh --connect qemu:///system net-dhcp-leases agent-sandbox-net
sudo wc -c /var/lib/libvirt/dnsmasq/virbr-agent.status
cat /sys/class/net/virbr-agent/statistics/rx_packets
```

A zero-byte status file means dnsmasq never granted a lease. A rising packet
count means the guest is asking and getting no answer.

**Why it happens.** DHCP DISCOVER is broadcast to 255.255.255.255, not sent to
the bridge address. A ufw rule written as `to 192.168.100.1 port 67` therefore
never matches it, the default deny drops it, and the guest waits forever. The
rule has to be scoped by interface instead:

```bash
sudo ufw status | grep 67
```

You want to see `67/udp on virbr-agent`, not `192.168.100.1 67/udp`.

**Steps.** Re-running the installer repairs both bridges. It deletes the
address-scoped rule and replaces it with the interface-scoped one:

```bash
./install_host_deps.sh --yes
```

For the build bridge, `manage-agent-vm.sh build` and `seal` reapply it on their
next run.

**Confirm.** Restart networking in the guest, or just wait for the next DHCP
retry, then:

```bash
virsh --connect qemu:///system net-dhcp-leases agent-sandbox-net
```

**Related.** libvirt writes its own accept rules for DHCP into its own nftables
table, which is why this looks like it should already work. It does not help:
with nftables, every table gets to drop a packet independently, so ufw's deny
still wins regardless of what libvirt permits.

---

## The guest got the wrong address

**Trigger.** `./manage-agent-vm.sh webapp ssh` times out, and
`./manage-agent-vm.sh webapp status` shows the VM running.

**Why it happens.** The DHCP reservation matches on MAC. If the guest sends a
client identifier derived from something else, dnsmasq may not match the
reservation and hands out a different address.

**Steps.** Find the address it actually took:

```bash
sudo virsh net-dhcp-leases agent-sandbox-net
```

The seal step writes `/etc/NetworkManager/conf.d/10-omavm-dhcp.conf` to pin the
client identifier to the MAC. If that file is missing from the guest, the base
was built before that fix and needs re-sealing.

---

## Permission denied on a file you passed to the VM

**Trigger.** Starting the domain fails with a monitor error like:

```
Could not open '/home/you/Downloads/something.iso': Permission denied
```

**Why it happens.** QEMU does not run as you. libvirt starts it as an
unprivileged system user, and that user cannot traverse a `0700` home
directory. The mode on the file itself is irrelevant, because the process
cannot reach it in the first place. `namei -l` on the path shows which
directory is blocking:

```bash
namei -l ~/Downloads/omarchy-4.0.3.iso
```

**Steps.** `manage-agent-vm.sh build` stages the ISO into
`/var/lib/libvirt/images/omavm/` automatically, so re-running it is the fix.
For any other file you want to attach, copy it there yourself:

```bash
sudo cp --reflink=auto /path/to/file /var/lib/libvirt/images/omavm/
sudo chown root:root /var/lib/libvirt/images/omavm/file
sudo chmod 0644 /var/lib/libvirt/images/omavm/file
```

**Do not** `chmod o+x` your home directory to work around this. That grants
every local user traversal into it, permanently, to fix one file.

**Check afterwards.** libvirt applies dynamic ownership to whatever it is
pointed at, so a failed attempt may have left your original file chowned to the
qemu user:

```bash
ls -l ~/Downloads/omarchy-4.0.3.iso
```

If the owner is not you, take it back:

```bash
sudo chown "$USER:$(id -gn)" ~/Downloads/omarchy-4.0.3.iso
```

The build command now does this for you, but older copies may still be affected.

---

## Disk is filling up

**Trigger.** `/var/lib` is short of space, or `./manage-agent-vm.sh webapp status`
shows a large overlay.

**Why it happens.** The overlay accumulates every block the guest has written
since the last reset. A long agent run that downloads a lot can grow it to many
gigabytes.

**Steps.**

```bash
./manage-agent-vm.sh webapp reset
```

That is the whole fix. A fresh overlay is a few hundred kilobytes.

To see where the space actually went:

```bash
sudo du -h /var/lib/libvirt/images/omavm/*
```

The base image is compressed at freeze time and does not grow between refreshes.

Staged installer ISOs also live in that directory and are several gigabytes
each. They are only needed during a build, so once you have a frozen base they
can go:

```bash
sudo rm /var/lib/libvirt/images/omavm/*.iso
```

---

## Things this runbook deliberately does not cover

**Renewing a TLS interception CA.** There is none. The proxy uses CONNECT and
never decrypts TLS, specifically so that no certificate authority has to be
generated, trusted inside the guest, and rotated on a schedule.

**Refreshing allowlisted IP addresses.** The allowlist matches hostnames, not
addresses, so there is nothing to re-resolve when a CDN moves.

**Snapshot housekeeping.** There are no libvirt snapshots to prune. State is a
copy-on-write overlay that is deleted and recreated, so there is no chain to
manage and nothing that grows without bound.
