#!/usr/bin/env python3
"""Bounded, low-brightness USB tests. Disable the app's matrix output first."""

import argparse
import fcntl
import os
import select
import struct
import subprocess
import termios
import time
import tty


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port", help="Exact /dev/cu.usbmodem... path for the flashed matrix")
    parser.add_argument("--app", help="Optional TeamsMuteLight binary to verify busy-port handling")
    parser.add_argument("--orientation-test", action="store_true", help="Show an up arrow for 20 s while you rotate the board")
    parser.add_argument("--offset", type=int, choices=range(4), default=0)
    parser.add_argument("--mirror", action="store_true")
    args = parser.parse_args()
    fd = os.open(args.port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    received = bytearray()
    identified = False

    def send(text):
        data = (text + "\n").encode("ascii")
        deadline = time.monotonic() + 1
        while data:
            if time.monotonic() >= deadline:
                raise TimeoutError("Serial write timed out")
            if select.select([], [fd], [], 0.1)[1]:
                try:
                    count = os.write(fd, data)
                except BlockingIOError:
                    continue
                if count == 0:
                    raise OSError("Serial write returned zero bytes")
                data = data[count:]

    def expect(prefix, exact=None, timeout=2):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            while b"\n" in received:
                line, _, rest = received.partition(b"\n")
                received[:] = rest
                text = line.decode("ascii", errors="replace").strip()
                if text.startswith(prefix):
                    if exact is not None and text != exact:
                        raise AssertionError(f"Expected {exact!r}, received {text!r}")
                    return text
            if len(received) > 2048:
                raise AssertionError("Unbounded firmware reply")
            if select.select([fd], [], [], 0.1)[0]:
                try:
                    chunk = os.read(fd, 256)
                except BlockingIOError:
                    continue
                if chunk:
                    received.extend(chunk)
        raise TimeoutError(f"No firmware response starting with {prefix!r}")

    def state(expected):
        send("STATUS")
        expect("STATE ", expected)

    try:
        fcntl.ioctl(fd, termios.TIOCEXCL)
        tty.setraw(fd, termios.TCSANOW)
        attributes = termios.tcgetattr(fd)
        attributes[2] |= termios.CLOCAL | termios.CREAD
        attributes[2] &= ~termios.HUPCL
        attributes[4] = attributes[5] = termios.B115200
        termios.tcsetattr(fd, termios.TCSANOW, attributes)
        termios.tcflush(fd, termios.TCIOFLUSH)
        fcntl.ioctl(fd, termios.TIOCMBIS, struct.pack("I", termios.TIOCM_DTR))
        send("HELLO")
        expect("MATRIX ", "MATRIX 3 8 8 25")
        identified = True
        state("STATE 0 0 0 0")
        print("Verified firmware handshake and dark startup.")
        send("ORIENTATION")
        telemetry = expect("ORIENT ").split()
        if len(telemetry) != 6:
            raise AssertionError(f"Invalid orientation telemetry: {telemetry}")
        turn, x, y, z, upright = map(int, telemetry[1:])
        if turn not in range(4) or upright not in (0, 1) or not 250000 < x*x + y*y + z*z < 2250000:
            raise AssertionError(f"Unexpected accelerometer values: {telemetry}")
        print(f"QMI8658 verified: acceleration ({x}, {y}, {z}) mg, orientation {turn * 90} degrees.")
        if args.app:
            result = subprocess.run(
                [args.app, "--cli", "matrix-probe"],
                capture_output=True, text=True, timeout=3, check=False,
            )
            if result.returncode != 2 or "busy" not in (result.stdout + result.stderr).lower():
                raise AssertionError(f"Expected explicit busy-port failure: {result}")
            print("Verified Swift driver reports a busy port promptly without disturbing this connection.")

        # One white pixel, briefly; over-limit input must still produce channels <= 25.
        send("DRAW 1 255 255 255 255 0 0000001000000000")
        expect("OK ", "OK 1")
        state("STATE 1 25 25 25")
        send("OFF 2")
        expect("OK ", "OK 2")
        state("STATE 0 0 0 0")
        print("Verified firmware clamps over-limit brightness to 25/255 (below 10%) and OFF clears output.")
        send("DRAW 90 255 0 0 1 0 0000001000000000")
        expect("OK ", "OK 90")
        state("STATE 1 3 0 0")
        send("DRAW 91 255 0 0 0 0 0000001000000000")
        expect("OK ", "OK 91")
        state("STATE 0 0 0 0")
        print("Verified nonzero brightness floor and explicit zero/off behavior.")

        # Match the app's relative RGB gain, leaving the master PWM unchanged.
        for sequence, red, master, output in [
            (92, 255, 5, 5), (93, 128, 5, 2), (94, 0, 5, 0), (95, 128, 3, 1),
        ]:
            pixels = f"{red:02X}0000" + "000000" * 63
            send(f"FRAME {sequence} {master} 0 {pixels}")
            expect("OK ", f"OK {sequence}")
            state(f"STATE {int(output > 0)} {output} 0 0")
        send("OFF 96")
        expect("OK ", "OK 96")
        state("STATE 0 0 0 0")
        print("Verified relative RGB dimming at 100%, 50%, 0%, and below the master floor.")

        # App gamma-2.2 maps the artwork's (255, 35, 45) red to (255, 3, 6).
        for sequence, master in enumerate((5, 8, 13, 25), start=97):
            send(f"FRAME {sequence} {master} 0 FF0306" + "000000" * 63)
            expect("OK ", f"OK {sequence}")
            state(f"STATE 1 {master} 0 0")
        send("OFF 101")
        expect("OK ", "OK 101")
        state("STATE 0 0 0 0")
        print("Verified gamma-corrected red stays red at 2%, 3%, 5%, and 10% master output.")

        send("DRAW 3 255 0 0 5 0 0000183C3C180000")
        expect("OK ", "OK 3")
        state("STATE 12 5 0 0")
        started = time.monotonic()
        checked_before_timeout = False
        while time.monotonic() - started < 3.4:
            send("HELLO")
            expect("MATRIX ", "MATRIX 3 8 8 25")
            send("DRAW 4 256 0 0 51 0 0000183C3C180000")
            expect("ERR ", "ERR command")
            if not checked_before_timeout and time.monotonic() - started >= 2.4:
                state("STATE 12 5 0 0")
                checked_before_timeout = True
            time.sleep(0.25)
        state("STATE 0 0 0 0")
        print("Verified 3-second stale-display clearing; HELLO and invalid DRAW do not extend it.")

        send("X" * 449)
        expect("ERR ", "ERR line-too-long")
        for sequence in range(5, 11):
            send(f"DRAW {sequence} 0 255 0 5 0 0000183C3C180000")
            expect("OK ", f"OK {sequence}")
            time.sleep(0.65)
        state("STATE 12 0 5 0")
        send("OFF 11")
        expect("OK ", "OK 11")
        state("STATE 0 0 0 0")
        print("Verified oversized-line recovery and heartbeat beyond the timeout. Display is off.")
        rgb = "FF0000" + "00FF00" + "0000FF" + "000000" * 61
        start = time.monotonic()
        for sequence in range(20, 70):
            send(f"FRAME {sequence} 5 0 {rgb}")
            expect("OK ", f"OK {sequence}")
            time.sleep(max(0, start + (sequence - 19) * 0.04 - time.monotonic()))
        if time.monotonic() - start > 2.5:
            raise AssertionError("RGB transport could not sustain the 25 fps test schedule")
        state("STATE 3 5 5 5")
        send(f"FRAME 70 5 0 {rgb[:-1]}Z")
        expect("ERR ", "ERR command")
        state("STATE 3 5 5 5")
        send("OFF 71")
        expect("OK ", "OK 71")
        state("STATE 0 0 0 0")
        print("Verified independent red/green/blue pixels, 25 fps RGB frame transport, and atomic malformed-frame rejection.")
        unique = "".join(f"{i * 4:02X}{255 - i * 4:02X}{i * 3:02X}" for i in range(64))
        send(f"FRAME 72 5 0 {unique}")
        expect("OK ", "OK 72")
        state("STATE 64 4 5 3")
        send("OFF 73")
        expect("OK ", "OK 73")
        state("STATE 0 0 0 0")
        print("Verified all 64 independently colored pixels at default brightness; display is off.")
        if args.orientation_test:
            print("Rotate the board now. Arrow should point UP, with one dot at LOWER LEFT.", flush=True)
            flags = args.offset + (4 if args.mirror else 0)
            started = time.monotonic()
            sequence = 100
            while time.monotonic() - started < 20:
                send(f"DRAW {sequence} 255 0 0 5 {flags} 183C7E1818181880")
                expect("OK ", f"OK {sequence}")
                send("ORIENTATION")
                print(expect("ORIENT "), flush=True)
                sequence += 1
                time.sleep(0.5)
    finally:
        try:
            if identified:
                send("OFF 4294967295")
                expect("OK ", "OK 4294967295")
        finally:
            os.close(fd)


if __name__ == "__main__":
    main()
