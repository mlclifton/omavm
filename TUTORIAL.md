# Driving the guest desktop: a walkthrough

Every command here was run against a real guest and produced the output shown.
Work through it in order and you will have driven a full Omarchy desktop from
your host terminal, without a viewer window and without touching the guest's
mouse or keyboard yourself.

All of it runs from the host, in `~/Projects/omavm`.

## Before you start

This walkthrough uses a VM called `webapp`. Create one if you have not already,
and substitute your own name throughout:

```bash
./manage-agent-vm.sh new webapp
./manage-agent-vm.sh webapp start
./manage-agent-vm.sh webapp ssh -- omarchy-ui doctor
```

The name always comes first, before the command. That is deliberate: it cannot
be forgotten, so you cannot reset the wrong guest.

You want nine `ok` lines. `clipboard readable` may say `ok (empty)`, which is
fine: it means the clipboard is working and has nothing on it.

```
omarchy-ui environment:
  hyprctl responds             ok
  a monitor is present         ok
  grim captures                ok
  wtype present                ok
  ydotool present              ok
  ydotoold socket              ok
  omarchy shell responds       ok
  OMARCHY_PATH resolved        ok
  clipboard readable           ok (empty)
```

If anything says `FAILED`, stop and read the line under it. `doctor` names the
specific broken thing rather than making you guess.

**If you see only eight checks and no `OMARCHY_PATH` line**, the guest is
running an older build of the tool than this repository has. Push the current
one in:

```bash
./manage-agent-vm.sh webapp sync-ui
```

A stale copy is otherwise invisible, because it runs fine and simply lacks
whatever was added since. `omarchy-ui build` prints a digest you can compare
against `sha256sum guest/skills/omarchy-ui/scripts/omarchy-ui | cut -c1-12`.

---

## Step 1 — look before you touch

Ask the compositor what is on screen. This is faster than a screenshot and it
gives you exact numbers rather than an estimate.

```bash
./manage-agent-vm.sh webapp ssh -- omarchy-ui monitors
```

```
Virtual-1  1920x1080@74  at 0,0  scale=1  focused=true
```

That is your coordinate space. All positions are in these pixels.

```bash
./manage-agent-vm.sh webapp ssh -- omarchy-ui windows
./manage-agent-vm.sh webapp ssh -- omarchy-ui layers
```

On a fresh desktop `windows` prints nothing, because there are none. `layers`
shows the pieces of the Omarchy shell:

```
Virtual-1  level=0  0,0 1920x1080  omarchy-background
Virtual-1  level=2  0,0 1920x26    omarchy-bar
```

**The bar is a layer, not a window.** It will never appear in `windows`. That
catches people out, so check `layers` whenever something you can see is not in
the window list.

## Step 2 — take a screenshot

```bash
./manage-agent-vm.sh webapp ssh -- omarchy-ui shot - > desktop.png
```

The `-` sends the PNG to stdout so you can redirect it to the host. Leave it off
and the file stays in the guest, with the path printed.

```bash
file desktop.png
# desktop.png: PNG image data, 1920 x 1080, 8-bit/color RGB
```

`grim` captures what the compositor actually renders, so menus, popups and the
bar are all included.

## Step 3 — open an app

```bash
./manage-agent-vm.sh webapp ssh -- omarchy-ui launch foot
./manage-agent-vm.sh webapp ssh -- omarchy-ui wait-window foot 10
```

`wait-window` blocks until the window exists and fails if it never does. **Do
not skip it.** Clicking where a window is about to be is the most common way
this kind of automation goes wrong.

```bash
./manage-agent-vm.sh webapp ssh -- omarchy-ui windows
```

```
0x556abeaee620  ws=1  12,38 1896x1030  class=foot  title=omadev@omarchy-agent:~
```

## Step 4 — click, and type

```bash
./manage-agent-vm.sh webapp ssh -- omarchy-ui click-window foot
./manage-agent-vm.sh webapp ssh -- omarchy-ui focused
```

```
0x556abeaee620  12,38 1896x1030  class=foot  title=omadev@omarchy-agent:~
```

`click-window` finds the window by class or title and clicks its centre. If your
match hits more than one window it stops and lists them, rather than picking one
for you.

Now type into it:

```bash
./manage-agent-vm.sh webapp ssh -- omarchy-ui type "echo hello from the guest"
./manage-agent-vm.sh webapp ssh -- omarchy-ui key Return
```

Check it worked by capturing just that window:

```bash
./manage-agent-vm.sh webapp ssh -- omarchy-ui shot --window foot - > term.png
```

The screenshot shows the command and its output. Key names are X keysyms:
`Return`, `Escape`, `Tab`, `space`, `F5`. Combinations use `ctrl+c`,
`super+space` and so on.

## Step 5 — click at exact coordinates

When you already know where something is, skip the matching:

