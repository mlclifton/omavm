---
name: omarchy-ui
description: Drive the Omarchy desktop on Hyprland - take screenshots, move and click the pointer, type, inspect window geometry, and open the Omarchy menu bar and its widgets. Use for any task that needs to see or interact with the graphical desktop rather than the terminal, including clicking buttons, reading what is on screen, testing a GUI change, or automating the bar, menu, theme picker and other Omarchy shell surfaces.
---

# Driving the Omarchy desktop

Everything here goes through one command, `omarchy-ui`. Run `omarchy-ui` with no
arguments for the full list.

## Ask the compositor, do not read pixels

This is the single most important habit. Hyprland knows exactly where every
window and panel is, and asking it is faster and more reliable than looking at
a screenshot and estimating.

```bash
omarchy-ui windows      # every window: address, geometry, class, title
omarchy-ui focused      # the focused window
omarchy-ui layers       # bar, menus, pickers. These are NOT windows.
omarchy-ui monitors     # outputs, resolution, scale
omarchy-ui bar          # geometry of the Omarchy bar
```

Take a screenshot to understand what something looks like, or to check a visual
result. Do not take one to work out where to click.

## The loop

Inspect, act, verify. Never act twice without checking in between.

```bash
omarchy-ui click-window "foot"          # clicks the centre of that window
omarchy-ui type "hello"
omarchy-ui key Return
omarchy-ui shot /tmp/after.png          # confirm it did what you expected
```

`click-window` takes a case-insensitive substring matched against class and
title. If it matches more than one window it stops and lists them rather than
guessing, so narrow the match.

## Wait before you click

The most common failure is clicking where something is about to be. Opening a
window or a menu is not instant.

```bash
omarchy-ui key super+Return             # Omarchy opens a terminal
omarchy-ui wait-window foot 5           # block until it exists
omarchy-ui click-window foot
```

`wait-layer` does the same for shell surfaces like the menu.

## The Omarchy shell

The bar and the menu are layer surfaces, not windows, so they never appear in
`omarchy-ui windows`. Use `omarchy-ui layers`. The bar's namespace is
`omarchy-bar` and it sits along the top edge, 24 pixels tall.

Open the menu by route rather than by chording keys:

```bash
omarchy-ui menu              # root
omarchy-ui menu system
omarchy-ui menu-close
```

Routes: `root`, `apps`, `capture`, `hardware`, `system`, `theme`,
`background`, `share`, `toggle`.

This uses `summon`, not `toggle`, on purpose. Toggle depends on the current
state, so calling it twice leaves the menu closed and you cannot tell from the
outside which happened. `omarchy-ui menu` also waits for the menu to actually
appear and fails if it does not.

To click something in the bar, read the bar's geometry first, then screenshot
that strip to see what is in it:

```bash
omarchy-ui bar                                   # e.g. 0,0 1920x24
omarchy-ui shot --region 0,0 1920x24 /tmp/bar.png
```

## Screenshots

```bash
omarchy-ui shot                      # whole screen, prints the path it wrote
omarchy-ui shot --window Spotify     # just that window
omarchy-ui shot --region 0,0 800x600
omarchy-ui shot -                    # PNG on stdout, to pipe somewhere
```

`grim` captures the compositor's own output, so menus, popups and the bar are
all included, exactly as a person would see them.

## Keyboard

```bash
omarchy-ui type "some text"
omarchy-ui key Return
omarchy-ui key ctrl+c
omarchy-ui key super+space           # the Omarchy menu binding
```

Key names are X keysyms: `Return`, `Escape`, `Tab`, `space`, `Left`, `F5`.
Modifiers are `ctrl`, `shift`, `alt`, `super`.

## Coordinates

All coordinates are Hyprland logical pixels and are **global across every
output**, not relative to a window or a screen. A second monitor placed to the
left has negative x values. Check `omarchy-ui monitors` before assuming an
origin of 0,0.

## When something does not work

```bash
omarchy-ui doctor
```

It checks each part of the path and names what is broken. The two usual causes:

- **`ydotoold socket FAILED`** means the input daemon is not running. Start it
  with `systemctl --user start ydotoold`. Pointer commands need it; keyboard
  and screenshots do not, which is why typing can work while clicking does not.
- **`hyprctl responds FAILED`** means this user has no graphical session, so
  there is no desktop to drive at all.

If a click seems to land in the wrong place, check `omarchy-ui cursor` against
where you asked it to go, and re-read the window geometry. Windows move.

If actions are landing before the UI has caught up, raise the pause after each
one:

```bash
OMARCHY_UI_SETTLE=0.4 omarchy-ui click-window foot
```
