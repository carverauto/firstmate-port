#!/usr/bin/env python3
"""Discord interactions endpoint. Verifies Ed25519; PING -> PONG. No secrets logged."""
import json
import os
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from nacl.encoding import HexEncoder
from nacl.exceptions import BadSignatureError
from nacl.signing import VerifyKey

MAX_BODY = 64 * 1024
PUB = os.environ.get("DISCORD_PUBLIC_KEY", "").strip()
NATS_URL = os.environ.get("NATS_URL", "").strip()
NATS_TOKEN = os.environ.get("NATS_TOKEN", "").strip()
NATS_SUBJECT = os.environ.get("NATS_SUBJECT", "local.discord.inbound")
if not PUB:
    print("error: DISCORD_PUBLIC_KEY is not set", file=sys.stderr)
    sys.exit(2)
try:
    VERIFY_KEY = VerifyKey(PUB, encoder=HexEncoder)
except Exception:
    print("error: DISCORD_PUBLIC_KEY is not a hex ed25519 key", file=sys.stderr)
    sys.exit(2)


def _nats_publish(payload: bytes) -> None:
    """Best-effort core NATS PUB. Failures must not delay Discord's PONG."""
    if not NATS_URL:
        return
    hostport = NATS_URL
    if hostport.startswith("nats://"):
        hostport = hostport[len("nats://") :]
    hostport = hostport.split("/")[0]
    if "@" in hostport:
        hostport = hostport.rsplit("@", 1)[-1]
    if ":" in hostport:
        host, port_s = hostport.rsplit(":", 1)
        port = int(port_s)
    else:
        host, port = hostport, 4222
    try:
        sock = socket.create_connection((host, port), timeout=2)
    except OSError as exc:
        print("nats connect: %s" % exc, file=sys.stderr)
        return
    try:
        sock.settimeout(2)
        _ = sock.recv(4096)
        connect = {"verbose": False, "pedantic": False, "tls_required": False}
        if NATS_TOKEN:
            connect["auth_token"] = NATS_TOKEN
        sock.sendall(("CONNECT %s\r\n" % json.dumps(connect)).encode("utf-8"))
        sock.sendall(("PUB %s %d\r\n" % (NATS_SUBJECT, len(payload))).encode("utf-8"))
        sock.sendall(payload + b"\r\n")
        sock.sendall(b"PING\r\n")
        _ = sock.recv(4096)
    except OSError as exc:
        print("nats pub: %s" % exc, file=sys.stderr)
    finally:
        try:
            sock.close()
        except OSError:
            pass


class Handler(BaseHTTPRequestHandler):
    server_version = "firstmate-discord-interactions/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def do_GET(self):
        if self.path.split("?", 1)[0] == "/healthz":
            self._send(200, b"ok", "text/plain")
            return
        self._send(404, b"not found", "text/plain")

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/interactions":
            self._send(404, b"not found", "text/plain")
            return
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            self._send(400, b"bad length", "text/plain")
            return
        if length <= 0 or length > MAX_BODY:
            self._send(413, b"payload too large", "text/plain")
            return
        body = self.rfile.read(length)
        sig = self.headers.get("X-Signature-Ed25519")
        ts = self.headers.get("X-Signature-Timestamp")
        if not sig or not ts:
            self._send(401, b"unauthorized", "text/plain")
            return
        try:
            VERIFY_KEY.verify(ts.encode("utf-8") + body, bytes.fromhex(sig))
        except (BadSignatureError, ValueError):
            self._send(401, b"unauthorized", "text/plain")
            return
        try:
            msg = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._send(400, b"bad json", "text/plain")
            return
        if msg.get("type") == 1:
            self._send(200, b'{"type":1}', "application/json")
            return
        threading.Thread(target=_nats_publish, args=(body,), daemon=True).start()
        self._send(200, b'{"type":5}', "application/json")

    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
