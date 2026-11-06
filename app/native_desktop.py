"""Pulse routing policy for the optional native desktop receiver.

The receiver owns desktop gain and its start/stop transitions. Phone routes
are staged on discard and registered before they can reach the output.
"""
from __future__ import annotations

from pathlib import Path
import re
import time

from native_control import NativeControlError, request


class NativeDesktopMixin:
    def __init__(self, *args, control_path=None, on_native_failure=None, **kwargs):
        super().__init__(*args, **kwargs)
        self.control_path = Path(control_path or "/run/lan-audio/desktop-control.sock")
        self.on_native_failure = on_native_failure or (lambda: None)
        self.receiver_pid = None
        self.native_input = None
        self.native_ready = False
        self.native_status = {}
        self.native_failed_pid = None
        self.native_start_deadline = 0.0
        self.retiring_native = set()

    @property
    def desktop_active(self):
        return self.native_ready and self.native_status.get("active") is True

    def _required_desktop_sinks(self):
        return set()

    def _native_stream(self, stream):
        properties = stream.get("properties", {})
        return (self.receiver_pid is not None
                and properties.get("application.name") == "lan-audio-bridge-desktop-native"
                and properties.get("application.process.id") == str(self.receiver_pid)
                and type(stream.get("index")) is int
                and 0 <= stream["index"] < 0xffffffff)

    def _retiring_stream(self, stream):
        properties = stream.get("properties", {})
        return (properties.get("application.name") == "lan-audio-bridge-desktop-native"
                and (properties.get("application.process.id"), stream.get("index")) in self.retiring_native)

    def _mute_owned_streams(self, include_current=True):
        streams = self.listing("sink-inputs")
        present = {(s.get("properties", {}).get("application.process.id"), s.get("index")) for s in streams}
        self.retiring_native.intersection_update(present)
        for stream in streams:
            if not ((include_current and self._native_stream(stream)) or self._retiring_stream(stream)):
                continue
            try:
                self.command("set-sink-input-mute", str(stream["index"]), "1")
            except RuntimeError:
                # The optional process can exit between listing and muting.
                # Tolerate only the disappearance of that exact stream.
                current = self.listing("sink-inputs")
                if any(s.get("index") == stream["index"] and
                       s.get("properties", {}).get("application.process.id") ==
                       stream.get("properties", {}).get("application.process.id") for s in current):
                    raise

    def _allowed_output_stream(self, stream):
        if self._retiring_stream(stream):
            return True
        if self._native_stream(stream):
            return self.native_input is None or stream["index"] == self.native_input
        return super()._allowed_output_stream(stream)

    def _native_command(self, command, timeout=2.0):
        value = request(self.control_path, command, timeout)
        if value["pid"] != self.receiver_pid:
            raise NativeControlError("Native desktop control identity changed")
        index = value.get("sink_input")
        if (type(value.get("active")) is not bool
                or type(index) is not int or not 0 <= index < 0xffffffff):
            raise NativeControlError("Native desktop control returned invalid stream state")
        if self.native_input is not None and index != self.native_input:
            raise NativeControlError("Native desktop stream identity changed")
        if command.startswith("PHONE "):
            expected = int(command[6:])
            expected = None if expected == -1 else expected
            if value.get("phone") != expected:
                raise NativeControlError("Native desktop phone route was not registered")
        if command == "HOLD" and value.get("phone_pending") is not True:
            raise NativeControlError("Native desktop takeover reservation was not applied")
        self.native_input = index
        self.native_status = value
        return value

    def _native_failed(self):
        # Keep phone playback alive if the optional receiver stops responding.
        # Mute only its supervised process's exact stream before restarting it.
        self.native_ready = False
        self.native_status = {}
        self.native_failed_pid = self.receiver_pid
        self._mute_owned_streams()
        self.on_native_failure()
        if self.route_module is not None:
            self._gain(self.route_module, False, False)
        else:
            self.command("suspend-sink", "output", "1")

    def refresh_native(self, pid):
        if pid != self.receiver_pid:
            if self.receiver_pid is not None:
                if self.native_input is not None:
                    self.retiring_native.add((str(self.receiver_pid), self.native_input))
                for stream in self.listing("sink-inputs"):
                    if self._native_stream(stream):
                        self.retiring_native.add((str(self.receiver_pid), stream["index"]))
                self._mute_owned_streams()
            self.receiver_pid = pid
            self.native_input = None
            self.native_ready = False
            self.native_status = {}
            self.native_failed_pid = None
            self.native_start_deadline = time.monotonic() + 3.0
            if self.route_module is not None:
                self._gain(self.route_module, False, False)
            elif pid is None:
                self.command("suspend-sink", "output", "1")
        # Pulse may remove a dead client's stream after waitpid reports exit.
        # Retain only those exact identities while that removal completes.
        if self.retiring_native:
            self._mute_owned_streams(include_current=False)
        if pid is None or pid == self.native_failed_pid:
            return
        try:
            self._native_command("STATUS", timeout=0.2)
            if not self.native_ready:
                self._native_command("GAIN " + str(self.desktop_volume / 100))
                phone = self._input(self.route_module) if self.route_module is not None else -1
                self._native_command("PHONE " + str(phone))
                self.native_ready = True
        except NativeControlError:
            if self.native_ready or time.monotonic() >= self.native_start_deadline:
                self._native_failed()

    def clear(self):
        held = False
        if self.native_ready and self.defer_gain_refresh:
            try:
                self._native_command("HOLD")
                held = True
            except NativeControlError:
                self._native_failed()
        if self.route_module is not None:
            self.command("unload-module", str(self.route_module))
            self.route_module = None
        if held:
            return
        if self.native_ready:
            try:
                self._native_command("PHONE -1")
                return
            except NativeControlError:
                self._native_failed()
        if not self.desktop_active:
            self.command("suspend-sink", "output", "1")

    def route(self, source):
        # Delegate source/transition validation to the same caller contract as
        # Pulse.route; public source names are checked before building commands.
        if source not in ("airplay", "dlna", "spotify", "miplay") or self.route_module is not None:
            raise RuntimeError("Invalid native phone routing transition")
        module = self.command("load-module", "module-loopback", f"source={source}_bus.monitor",
                              "sink=discard", f"latency_msec={self.latency_ms}",
                              "source_dont_move=true", "sink_dont_move=false", "channels=2", "remix=no")
        if not re.fullmatch(r"[0-9]+", module):
            raise RuntimeError("PulseAudio did not return a routing module identifier")
        self.route_module = int(module)
        index = self._input(self.route_module)
        if self.native_ready:
            try:
                self._native_command("PHONE " + str(index))
            except NativeControlError:
                self._native_failed()
        if not self.native_ready:
            self._gain(self.route_module, False, False)
        self.command("suspend-sink", "output", "0")
        self.command("move-sink-input", str(index), "output")
        self.command("set-sink-mute", "output", "0")

    def clear_all(self):
        # Shutdown owns both lanes; ordinary phone transitions never use this.
        self._mute_owned_streams()
        self.command("set-sink-mute", "output", "1")
        if self.route_module is not None:
            self.command("unload-module", str(self.route_module))
            self.route_module = None
        self.command("suspend-sink", "output", "1")
