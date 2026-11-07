#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read-only freeze check: one busy timing loop pinned to each listed CPU.

Gaps seen on one CPU only point at work on that core (interrupt/softirq load);
simultaneous gaps on every CPU point at a machine-wide freeze (e.g. SMI).
Uses one core per listed CPU for the duration.

Usage: python3 cpu_freeze.py --seconds 130 --cpus 0,7,15,31
"""
import argparse
import datetime
import multiprocessing
import os
import time


def loop(cpu, seconds, queue):
    os.sched_setaffinity(0, {cpu})
    end = time.monotonic() + seconds
    last = time.monotonic()
    while last < end:
        now = time.monotonic()
        if now - last > 0.005:
            queue.put((cpu, time.time() - (now - last), (now - last) * 1000))
        last = now
    queue.put(None)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=float, default=130)
    parser.add_argument("--cpus", default="0,1")
    args = parser.parse_args()
    cpus = [int(c) for c in args.cpus.split(",")]
    queue = multiprocessing.Queue()
    workers = [multiprocessing.Process(target=loop, args=(c, args.seconds, queue)) for c in cpus]
    for w in workers:
        w.start()
    done, gaps = 0, []
    while done < len(workers):
        item = queue.get()
        if item is None:
            done += 1
        else:
            gaps.append(item)
    for w in workers:
        w.join()
    print("gaps > 5 ms per CPU:", {c: sum(1 for g in gaps if g[0] == c) for c in cpus})
    for cpu, start, ms in sorted(gaps, key=lambda g: g[1]):
        if ms > 15:
            print("  %s cpu %d stalled %.1f ms" % (datetime.datetime.fromtimestamp(start).strftime("%H:%M:%S.%f")[:-3], cpu, ms))
