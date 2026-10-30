#!/usr/bin/env python3
"""Accountless discovery/handshake checks from an independent Docker network peer.

Start compose.test.yaml, then run this file with a Docker-enabled Python host.
No published ports, sound devices, credentials, or third-party Python packages.
This proves container-network discovery, not phone/LAN discovery or playback.
"""
import argparse
import base64
import ipaddress
import json
from pathlib import Path
import plistlib
import socket
import struct
import subprocess
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

NETWORK = "lan-audio-bridge-test_default"
SERVICES = ("_airplay._tcp.local", "_raop._tcp.local", "_spotify-connect._tcp.local", "_mi-connect._udp.local")
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def dns_name(packet, offset):
    labels, seen, end = [], set(), None
    while True:
        if offset in seen or offset >= len(packet):
            raise ValueError("Invalid DNS name")
        seen.add(offset)
        length = packet[offset]
        if length & 0xc0 == 0xc0:
            if offset + 1 >= len(packet):
                raise ValueError("Short DNS pointer")
            if end is None:
                end = offset + 2
            offset = ((length & 0x3f) << 8) | packet[offset + 1]
            continue
        if length & 0xc0 or offset + 1 + length > len(packet):
            raise ValueError("Invalid DNS label")
        offset += 1
        if not length:
            return ".".join(labels).lower(), end or offset
        labels.append(packet[offset:offset + length].decode("utf-8"))
        offset += length


def dns_records(packet):
    if len(packet) < 12:
        raise ValueError("Short DNS packet")
    _, flags, questions, answers, authority, additional = struct.unpack_from("!6H", packet)
    if not flags & 0x8000:
        return []
    offset, records = 12, []
    for _ in range(questions):
        _, offset = dns_name(packet, offset)
        offset += 4
    for _ in range(answers + authority + additional):
        name, offset = dns_name(packet, offset)
        kind, cls, ttl, size = struct.unpack_from("!HHIH", packet, offset)
        offset += 10
        end = offset + size
        if end > len(packet):
            raise ValueError("Short DNS record")
        value = None
        if kind == 12:
            value, _ = dns_name(packet, offset)
        elif kind == 33 and size >= 7:
            _, _, port = struct.unpack_from("!HHH", packet, offset)
            target, _ = dns_name(packet, offset + 6)
            value = (port, target)
        elif kind == 16:
            value = {}
            while offset < end:
                length = packet[offset]
                offset += 1
                if offset + length > end:
                    raise ValueError("Short DNS TXT")
                item = packet[offset:offset + length].decode("utf-8")
                key, _, val = item.partition("=")
                value[key.lower()] = val
                offset += length
        elif kind == 1 and size == 4:
            value = socket.inet_ntoa(packet[offset:end])
        if ttl and cls & 0x7fff == 1 and value is not None:
            records.append((name, kind, value))
        offset = end
    return records


def query_name(name):
    return b"".join(bytes([len(label)]) + label.encode() for label in name.split(".")) + b"\0"


def discover_mdns(target_ip):
    found, result = {}, {}
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("", 5353))
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                        socket.inet_aton("224.0.0.251") + socket.inet_aton("0.0.0.0"))
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
        sock.settimeout(0.3)
        deadline, next_query = time.monotonic() + 20, 0
        while time.monotonic() < deadline:
            if time.monotonic() >= next_query:
                questions = [(name, 12) for name in SERVICES]
                for name in SERVICES:
                    for instance in found.get((name, 12), []):
                        questions.extend(((instance, 33), (instance, 16)))
                        for _, hostname in found.get((instance, 33), []):
                            questions.append((hostname, 1))
                payload = struct.pack("!6H", 0, 0, len(questions), 0, 0, 0)
                payload += b"".join(query_name(name) + struct.pack("!HH", kind, 1)
                                    for name, kind in questions)
                sock.sendto(payload, ("224.0.0.251", 5353))
                next_query = time.monotonic() + 1
            try:
                packet, sender = sock.recvfrom(65535)
            except socket.timeout:
                continue
            if sender[0] != target_ip or sender[1] != 5353:
                continue
            for name, kind, value in dns_records(packet):
                values = found.setdefault((name, kind), [])
                if value not in values:
                    values.append(value)
            result = {}
            for service in SERVICES:
                for instance in found.get((service, 12), []):
                    for port, hostname in found.get((instance, 33), []):
                        txt = found.get((instance, 16), [])
                        addresses = found.get((hostname, 1), [])
                        if port and txt and target_ip in addresses:
                            result[service] = (port, txt[-1])
            if len(result) == len(SERVICES):
    print("PASS: multicast mDNS PTR/SRV/TXT/A for AirPlay, RAOP, Spotify, MiPlay", flush=True)
                return result
    missing = [service for service in SERVICES if service not in result]
    raise AssertionError("Incomplete mDNS records: " + ", ".join(missing))


