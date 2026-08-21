# Keytap

An on-screen keypress visualizer for [Omarchy](https://omarchy.org/) — a floating,
theme-aware rolling cluster near the bottom of the screen where every chord you
press leaves a keycap bubble:

```
   ┌───────┐ ┌───────┐ ┌──────────────────┐
   │  [A]  │ │  [L]  │ │ [Ctrl] + [S]     │
   └───────┘ └───────┘ └──────────────────┘
```

- **Rolling history** — several recent chords stay visible at once; newest on the right
- **Lingers, then dissolves** — each bubble holds ~3s, then slowly fades out individually
- **Live chords** — while held, a bubble updates in place (Super → Super+Shift → Super+Shift+T)
- **Draggable** — right-click the bar icon (or IPC `drag`), move the cluster anywhere,
  position saves on release
- **Theme-aware** — colors, radius, and fonts follow your Omarchy theme
- **Click-through** — the overlay never intercepts mouse or keyboard input
  (except the cluster itself while in drag mode)
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

- Type — chords appear as keycap bubbles that linger, then slowly dissolve
- Click the keyboard icon in the bar (or IPC below) to toggle the overlay
- Settings persist across restarts in `~/.local/state/batman.keytap/state.json`

### IPC

```bash
omarchy-shell keytap toggle   # on/off
omarchy-shell keytap show     # force on
omarchy-shell keytap hide     # force off
omarchy-shell keytap drag     # toggle drag mode — move the cluster, release to save
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

| Key            | Default        | Meaning                                          |
|----------------|----------------|--------------------------------------------------|
| `enabled`      | `true`         | Visualizer on/off (bar widget toggles this)      |
| `duration`     | `3200`         | ms each bubble lingers before its slow fade      |
| `maxEntries`   | `5`            | Bubbles kept visible at once (oldest drops first)|
| `marginBottom` | `110`          | Default cluster height above the screen bottom   |
| `posX`/`posY`  | unset          | Cluster center; written when you drag it         |

Drag mode auto-exits after ~6s idle. Until the first drag, the cluster sits
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
                              KeytapPanel.qml ──▶ layer-shell overlay bubbles
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
