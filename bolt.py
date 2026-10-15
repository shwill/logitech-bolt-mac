#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["hidapi>=0.14"]
# ///
"""Minimal Logitech Bolt receiver tool for macOS: list, pair, unpair.

Protocol details (HID++ 1.0 Bolt registers) follow Solaar's implementation.
"""

import argparse
import sys
import time

import hid

VID, PID = 0x046D, 0xC548
RECEIVER = 0xFF
SHORT, LONG = 0x10, 0x11
SHORT_LEN, LONG_LEN = 7, 20

SET_SHORT, GET_SHORT, SET_LONG, GET_LONG = 0x80, 0x81, 0x82, 0x83
ERROR = 0x8F

REG_NOTIFICATIONS = 0x00
REG_DISCOVERY = 0xC0
REG_PAIRING = 0xC1  # long
REG_RECEIVER_INFO = 0xB5  # long
INFO_PAIRING = 0x50
INFO_NAME = 0x60
MAX_SLOTS = 6

N_PASSKEY_REQUEST = 0x4D
N_PASSKEY_PRESSED = 0x4E
N_DEVICE_DISCOVERED = 0x4F
N_DISCOVERY_STATUS = 0x53
N_PAIRING_STATUS = 0x54

KINDS = {0: "unknown", 1: "keyboard", 2: "mouse", 3: "numpad", 4: "presenter",
         7: "remote", 8: "trackball", 9: "touchpad", 10: "tablet", 11: "gamepad", 12: "joystick", 13: "headset"}
HIDPP_ERRORS = {1: "invalid sub-id", 2: "invalid address", 3: "invalid value", 4: "connection failed",
                5: "too many devices", 6: "already exists", 7: "busy", 8: "unknown device",
                9: "resource error", 10: "request unavailable", 11: "invalid param value", 12: "wrong pin code"}
PAIRING_ERRORS = {1: "device timeout", 2: "failed"}


class HidppError(Exception):
    pass


class Receiver:
    def __init__(self):
        paths = [d["path"] for d in hid.enumerate(VID, PID) if d["usage_page"] == 0xFF00]
        if not paths:
            sys.exit("No Logi Bolt receiver (046D:C548) found.")
        self.dev = hid.device()
        try:
            self.dev.open_path(paths[0])
        except OSError as e:
            sys.exit(f"Cannot open receiver ({e}). Quit Logi Options+ / logioptionsplus_agent and retry.")
        self.pending = []

    def close(self):
        self.dev.close()

    def write(self, sub_id, address, params=b"", long=False):
        report, size = (LONG, LONG_LEN) if long or len(params) > 3 else (SHORT, SHORT_LEN)
        msg = bytes([report, RECEIVER, sub_id, address]) + bytes(params)
        self.dev.write(msg.ljust(size, b"\0"))

    def read(self, timeout_ms):
        data = self.dev.read(64, timeout_ms)
        return bytes(data) if data else None

    def request(self, sub_id, address, params=b"", long=False, timeout=2.0):
        self.write(sub_id, address, params, long)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            msg = self.read(100)
            if not msg or msg[0] not in (SHORT, LONG):
                continue
            if msg[1] == RECEIVER and msg[2] == ERROR and msg[3] == sub_id and msg[4] == address:
                raise HidppError(HIDPP_ERRORS.get(msg[5], f"error 0x{msg[5]:02x}"))
            if msg[1] == RECEIVER and msg[2] == sub_id and msg[3] == address:
                return msg[4:]
            self.pending.append(msg)
        raise TimeoutError(f"no reply to 0x{sub_id:02x}/0x{address:02x}")

    def read_long(self, address, *params):
        return self.request(GET_LONG, address, bytes(params))

    def notifications(self, timeout_ms=200):
        while self.pending:
            yield self.pending.pop(0)
        msg = self.read(timeout_ms)
        if msg and msg[0] in (SHORT, LONG):
            yield msg

    def devices(self):
        found = []
        for slot in range(1, MAX_SLOTS + 1):
            try:
                info = self.read_long(REG_RECEIVER_INFO, INFO_PAIRING + slot)
            except HidppError:
                continue
            name = "?"
            try:
                raw = self.read_long(REG_RECEIVER_INFO, INFO_NAME + slot, 0x01)
                name = raw[3:3 + raw[2]].decode("utf-8", "replace")
            except HidppError:
                pass
            found.append({
                "slot": slot,
                "name": name,
                "kind": KINDS.get(info[1] & 0x0F, f"0x{info[1] & 0x0F:x}"),
                "wpid": (info[3:4] + info[2:3]).hex().upper(),
                "serial": info[4:8].hex().upper(),
            })
        return found

    def enable_notifications(self):
        self.request(SET_SHORT, REG_NOTIFICATIONS, bytes([0x00, 0x09, 0x00]))

    def discover(self, timeout_s=30, cancel=False):
        self.request(SET_SHORT, REG_DISCOVERY, bytes([timeout_s, 0x02 if cancel else 0x01]))

    def pair(self, address, authentication, entropy):
        self.request(SET_LONG, REG_PAIRING, bytes([0x01, 0x00]) + address + bytes([authentication, entropy]), long=True)

    def unpair(self, slot):
        self.request(SET_LONG, REG_PAIRING, bytes([0x03, slot]) + bytes(6), long=True)


