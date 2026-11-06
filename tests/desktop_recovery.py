#!/usr/bin/env python3
"""Receiver/player failure isolation in the dedicated desktop test container."""
import json
import os
import signal
import time

from desktop_audio import Monitor, VBANTone, audio, receiver_pid, routes
from integration import FREQUENCIES, Tone, eventually, pulse, status


def main():
    assert status().get("desktop", {}).get("enabled"), "Use compose.desktop-test.yaml"
    assert status()["state"] == "idle", "Another source or test is active"
    desktop = VBANTone()
    phone = Tone("dlna")
    monitor = None
    results = []
    try:
        eventually(lambda: routes("dlna", True), "initial mixed routes")
        time.sleep(2.2)
        native = status()["desktop"].get("backend") == "native"
        for kind in (("receiver",) if native else ("receiver", "player")):
            old_pid = receiver_pid()
            phone_route = status()["route_module"]
            phone_pid = status()["children"]["dlna"]["pid"]
            if kind == "receiver":
                target = old_pid
            else:
                inputs = [s for s in pulse("sink-inputs")
                          if s.get("properties", {}).get("application.name") == "LAN Audio Bridge VBAN"]
                assert len(inputs) == 1, inputs
                target = int(inputs[0]["properties"]["application.process.id"])
            monitor = Monitor()
            time.sleep(0.5)
            offset = len(monitor.raw)
            os.kill(target, signal.SIGKILL)
            eventually(lambda: receiver_pid() != old_pid and routes("dlna", True),
                       kind + " restarted with desktop route", timeout=12)
            time.sleep(1)
            assert status()["route_module"] == phone_route
            assert status()["children"]["dlna"]["pid"] == phone_pid
            # During desktop recovery, the continuing phone must remain audible.
            samples = monitor.samples(offset)
            window = 2400
            rms = [(sum(x * x for x in samples[i:i + window]) / window) ** 0.5
                   for i in range(0, len(samples) - window, window)]
            assert rms and min(rms) > 500, rms
            monitor.close()
            monitor = None
            audio({1300: 5000, FREQUENCIES["dlna"]: 5000})
            results.append({"failure": kind, "phone_route_preserved": True,
                            "phone_receiver_preserved": True, "desktop_recovered": True,
                            "continuous_50ms_windows": len(rms), "minimum_rms": round(min(rms), 1)})
    finally:
        if monitor:
            monitor.close()
        desktop.close()
        phone.close()
        eventually(lambda: routes(None, False), "idle after failure tests", timeout=8)
    print(json.dumps({"ok": True, "results": results}))


if __name__ == "__main__":
    main()
