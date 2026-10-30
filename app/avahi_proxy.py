#!/usr/bin/env python3
"""Dedicated sidecar: expose only the discovery API on a separate D-Bus socket."""
import os
from pathlib import Path
import sys

from runtime import avahi_available

SOURCE = "/run/host-dbus/system_bus_socket"
TARGET = "/proxy/system_bus_socket"


def proxy_command() -> list[str]:
    # No --talk or --own: Server.SetHostName and unrelated host services stay blocked.
    methods = ["Server." + name for name in (
        "GetVersionString", "GetAPIVersion", "GetState", "GetHostName", "GetDomainName",
        "GetHostNameFqdn", "GetLocalServiceCookie", "EntryGroupNew")]
    methods.append("EntryGroup.*")
    return ["xdg-dbus-proxy", "unix:path=" + SOURCE, TARGET, "--filter",
            *("--call=org.freedesktop.Avahi=org.freedesktop.Avahi." + method for method in methods),
            "--call=org.freedesktop.Avahi=org.freedesktop.DBus.Introspectable.Introspect",
            "--call=org.freedesktop.Avahi=org.freedesktop.DBus.Properties.Get",
            "--call=org.freedesktop.Avahi=org.freedesktop.DBus.Properties.GetAll",
            "--call=org.freedesktop.Avahi=org.freedesktop.DBus.Peer.Ping",
            "--broadcast=org.freedesktop.Avahi=org.freedesktop.Avahi.Server.StateChanged",
            "--broadcast=org.freedesktop.Avahi=org.freedesktop.Avahi.EntryGroup.StateChanged"]


def main() -> int:
    if sys.argv[1:] == ["--check"]:
        return 0 if avahi_available("unix:path=" + TARGET) else 1
    if sys.argv[1:]:
        return 2
    if not Path(SOURCE).is_socket():
        print("Host D-Bus socket unavailable; mount the host /run/dbus directory into the proxy sidecar", file=sys.stderr)
        return 1
    os.umask(0o077)
    Path(TARGET).parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    argv = proxy_command()
    os.execvp(argv[0], argv)
    return 1


if __name__ == "__main__":
    sys.exit(main())