def print_devices(rx):
    devs = rx.devices()
    if not devs:
        print("No paired devices.")
    for d in devs:
        print(f"  slot {d['slot']}: {d['name']} ({d['kind']}, wpid {d['wpid']}, serial {d['serial']})")


def show_passkey(passkey, authentication):
    print()
    if authentication & 0x01:
        print(f"  Type on the keyboard:  {passkey}  then press Enter")
    else:
        clicks = ", ".join("RIGHT" if b == "1" else "left" for b in f"{int(passkey):010b}")
        print(f"  Click on the mouse:  {clicks}")
        print("  then press left and right buttons together")
    print()


def cmd_pair(rx, timeout_s):
    rx.enable_notifications()
    print("Put the device in pairing mode (hold an Easy-Switch / Connect button ~3s until it blinks fast).")
    rx.discover(timeout_s)
    print(f"Searching for {timeout_s}s ... (Ctrl-C to cancel)")

    found = {}
    counter = None
    pairing_started = False
    deadline = time.monotonic() + timeout_s + 60
    try:
        while time.monotonic() < deadline:
            for n in rx.notifications():
                if n[1] != RECEIVER:
                    continue
                sub, addr, data = n[2], n[3], n[4:]

                if sub == N_DEVICE_DISCOVERED and not pairing_started:
                    c = addr + data[0] * 256
                    if counter is None:
                        counter = c
                    elif c != counter:
                        continue
                    if data[1] == 0:
                        found.update(kind=data[3], address=bytes(data[6:12]), auth=data[14])
                    elif data[1] == 1:
                        found["name"] = bytes(data[3:3 + data[2]]).decode("utf-8", "replace")
                    if {"kind", "address", "auth", "name"} <= found.keys():
                        kind = KINDS.get(found["kind"] & 0x0F, "device")
                        print(f"Found {found['name']} ({kind}), pairing ...")
                        pairing_started = True
                        rx.pair(found["address"], found["auth"], 20 if found["kind"] & 0x0F == 1 else 10)

                elif sub == N_DISCOVERY_STATUS and addr != 0x00 and not pairing_started:
                    print("Discovery ended without finding a device in pairing mode.")
                    return 1

                elif sub == N_PASSKEY_REQUEST:
                    show_passkey(bytes(data[0:6]).decode("ascii"), found.get("auth", 0))

                elif sub == N_PASSKEY_PRESSED:
                    print(".", end="", flush=True)

                elif sub == N_PAIRING_STATUS and addr != 0x00:
                    err = data[0]
                    if err or addr != 0x02:
                        print(f"\nPairing failed: {PAIRING_ERRORS.get(err, f'status 0x{addr:02x}/0x{err:02x}')}")
                        return 1
                    print("\nPaired successfully.")
                    time.sleep(1)
                    print_devices(rx)
                    return 0
        print("Timed out.")
        return 1
    except KeyboardInterrupt:
        print("\nCancelling ...")
        try:
            rx.discover(timeout_s, cancel=True)
        except (HidppError, TimeoutError):
            pass
        return 130


def main():
    p = argparse.ArgumentParser(description="Pair/unpair devices with a Logitech Bolt receiver.")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list", help="list paired devices")
    pp = sub.add_parser("pair", help="pair a new device")
    pp.add_argument("--timeout", type=int, default=30, help="discovery timeout in seconds (max 255)")
    up = sub.add_parser("unpair", help="unpair the device in a slot")
    up.add_argument("slot", type=int, choices=range(1, MAX_SLOTS + 1))
    args = p.parse_args()

    rx = Receiver()
    try:
        if args.cmd == "list":
            print_devices(rx)
        elif args.cmd == "pair":
            return cmd_pair(rx, min(args.timeout, 255))
        elif args.cmd == "unpair":
            rx.unpair(args.slot)
            print(f"Unpaired slot {args.slot}.")
            print_devices(rx)
    except (HidppError, TimeoutError) as e:
        sys.exit(f"Receiver error: {e}")
    finally:
        rx.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
