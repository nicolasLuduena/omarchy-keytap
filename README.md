# Keytap

An on-screen keypress visualizer for [Omarchy](https://omarchy.org/) — a floating,
theme-aware pill near the bottom of the screen that pops up your key combos as
styled keycaps:

```
        ┌──────────────────────────────┐
        │  [Ctrl] + [Shift] + [T]      │
        └──────────────────────────────┘
```

- **Live combos** — modifiers update while held; the pill pulses on every new key
- **Lingers, then fades** — combos stay ~3s and dissolve slowly instead of vanishing
- **Draggable** — right-click the bar icon (or IPC `drag`), move the pill anywhere,
  position saves on release
- **Theme-aware** — colors, radius, and fonts follow your Omarchy theme
- **Click-through** — the overlay never intercepts mouse or keyboard input
  (except the pill itself while in drag mode)
- **Global capture** — reads evdev devices directly (you need to be in the
  `input` group; no root daemon)

## Install

```bash
omarchy plugin add https://github.com/nicolasLuduena/omarchy-keytap.git --enable
```

Or from a local checkout:

```bash
omarchy plugin add ~/Documents/nicolasLuduena/keytap --enable --yes
```

Then add the bar toggle widget (right section by default):

```bash
omarchy bar move batman.keytap --section right
```

## Use

- Type — combos appear as a pill and fade out after a moment
- Click the keyboard icon in the bar (or IPC below) to toggle the overlay
- Settings persist across restarts in `~/.local/state/batman.keytap/state.json`

### IPC

```bash
omarchy-shell keytap toggle   # on/off
omarchy-shell keytap show     # force on
omarchy-shell keytap hide     # force off
omarchy-shell keytap drag     # toggle drag mode — move the pill, release to save
omarchy-shell keytap state    # JSON: {enabled, duration, marginBottom, posX, posY, dragMode}
```

Bind it to a key, e.g. in `~/.config/hypr/bindings.lua`:

```lua
o.bind("Super", "K", "Toggle keytap", function() hl.exec("omarchy-shell -q keytap toggle") end)
```

### Summon payload

The panel also honors the standard shell summon contract, which doubles as a
one-shot settings override:

```bash
omarchy-shell shell summon batman.keytap '{"duration": 2500, "marginBottom": 160}'
```

## Configuration

State file `~/.local/state/batman.keytap/state.json`:

| Key            | Default        | Meaning                                        |
|----------------|----------------|------------------------------------------------|
| `enabled`      | `true`         | Visualizer on/off (bar widget toggles this)    |
| `duration`     | `3200`         | ms a combo lingers before the slow fade starts |
| `marginBottom` | `110`          | Default pill height above the screen bottom    |
| `posX`/`posY`  | unset          | Pill center; written when you drag it          |

Drag mode auto-exits after ~6s idle. Until the first drag, the pill sits
bottom-center at `marginBottom`.

Environment (set for the shell process, e.g. via systemd override):

| Variable               | Meaning                                              |
|------------------------|------------------------------------------------------|
| `KEYTAP_DEVICE_FILTER` | Regex — only capture keyboards whose name matches    |
| `KEYTAP_DEBUG`         | Set to `1` to trace raw events to stderr             |

## How it works

```
/dev/input/event* ──▶ keytap-collector (python-evdev) ──▶ JSON lines on stdout
                                                              │
                                        Quickshell Process ◀──┘
                                                │
                              KeytapPanel.qml ──▶ layer-shell overlay pill
```

The collector tracks modifier state across all keyboards, filters autorepeat,
handles hotplug, and emits canonical-order combos (`Ctrl, Super, Alt, AltGr,
Shift`, then keys in press order).

## Privacy

Keytap shows *everything* you type, including passwords. Only run it when it
won't leak anything you care about, or toggle it off from the bar.

## Development

```bash
omarchy plugin validate .                        # manifest check
python3 test/collector_test.py                   # synthetic uinput round-trip
omarchy plugin add . --enable --yes              # reinstall after changes
omarchy plugin update batman.keytap              # pull once pushed to git
```

While iterating, edit the installed copy directly
(`~/.config/omarchy/plugins/batman.keytap/`) — the shell hot-reloads plugin
files on save — then mirror changes back into this repo.
