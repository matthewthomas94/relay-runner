#!/usr/bin/env python3
"""Key daemon — listens for global hotkey and sends commands to TTS worker."""

import os
import socket
import sys

TTS_CONTROL_SOCK = os.environ.get("TTS_CONTROL_SOCK", "/tmp/tts_control.sock")
VOICE_KEY = os.environ.get("VOICE_KEY", "F5")


def send_command(cmd: str):
    """Send a command to the TTS worker via Unix datagram socket."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        sock.sendto(cmd.encode("utf-8"), TTS_CONTROL_SOCK)
    except (ConnectionRefusedError, FileNotFoundError):
        print(f"[key_daemon] TTS worker not running ({TTS_CONTROL_SOCK})", file=sys.stderr)
    finally:
        sock.close()


def run_pynput():
    """Use pynput for global hotkey capture (prototype approach)."""
    try:
        from pynput import keyboard
    except ImportError:
        print("[key_daemon] pynput not installed. Install with: pip install pynput", file=sys.stderr)
        print("[key_daemon] Falling back to stdin mode.", file=sys.stderr)
        run_stdin()
        return

    # Map key name to pynput Key
    key_map = {
        "F1": keyboard.Key.f1, "F2": keyboard.Key.f2, "F3": keyboard.Key.f3,
        "F4": keyboard.Key.f4, "F5": keyboard.Key.f5, "F6": keyboard.Key.f6,
        "F7": keyboard.Key.f7, "F8": keyboard.Key.f8, "F9": keyboard.Key.f9,
        "F10": keyboard.Key.f10, "F11": keyboard.Key.f11, "F12": keyboard.Key.f12,
    }

    target_key = key_map.get(VOICE_KEY.upper())
    if target_key is None:
        print(f"[key_daemon] Unknown key '{VOICE_KEY}', defaulting to F5", file=sys.stderr)
        target_key = keyboard.Key.f5

    print(f"[key_daemon] Press {VOICE_KEY} to play/pause TTS", file=sys.stderr)
    print(f"[key_daemon] Press Shift+{VOICE_KEY} to skip", file=sys.stderr)

    shift_held = False

    def on_press(key):
        nonlocal shift_held
        if key in (keyboard.Key.shift, keyboard.Key.shift_r):
            shift_held = True
        elif key == target_key:
            if shift_held:
                send_command("skip")
            else:
                send_command("toggle")

    def on_release(key):
        nonlocal shift_held
        if key in (keyboard.Key.shift, keyboard.Key.shift_r):
            shift_held = False

    with keyboard.Listener(on_press=on_press, on_release=on_release) as listener:
        listener.join()


def run_stdin():
    """Fallback: read single-char commands from stdin."""
    print("[key_daemon] stdin mode: p=play, s=skip, q=quit", file=sys.stderr)
    try:
        while True:
            ch = sys.stdin.read(1)
            if not ch or ch == "q":
                break
            elif ch == "p":
                send_command("toggle")
            elif ch == "s":
                send_command("skip")
    except KeyboardInterrupt:
        pass


def main():
    mode = os.environ.get("KEY_MODE", "pynput")
    print(f"[key_daemon] Control socket: {TTS_CONTROL_SOCK}", file=sys.stderr)

    if mode == "stdin":
        run_stdin()
    else:
        run_pynput()


if __name__ == "__main__":
    main()
