"""Local control channel for the optional native desktop receiver."""
from __future__ import annotations

import json
import errno
import os
from pathlib import Path
import socket
import uuid


class NativeControlError(RuntimeError):
    pass


def remove_stale_socket(path: Path) -> None:
    """Clean up after a dead supervised receiver, without stealing a live socket."""
    import stat
    try:
        before = path.lstat()
    except FileNotFoundError:
        return
    if not stat.S_ISSOCK(before.st_mode):
        raise OSError(errno.EEXIST, "Desktop control path is not a socket")
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as probe:
        try:
            probe.connect(str(path))
        except OSError as exc:
            if exc.errno == errno.ENOENT:
                return
            if exc.errno != errno.ECONNREFUSED:
                raise
        else:
            raise OSError(errno.EADDRINUSE, "Desktop control socket is still active")
    try:
        after = path.lstat()
    except FileNotFoundError:
        return
    if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
        raise OSError(errno.EAGAIN, "Desktop control socket changed during cleanup")
    path.unlink(missing_ok=True)


def request(path: Path, command: str, timeout: float = 2.0) -> dict:
    """Use one private reply socket per transaction; never accept unrelated peers."""
    local = path.parent / (".desktop-control-" + uuid.uuid4().hex[:16])
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as channel:
            channel.settimeout(timeout)
            channel.bind(str(local))
            os.chmod(local, 0o600)
            channel.connect(str(path))
            channel.send(command.encode("ascii"))
            result = json.loads(channel.recv(16384))
        if not isinstance(result, dict) or result.get("ok") is not True:
            raise NativeControlError("Native desktop control rejected the operation")
        if type(result.get("pid")) is not int or result["pid"] <= 0:
            raise NativeControlError("Native desktop control returned an invalid identity")
        return result
    except (OSError, ValueError, UnicodeError):
        raise NativeControlError("Native desktop control is unavailable") from None
    finally:
        local.unlink(missing_ok=True)