def get_url(url):
    with OPENER.open(url, timeout=5) as response:
        assert response.status == 200, "HTTP endpoint did not return 200"
        body = response.read(1024 * 1024 + 1)
    assert len(body) <= 1024 * 1024, "Oversized HTTP response"
    return body


def test_ssdp(target_ip, device_name):
    location = None
    request = ("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n"
               'MAN: "ssdp:discover"\r\nMX: 1\r\n'
               "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n").encode()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("", 0))
        sock.settimeout(0.3)
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
        deadline, next_query = time.monotonic() + 12, 0
        while time.monotonic() < deadline and location is None:
            if time.monotonic() >= next_query:
                sock.sendto(request, ("239.255.255.250", 1900))
                next_query = time.monotonic() + 2
            try:
                packet, sender = sock.recvfrom(65535)
            except socket.timeout:
                continue
            if sender[0] != target_ip:
                continue
            lines = packet.decode("utf-8").split("\r\n")
            assert lines[0] == "HTTP/1.1 200 OK", "Unexpected SSDP status"
            headers = dict((key.lower(), value.strip()) for line in lines[1:]
                           if ":" in line for key, value in [line.split(":", 1)])
            assert headers.get("st") == "urn:schemas-upnp-org:device:MediaRenderer:1", "SSDP ST mismatch"
            assert headers.get("usn") and headers.get("cache-control"), "SSDP headers missing"
            location = headers.get("location")
    assert location, "No SSDP M-SEARCH response from test receiver"
    url = urllib.parse.urlsplit(location)
    assert url.scheme == "http" and url.hostname == target_ip, "SSDP location points outside test receiver"
    assert not url.username and not url.password, "Unexpected URL credentials"
    root = ET.fromstring(get_url(location))
    assert root.findtext(".//{*}deviceType") == "urn:schemas-upnp-org:device:MediaRenderer:1", "Device type mismatch"
    assert root.findtext(".//{*}friendlyName") == device_name, "DLNA device name mismatch"
    kinds = {node.findtext("{*}serviceType") for node in root.findall(".//{*}service")}
    for kind in ("AVTransport", "RenderingControl", "ConnectionManager"):
        assert "urn:schemas-upnp-org:service:" + kind + ":1" in kinds, "Missing DLNA service: " + kind
    print("PASS: multicast SSDP M-SEARCH response and advertised DLNA description", flush=True)


def airplay_request(ip, port, request):
    with socket.create_connection((ip, port), timeout=5) as sock:
        sock.sendall(request.encode())
        stream = sock.makefile("rb")
        status = stream.readline(4096).decode().strip()
        headers = {}
        for _ in range(100):
            line = stream.readline(8192)
            if line == b"\r\n":
                break
            assert line, "Incomplete AirPlay response"
            key, value = line.decode().split(":", 1)
            headers[key.lower()] = value.strip()
        else:
            raise AssertionError("Too many AirPlay headers")
        size = int(headers.get("content-length", 0))
        assert 0 <= size <= 1024 * 1024, "Oversized AirPlay response"
        body = stream.read(size)
        assert len(body) == size, "Incomplete AirPlay body"
        return status, headers, body


def test_airplay(ip, records):
    port, txt = records[SERVICES[0]]
    raop_port, raop_txt = records[SERVICES[1]]
    assert port == raop_port, "AirPlay/RAOP advertised ports differ"
    assert "features" in txt and "ft" in raop_txt, "AirPlay capability TXT missing"
    status, headers, _ = airplay_request(ip, port, "OPTIONS * RTSP/1.0\r\nCSeq: 1\r\n\r\n")
    assert status == "RTSP/1.0 200 OK", "RTSP OPTIONS failed"
    assert headers.get("cseq") == "1", "RTSP CSeq mismatch"
    assert "SETUP" in headers.get("public", ""), "RTSP SETUP capability missing"
    status, _, body = airplay_request(ip, port, "GET /info RTSP/1.0\r\nCSeq: 2\r\n\r\n")
    assert status == "RTSP/1.0 200 OK", "AirPlay info handshake failed"
    info = plistlib.loads(body)
    assert isinstance(info, dict) and "features" in info, "AirPlay info capabilities missing"
    print("PASS: advertised AirPlay/RAOP endpoint RTSP OPTIONS + /info plist", flush=True)


