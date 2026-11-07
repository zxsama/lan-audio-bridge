#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read-only DAC stall detector for the NAS host.

Samples the ALSA hardware pointer (and the interrupt count of the card's USB
controller) every ~10 ms. A stall is an interval in which the device played
noticeably less than the elapsed time. With --processes it also logs newly
started processes, which identified a crash-looping container as the trigger.

Usage on the host:  python3 dac_stall.py --seconds 200 [--card 0] [--processes]
Remote:            ssh nas 'python3 - --seconds 200' < dac_stall.py
"""
import argparse
import datetime
import os
import time

parser = argparse.ArgumentParser()
parser.add_argument("--seconds", type=float, default=200)
parser.add_argument("--card", type=int, default=0)
parser.add_argument("--threshold-ms", type=float, default=10, help="missing playback per interval that counts as a stall")
parser.add_argument("--processes", action="store_true", help="also print processes started within 8 s before each stall")
args = parser.parse_args()
status_path = "/proc/asound/card%d/pcm0p/sub0/status" % args.card


def controller_irqs():
    device = os.path.realpath("/sys/class/sound/card%d/device" % args.card)
    while device != "/" and not os.path.isdir(os.path.join(device, "msi_irqs")):
        device = os.path.dirname(device)
    return set(os.listdir(os.path.join(device, "msi_irqs"))) if device != "/" else set()


irqs = controller_irqs()


def irq_count():
    total = 0
    for line in open("/proc/interrupts"):
        fields = line.split()
        if fields and fields[0].rstrip(":") in irqs:
            total += sum(int(x) for x in fields[1:] if x.isdigit())
    return total


def hw_ptr():
    state, pointer = None, None
    for line in open(status_path):
        if line.startswith("state:"):
            state = line.split()[1]
        elif line.startswith("hw_ptr"):
            pointer = int(line.split()[-1])
    return state, pointer


def pids():
    return {int(p) for p in os.listdir("/proc") if p.isdigit()}


def command(pid):
    try:
        raw = open("/proc/%d/cmdline" % pid, "rb").read().replace(b"\0", b" ").strip()
        return raw.decode(errors="replace")[:160] or open("/proc/%d/comm" % pid).read().strip()
    except OSError:
        return "?"


def stamp(t):
    return datetime.datetime.fromtimestamp(t).strftime("%H:%M:%S.%f")[:-3]


print("card %d, controller irqs %s" % (args.card, ",".join(sorted(irqs)) or "unknown"), flush=True)
end = time.monotonic() + args.seconds
recent, seen = [], pids()
last_t, (state, last_h), last_q = time.time(), hw_ptr(), irq_count()
first_t, first_h, stalls = last_t, last_h, []
while time.monotonic() < end:
    time.sleep(0.01)
    t = time.time()
    if args.processes:
        now = pids()
        recent += [(t, pid, command(pid)) for pid in sorted(now - seen)]
        recent = [r for r in recent if t - r[0] < 8]
        seen = now
    state, h = hw_ptr()
    q = irq_count()
    if state == "RUNNING" and h is not None and last_h is not None:
        missing_ms = ((t - last_t) * 48000 - (h - last_h)) / 48
        if missing_ms > args.threshold_ms:
            stalls.append(t)
            print("STALL %s interval %.0f ms, missing %.1f ms, controller irqs %d" % (stamp(t), (t - last_t) * 1000, missing_ms, q - last_q), flush=True)
            if args.processes and (len(stalls) < 2 or t - stalls[-2] > 2):
                for when, pid, cmd in recent:
                    if not cmd.startswith(("pactl", "sleep")):
                        print("    %+.2f s  %d %s" % (when - t, pid, cmd), flush=True)
    last_t, last_h, last_q = t, h, q
if last_h is not None and first_h is not None and last_t > first_t:
    print("hw rate %.1f frames/s over %.0f s" % ((last_h - first_h) / (last_t - first_t), last_t - first_t))
groups = [s for i, s in enumerate(stalls) if i == 0 or s - stalls[i - 1] > 2]
print("stall events: %d%s" % (len(groups), (", intervals s: %s" % [round(b - a, 1) for a, b in zip(groups, groups[1:])]) if len(groups) > 1 else ""))
