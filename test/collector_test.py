#!/usr/bin/env python3
"""Test keytap-collector by injecting synthetic events via uinput."""
import os
import subprocess
import sys
import time

from evdev import UInput, ecodes

COLLECTOR = sys.argv[1] if len(sys.argv) > 1 else "./keytap-collector"

KEYS = {
    ecodes.EV_KEY: [
        ecodes.KEY_LEFTCTRL, ecodes.KEY_LEFTSHIFT, ecodes.KEY_LEFTMETA,
        ecodes.KEY_S, ecodes.KEY_T, ecodes.KEY_A,
        ecodes.KEY_UP, ecodes.KEY_F5, ecodes.KEY_VOLUMEUP,
    ]
}

proc = subprocess.Popen(
    [COLLECTOR],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env={**os.environ, "KEYTAP_DEVICE_FILTER": "keytap-test-kbd"},
)
time.sleep(0.7)

ui = UInput(name="keytap-test-kbd", events=KEYS, bustype=0x06)
time.sleep(3.5)  # wait for the collector's hotplug rescan to find the device


def tap(*codes, hold=0.04):
    for c in codes:
        ui.write(ecodes.EV_KEY, c, 1)
    ui.syn()
    time.sleep(hold)
    for c in codes:
        ui.write(ecodes.EV_KEY, c, 0)
    ui.syn()
    time.sleep(0.08)


try:
    tap(ecodes.KEY_A)                                    # plain letter
    tap(ecodes.KEY_LEFTCTRL, ecodes.KEY_S)               # Ctrl+S
    tap(ecodes.KEY_LEFTMETA, ecodes.KEY_LEFTSHIFT, ecodes.KEY_T)  # Super+Shift+T
    tap(ecodes.KEY_UP)                                   # arrow glyph
    tap(ecodes.KEY_F5)                                   # function key
    tap(ecodes.KEY_VOLUMEUP)                             # media key
finally:
    time.sleep(0.3)
    proc.terminate()
    out, err = proc.stdout.read(), proc.stderr.read()

lines = [line for line in out.splitlines() if line.strip()]
print("CAPTURED:")
for line in lines:
    print(" ", line)
if err.strip():
    print("STDERR:", err.strip())

checks = {
    "plain letter": '["A"]' in out,
    "ctrl+s": '["Ctrl", "S"]' in out,
    "super+shift+t": '["Super", "Shift", "T"]' in out,
    "arrow": "\u2191" in out,
    "fkey": '"F5"' in out,
    "media": '"Vol+"' in out,
    "release-hides": lines and '"combo": []' in lines[-1],
}
failed = [name for name, ok in checks.items() if not ok]
for name, ok in checks.items():
    print(("PASS" if ok else "FAIL"), name)
sys.exit(1 if failed else 0)