def test_spotify(ip, records, device_name):
    port, txt = records[SERVICES[2]]
    path = txt.get("cpath")
    assert path and path.startswith("/") and not path.startswith("//"), "Spotify CPath missing/invalid"
    assert txt.get("version"), "Spotify zeroconf version missing"
    url = f"http://{ip}:{port}{path}?" + urllib.parse.urlencode({"action": "getInfo"})
    info = json.loads(get_url(url))
    # Never log the JSON: it also contains device identifiers and public keys.
    assert info.get("status") == 101 and info.get("statusString") == "OK", "Spotify getInfo failed"
    assert info.get("remoteName") == device_name, "Spotify device name mismatch"
    assert not info.get("activeUser"), "Test receiver unexpectedly has an active account"
    assert info.get("deviceType") and info.get("version"), "Spotify public capabilities missing"
    print("PASS: advertised Spotify zeroconf getInfo; no active account", flush=True)


def test_miplay(ip, records, device_name):
    port, txt = records[SERVICES[3]]
    assert port == 56666, "Unexpected MiConnect discovery service port"
    assert txt.get("name") == device_name and txt.get("apps") == "[5]", "MiPlay identity missing"
    data = base64.b64decode(txt["appsdata"], validate=True)
    assert len(data) > 28 and data[0] == 0x81 and data[2] == len(data) - 3, "Invalid MiPlay app data"
    control_port = struct.unpack_from(">H", data, 5)[0]
    with socket.create_connection((ip, control_port), timeout=5) as sock:
        assert sock.recv(128), "Advertised MiPlay control endpoint did not respond"
    print("PASS: MiPlay mDNS identity/address and advertised TCP control endpoint (no phone compatibility claim)", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", help="Explicit compose.test.yaml audio container ID")
    parser.add_argument("--inside", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--target-ip", help=argparse.SUPPRESS)
    parser.add_argument("--device-name", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.inside:
        ipaddress.IPv4Address(args.target_ip)
        records = discover_mdns(args.target_ip)
        test_ssdp(args.target_ip, args.device_name)
        test_airplay(args.target_ip, records)
        test_spotify(args.target_ip, records, args.device_name)
        test_miplay(args.target_ip, records, args.device_name)
        print("PASS: independent-container discovery and accountless handshakes. Phone/LAN/playback remain separate.", flush=True)
        return

    def command(*arguments):
        return subprocess.check_output(arguments, text=True, timeout=20).strip()

    root = Path(__file__).resolve().parents[1]
    container = args.container or command("docker", "compose", "-f", str(root / "compose.test.yaml"), "ps", "-q", "audio")
    assert container and "\n" not in container, "Start exactly one compose.test.yaml audio container"
    info = json.loads(command("docker", "inspect", container))[0]
    env = dict(item.split("=", 1) for item in info["Config"]["Env"])
    host = info["HostConfig"]
    labels = info["Config"].get("Labels", {})
    assert labels.get("com.docker.compose.project") == "lan-audio-bridge-test", "Expected isolated test project"
    assert env.get("AUDIO_MODE") == "null", "Expected null audio output"
    assert not host.get("Privileged") and not host.get("Devices") and not host.get("PortBindings"), "Unsafe test container settings"
    assert info["State"]["Running"], "Test receiver not running"
    networks = info["NetworkSettings"]["Networks"]
    assert set(networks) == {NETWORK}, "Expected isolated test network only"
    subprocess.run(["docker", "run", "--rm", "-i", "--network", NETWORK, "--cap-drop=ALL",
                    "--security-opt=no-new-privileges:true", "--read-only", "--user=65534:65534",
                    "--entrypoint=python3", info["Image"], "-u", "-", "--inside",
                    "--target-ip", networks[NETWORK]["IPAddress"], "--device-name", env["DEVICE_NAME"]],
                   input=Path(__file__).read_bytes(), check=True, timeout=90)


if __name__ == "__main__":
    main()