```bash
./manage-agent-vm.sh webapp ssh -- omarchy-ui at 960 540
./manage-agent-vm.sh webapp ssh -- omarchy-ui at 100 13 right
./manage-agent-vm.sh webapp ssh -- omarchy-ui cursor
```

The bar is 26 pixels tall at the top, so `y=13` is the middle of it. Get its
real geometry with `omarchy-ui bar` rather than assuming.

## Step 6 — open the Omarchy menu

```bash
./manage-agent-vm.sh webapp ssh -- omarchy-ui menu system
./manage-agent-vm.sh webapp ssh -- omarchy-ui layers
```

```
Virtual-1  level=3  0,0 1920x1080  omarchy-menu
```

Routes are `root`, `apps`, `capture`, `hardware`, `system`, `theme`,
`background`, `share` and `toggle`.

```bash
./manage-agent-vm.sh webapp ssh -- omarchy-ui shot - > menu.png
./manage-agent-vm.sh webapp ssh -- omarchy-ui menu-close
```

This calls the shell's IPC directly rather than pressing `SUPER + SPACE`, and
waits for the menu to actually appear. It also summons rather than toggles, so
calling it twice leaves the menu open both times instead of flipping it shut.

## Step 7 — move text between guest and host

```bash
./manage-agent-vm.sh webapp ssh -- 'printf "copied inside the guest" | omarchy-ui clip-set'
./manage-agent-vm.sh webapp clip pull
wl-paste
# copied inside the guest
```

And the other way:

```bash
printf 'from the host' | wl-copy
./manage-agent-vm.sh webapp clip push
./manage-agent-vm.sh webapp ssh -- omarchy-ui clip-get
# from the host
```

**Do not wait for the SPICE clipboard to work.** The packaged `spice-vdagent`
is an X11 agent and does not sync a Wayland session's clipboard, so nothing
crosses the boundary on its own however healthy every component looks.
`clip push` and `clip pull` go over SSH and do not involve SPICE at all.

Inside the guest, Omarchy binds `SUPER + C` and `SUPER + V` for copy and paste
between guest applications. Those never reach the host; `clip` is what does.

## Step 8 — watch without interfering

```bash
./manage-agent-vm.sh webapp watch          # frames every 2 seconds
./manage-agent-vm.sh webapp watch 5        # or every 5
```

This pulls frames over SSH. Your pointer never enters the guest, so an agent
driving the cursor keeps it.

In a terminal that can draw images, such as foot or kitty, the frames appear
directly in the terminal. `watch` asks the terminal whether it supports sixel
rather than guessing from `$TERM`, because drawing sixel at a terminal that
cannot render it fills the screen with rubbish. Force it with `--inline` if
your terminal supports it but does not say so, and `--no-inline` to just write
the file.

Without image support each frame is written to one path, printed at the start,
which you can open in any viewer.

You can attach a real viewer instead:

```bash
./manage-agent-vm.sh webapp gui
```

But understand the trade. **A focused viewer window forwards your host pointer
into the guest**, so moving your mouse over it will fight whatever the agent is
doing. Use `watch` while an agent is working, and `gui` when you want to take
over yourself.

## Step 9 — put it back

```bash
./manage-agent-vm.sh webapp reset
```

Destroys the running guest, discards every change since the last reset, and
recreates the disk from the frozen base. It takes about as long as creating a
small file, because only a copy-on-write overlay is replaced.

---

## Putting it together

A complete loop an agent can run, with a check after every action:

```bash
#!/usr/bin/env bash
set -euo pipefail
VM=webapp
MANAGE=~/Projects/omavm/manage-agent-vm.sh
run() { "$MANAGE" "$VM" ssh -- omarchy-ui "$@"; }

run doctor >/dev/null || { echo "guest not ready"; exit 1; }

run launch foot
run wait-window foot 10

run click-window foot
run type "uname -a"
run key Return

run shot - > /tmp/result.png
echo "captured $(file -b /tmp/result.png)"
```

## The habits that matter

- **Ask the compositor, do not read pixels.** `windows` and `layers` give exact
  geometry. Screenshots are for judging what something looks like, not for
  working out where to click.
- **Wait after opening anything.** `wait-window` and `wait-layer` exist because
  clicking too early is the most common failure.
- **Match precisely.** An ambiguous window match stops rather than guessing.
- **Keep the resolution fixed.** Coordinate clicking only reproduces if the
  viewport is identical every run. That is why it is pinned at 1920x1080 in
  `config/omavm.conf` rather than following the viewer window.

## When something breaks

```bash
./manage-agent-vm.sh webapp ssh -- omarchy-ui doctor
```

The two you are most likely to see:

- **`ydotoold socket FAILED`** means the input daemon is not running. Pointer
  and clicks need it; typing and screenshots do not, which is why typing can
  work while clicking silently does nothing.
- **`hyprctl responds FAILED`** means there is no graphical session for that
  user, so there is no desktop to drive.

`OPERATIONS.md` covers the rest, each entry with the circumstance that triggers
it.
