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
| Clipboard still does not work after sealing | [Start the session agent](#clipboard-does-not-work-after-sealing) | Once per guest |
| Seal reports the wrong guest account | [Set GUEST_USER](#the-guest-account-name-does-not-match) | After an install |
| Seal keeps failing the same way after a fix | [Check for a stale seal server](#seal-keeps-running-an-old-script) | After an interrupted seal |
| The agent cannot click or type in the guest | [Repair the input path](#the-agent-cannot-click-or-type) | Rare |
| You changed the agent skill or `omarchy-ui` | [Push the change into the guest](#updating-the-agent-skill) | Whenever you edit it |
| The file share is missing in the guest | [Fix the share](#the-file-share-is-not-mounted) | Rare |
| Guest is unreachable at its usual address | [Fix DHCP addressing](#the-guest-got-the-wrong-address) | Rare |
| Guest has no IP address at all | [Diagnose a missing lease](#the-guest-never-gets-an-ip-address) | Rare |
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

## The base image is stale

**Trigger.** Any of:

- The base is more than about a month old. Check with
  `./manage-agent-vm.sh status`.
- An agent needs a package that is not in the base.
- An Omarchy release you want to test against has shipped.

**Why it matters.** Every reset returns to the base exactly. Nothing an agent
installs survives, by design, so the only way to change what the guest has is to
rebuild the base.

**Steps.**

```bash
./manage-agent-vm.sh refresh          # boots a writable copy of the base on the NAT network
./manage-agent-vm.sh ssh
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
./manage-agent-vm.sh stop
./manage-agent-vm.sh freeze           # compacts, replaces the base, closes the build network, resets
```

**Confirm.**

```bash
./manage-agent-vm.sh status
```

**Note.** The old base is not deleted until `freeze` succeeds, so a refresh that
goes wrong costs you nothing. If you abandon a refresh halfway, run
`./manage-agent-vm.sh reset` to go back to the frozen base.

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
./manage-agent-vm.sh start
./verify-isolation.sh                 # full check with the guest up
```

If the guest fails to boot after an `edk2-ovmf` upgrade, reset. That restores
NVRAM from the new firmware template:

```bash
./manage-agent-vm.sh reset
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
./manage-agent-vm.sh stop --force
```

**`Base image mode is not 444`.** Resets are no longer deterministic, because
something has been able to write to the base:

```bash
sudo chmod 0444 /var/lib/libvirt/images/omavm/omarchy-agent-base.qcow2
./manage-agent-vm.sh reset
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
./manage-agent-vm.sh refresh          # boot the base writable
./manage-agent-vm.sh seal             # reinstalls the new public key
./manage-agent-vm.sh stop
./manage-agent-vm.sh freeze
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
./manage-agent-vm.sh ssh -- uptime
```

If SSH works, the guest is fine and the problem is rendering. Boot without 3D:

```bash
./manage-agent-vm.sh stop --force
ACCEL3D=no GL_ENABLE=no ./manage-agent-vm.sh start --gui
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
./manage-agent-vm.sh seal
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
./manage-agent-vm.sh ssh -- id -un
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
OMAVM_KEYBOARD_LAYOUT=gb ./manage-agent-vm.sh paste --enter 'some | text'
```

Supported values are `us` and `gb`. Add more in `apply_keyboard_layout` in
`manage-agent-vm.sh`.

**Confirm.**

```bash
./manage-agent-vm.sh paste --dry-run 'a|b'
```

Under `gb` the pipe should be `KEY_LEFTSHIFT KEY_102ND`, under `us`
`KEY_LEFTSHIFT KEY_BACKSLASH`.

**Note.** This setting affects nothing except `paste`. Once the guest is sealed,
real clipboard sharing takes over and the layout stops mattering.

---

## Clipboard does not work after sealing

**Trigger.** The guest is sealed, `spice-vdagentd` is running, and copy and
paste between host and guest still does nothing in either direction.

**Why it happens.** Clipboard sharing needs **two** processes in the guest, and
enabling the obvious one is not enough.

| Process | Kind | What it does |
|---|---|---|
| `spice-vdagentd` | system service | talks to the host over the virtio channel |
| `spice-vdagent` | per-session client | talks to the compositor holding the clipboard |

The per-session client ships as an XDG autostart entry, which Hyprland does not
read directly. Without it the daemon has nothing to exchange clipboard data
with, and fails silently rather than complaining.

**Check both:**

```bash
./manage-agent-vm.sh ssh -- systemctl is-active spice-vdagentd
./manage-agent-vm.sh ssh -- pgrep -a spice-vdagent
```

The second must show a process **without** the trailing `d`. If only
`spice-vdagentd` appears, that is the fault.

**Steps.** Sealing installs a user unit for the session client. It starts at the
next login, not immediately, so the guest needs a reboot:

```bash
./manage-agent-vm.sh ssh -- sudo reboot
```

If it still does not appear after that:

```bash
./manage-agent-vm.sh ssh -- systemctl --user status spice-vdagent
```

**Also check the hypervisor is willing**, which it will not be in the sandbox
profile:

```bash
virsh --connect qemu:///system dumpxml omarchy-agent | grep clipboard
```

**Note.** The same reasoning applies to `ydotoold`, which is also a session
service. Both need one login after sealing before they exist, which is why the
seal step now tells you to reboot before freezing.

---

## Seal stopped partway

**Trigger.** The seal script printed errors in the guest and the host is still
sitting at `waiting for ssh`.

**First, find out how far it got.** If SSH answers, the script got past the
remote access step and everything else can be fixed from the host:

```bash
./manage-agent-vm.sh ssh -- true && echo "ssh is up"
```

**If SSH answers**, the seal script prints a summary of what did not complete.
Work through it from the host rather than re-running the whole thing:

```bash
./manage-agent-vm.sh ssh -- omarchy-ui doctor
./manage-agent-vm.sh ssh -- 'sudo pacman -S --needed grim ydotool wtype jq'
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
./manage-agent-vm.sh paste 'the text to type' --enter
./manage-agent-vm.sh paste                    # or whatever is on your clipboard
```

Click into the guest window first, so the keystrokes land where you want them.

**Two limits worth knowing.** It assumes a US keyboard layout in the guest:
letters and digits are safe on any layout, but symbols are not, because a
symbol's keycode depends on the layout. And it types one key at a time, so a
long paste is visibly slow and anything non-ASCII is skipped with a warning.

**The permanent fix** is to finish sealing. After that `spice-vdagent` is
running and ordinary clipboard sharing works in both directions:

```bash
./manage-agent-vm.sh ssh -- systemctl is-active spice-vdagentd
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
./manage-agent-vm.sh watch
```

That pulls frames from the guest over SSH so you can see what is happening
without your pointer ever entering it.

**If you need a viewer open anyway**, minimise it or move it to a workspace you
are not using. An unfocused window with your pointer elsewhere does not forward
motion.

**Confirm.** Ask the compositor in the guest where its cursor is, rather than
trusting what you see:

```bash
./manage-agent-vm.sh ssh -- hyprctl cursorpos
```

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
./manage-agent-vm.sh ssh -- systemctl --user status ydotoold
./manage-agent-vm.sh ssh -- 'echo $YDOTOOL_SOCKET'
```

Or ask the tool itself, which checks every part of the path:

```bash
./manage-agent-vm.sh ssh -- omarchy-ui doctor
```

If the unit is missing, the base predates the control kit and needs re-sealing:

```bash
./manage-agent-vm.sh refresh
./manage-agent-vm.sh seal
./manage-agent-vm.sh stop && ./manage-agent-vm.sh freeze
```

If the unit is present but failing, the uinput device is usually the cause:

```bash
./manage-agent-vm.sh ssh -- 'ls -l /dev/uinput; id'
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

**For a quick iteration**, copy it into the running guest and try it:

```bash
scp -i ~/.ssh/omavm_agent_ed25519 \
    guest/skills/omarchy-ui/scripts/omarchy-ui agent@192.168.100.10:/tmp/
./manage-agent-vm.sh ssh -- sudo install -m 0755 /tmp/omarchy-ui /usr/local/bin/omarchy-ui
./manage-agent-vm.sh ssh -- omarchy-ui doctor
```

That survives until the next `reset`, which is what you want while you are
still changing it.

**To make it permanent**, put it in the base:

```bash
./manage-agent-vm.sh refresh
./manage-agent-vm.sh seal
./manage-agent-vm.sh stop
./manage-agent-vm.sh freeze
```

**Confirm.**

```bash
./manage-agent-vm.sh reset
./manage-agent-vm.sh start
./manage-agent-vm.sh ssh -- omarchy-ui --help | head -3
```

Running `reset` first is the point: it proves the change is in the base rather
than in a copy that a reset would throw away.

---

## The file share is not mounted

**Trigger.** `/mnt/omavm` is empty in the guest, or the mount is missing.

**First, is a share configured at all?** It is off by default:

```bash
./manage-agent-vm.sh status
```

If it says `disabled`, set `SHARE_DIR` in `config/omavm.conf` and restart the
guest. The device is only added to the domain when a share is configured, so
this needs a stop and start rather than a mount command.

**If it says enabled but the guest has nothing:**

```bash
./manage-agent-vm.sh ssh -- 'mount | grep virtiofs; sudo mount -a'
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
./manage-agent-vm.sh stop
./manage-agent-vm.sh start --gui
```

**Steps, for dynamic resizing.** This only works on a sealed guest, because the
installer media does not run a display agent. Check the agent is up:

```bash
./manage-agent-vm.sh ssh -- systemctl is-active spice-vdagentd
```

Then enable automatic resizing in the viewer, under View, "Automatically resize".
Without it `virt-viewer` scales the image instead of asking the guest to change
resolution, which looks blurry rather than sharp.

**Confirm.**

```bash
./manage-agent-vm.sh ssh -- hyprctl monitors
```

**Worth keeping in mind.** A fixed resolution is a feature for agent work, not a
limitation. Coordinate based clicking depends on the viewport being the same
size on every reset, and screenshots are only comparable across runs if the
geometry does not move. Prefer changing the configured resolution over letting
the window size decide it.

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

**Trigger.** `./manage-agent-vm.sh ssh` times out, and
`./manage-agent-vm.sh status` shows the VM running.

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

**Trigger.** `/var/lib` is short of space, or `./manage-agent-vm.sh status`
shows a large overlay.

**Why it happens.** The overlay accumulates every block the guest has written
since the last reset. A long agent run that downloads a lot can grow it to many
gigabytes.

**Steps.**

```bash
./manage-agent-vm.sh reset
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
