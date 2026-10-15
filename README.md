# Bolt Pair

A tiny native macOS app (and CLI) for pairing and unpairing devices with a **Logitech Bolt** USB receiver — no Logi Options+ or Logi Bolt app required.

Talks HID++ 1.0 directly to the receiver's vendor interface via IOKit. The Bolt register and notification layout follows [Solaar](https://github.com/pwr-Solaar/Solaar)'s implementation.

## Features

- List paired devices (name, type, slot)
- Pair a new device, including the passkey step (digits for keyboards, left/right click sequence for mice)
- Unpair a device from its slot
- Detects the receiver being plugged in / removed

## Requirements

- macOS 14+ (tested on Apple Silicon, macOS 26)
- Logi Bolt receiver (USB `046D:C548`)
- Xcode Command Line Tools (`xcode-select --install`) to build

## App

```sh
./build.sh
open "build/Bolt Pair.app"
```

The bundle is ad-hoc signed. Copy it to `/Applications` if you like.

## CLI

`bolt.py` does the same from the terminal. It needs [uv](https://docs.astral.sh/uv/), which installs the `hidapi` dependency automatically.

```sh
./bolt.py list
./bolt.py pair            # then hold the device's Easy-Switch / Connect button until it blinks fast
./bolt.py unpair 2
```

## Pairing

1. Click **Pair New Device** (or run `./bolt.py pair`).
2. Hold an Easy-Switch channel button (or Connect button) on the device for ~3 s until it blinks fast.
3. Confirm the passkey:
   - **Keyboard:** type the shown digits, then Return.
   - **Mouse:** click the shown left/right sequence, then press both buttons together.

## Notes

- If Logi Options+ is running, it may react to the pairing session too. Quit it while pairing if it gets in the way.
- Unofficial project, not affiliated with Logitech.
