# Relay Remote user guide

Relay Remote lets the Relay Remote iPhone app drive a Relay Runner voice session on your Mac. Speech recognition and speech synthesis stay on the phone; only text crosses the link, inside an SSH connection to the Mac's built-in OpenSSH server. There is no cloud service, account or relay in between. The design is in [the Relay Remote spec](specs/relay-remote.md).

You need a Mac running Relay Runner with a session started, and an iPhone with the Relay Remote app. Replace `<user>` below with your macOS short user name.

## 1. Turn on Remote Login

Relay Remote connects to the SSH server that ships with macOS.

1. Open System Settings, then General, then Sharing.
2. Turn on Remote Login. Allow only your own user if the list offers a choice.
3. Leave "Allow full disk access for remote users" off. Relay Remote does not need it.

Relay Runner shows the state under Settings, Remote, Remote Login. If it says Remote Login is off, use Open Sharing Settings, then Check Again.

## 2. Turn off password sign-in

Switching on Remote Login lets anyone who knows your Mac password try it over SSH. Relay Remote signs in with a key and never needs a password, so close that door. Relay Runner does not edit `/etc`; this one-time step needs an administrator.

```bash
sudo tee /etc/ssh/sshd_config.d/01-relay-remote.conf >/dev/null <<'CONF'
PasswordAuthentication no
KbdInteractiveAuthentication no
CONF
```

Files in `/etc/ssh/sshd_config.d/` are read in name order and the first value for an option wins, so the `01-` prefix keeps this file ahead of the stock `100-macos.conf`. macOS upgrades can reset `/etc/ssh/sshd_config` but keep that directory, so the drop-in survives them. Check the result with `sudo sshd -T | grep -i -E 'passwordauthentication|kbdinteractive'`; both should read `no`. To undo it, delete the file.

Any other SSH login that relied on a password stops working too. Use a key for those.

## 3. Pair a phone

1. In Relay Runner, open Settings, then Remote, then Pair a Device. It shows a one-time code that expires after ten minutes.
2. In the Relay Remote app, scan the code.
3. Relay Runner shows a confirmation naming the device and its key fingerprint. Compare it with what the phone shows, then choose Allow. Choose Deny if you don't recognise the device.

Only after Allow does Relay Runner add the phone's permanent key to `~/.ssh/authorized_keys`, locked to the Relay helper with `restrict`, so a stolen phone key gets one program: no shell, no terminal and no port forwarding. The one-time key is removed. The phone remembers the Mac's host key from pairing and checks it on every connection.

## 4. Unpair a phone

Open Settings, then Remote, then Paired Devices, and choose Unpair next to the device. Relay Runner removes that device's line from `authorized_keys` and leaves every other line alone. The phone can no longer sign in. Delete the Mac from the phone's app as well to discard its key.

## 5. Use it at home

On the home network the app finds the Mac through Bonjour (`_ssh._tcp`, which Remote Login advertises) and connects to port 22. The Mac must be awake with your user logged in.

## 6. Use it away from home with Tailscale

Install Tailscale on the Mac and the phone and sign both in to the same tailnet. Pair while both are on the tailnet, or re-pair after you add it, so the phone connects to the Mac's tailnet name. The Tailscale tunnel must be up on the phone before Relay Remote connects.

Use plain `sshd` over the tailnet, as set up above. Do not use Tailscale SSH: the App Store and GUI Mac builds of Tailscale cannot host it, and Relay Remote does not need it. Tailscale relays only carry encrypted WireGuard traffic.

## 7. Why port forwarding is discouraged

Forwarding port 22 on your router puts your Mac's SSH server on the public internet, where it is scanned and attacked within hours. It only counts as acceptable with password and keyboard-interactive sign-in disabled (step 2), and many home connections sit behind carrier-grade NAT where it cannot work at all. Prefer Tailscale. If you forward anyway, expect to watch the logs, keep macOS updated, and consider a non-standard external port plus a dynamic DNS name.

## 8. Sleep and keep-awake

A sleeping Mac drops every connection and cannot be woken from the phone. While at least one phone is connected, Relay Runner holds a power assertion that stops idle system sleep, and releases it when the last phone disconnects. It does not stop a closed lid or a manual sleep, and the phone will say the connection dropped. For a Mac you want reachable all day, set Energy settings to prevent automatic sleep on power adapter, or run `caffeinate -s` in a Terminal.

While a phone is the active input, Relay Runner mutes the Mac microphone so the two don't compete, and shows Remote: and the device name in its status. It takes the microphone back when the phone disconnects.

## 9. When the host key changes

The phone pins the Mac's SSH host key at pairing and refuses to connect if it ever differs. That protects you from someone impersonating the Mac, so treat the warning seriously. First work out whether the change is expected:

- Expected: you reinstalled macOS, restored from a backup that did not include `/etc/ssh/ssh_host_*`, or deliberately regenerated the host keys.
- Unexpected: nothing on the Mac changed, or you are on an unfamiliar network. Do not continue. Connect from the home network or Tailscale instead and check again.

If the change is expected, check the Mac's current fingerprint with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`, then unpair the phone (step 4), delete the Mac in the app, and pair again (step 3). Pairing pins the new key. There is no accept-and-continue shortcut, by design.

## Troubleshooting

- Pair a Device is greyed out: Remote Login is off or not yet detected. See step 1.
- "Relay Runner is not running": the phone connected but no voice session is active. Start a session in the app.
- The connection works at home but not away: the Tailscale tunnel is down on the phone, or the Mac is asleep.
