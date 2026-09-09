#!/usr/bin/env python3
"""omavm agent egress proxy.

Two listeners, both bound only to the sandbox bridge address so nothing on the
LAN can reach them:

  * A forward proxy (CONNECT and absolute-URI HTTP) that permits only
    hostnames present in the allowlist. TLS is never decrypted, so there is no
    certificate authority to generate, install in the guest or rotate.

  * A credential-injecting reverse proxy. The guest points its LLM client at
    http://<host>:<gateway-port>/<route> over plain HTTP and never holds the
    API key. The key is added on the host side and the request is forwarded
    upstream over real TLS.

Both listeners refuse any destination that resolves to a non-global address.
Without that check the proxy is a hole straight into the host's own LAN, which
would defeat the point of the isolated network. The resolved address is what
gets connected to, so a name cannot resolve to a public address for the check
and a private one for the connection.

Standard library only. Reload configuration with SIGHUP.
"""

from __future__ import annotations

import argparse
import http.client
import ipaddress
import logging
import os
import selectors
import signal
import socket
import socketserver
import ssl
import sys
import threading
from http.server import BaseHTTPRequestHandler
from urllib.parse import urlsplit

LOG = logging.getLogger("omavm-proxy")

# Headers that describe a single hop and must not be forwarded onward.
HOP_BY_HOP = frozenset({
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade", "proxy-connection",
})

# Headers a guest is never allowed to set on a gateway route. The whole point
# of the gateway is that credentials come from the host, so a client-supplied
# credential header is stripped rather than passed through.
STRIPPED_FROM_CLIENT = frozenset({
    "authorization", "x-api-key", "api-key", "cookie", "proxy-authorization",
})

TUNNEL_IDLE_TIMEOUT = 300.0
UPSTREAM_TIMEOUT = 120.0
BUFFER_SIZE = 65536
MAX_CONNECTIONS = 64

_CONN_SEMAPHORE = threading.BoundedSemaphore(MAX_CONNECTIONS)


# --------------------------------------------------------------------------
# configuration
# --------------------------------------------------------------------------

class Config:
    """Allowlist and gateway routes, reloadable in place on SIGHUP."""

    def __init__(self, allowlist_path: str, routes_path: str) -> None:
        self.allowlist_path = allowlist_path
        self.routes_path = routes_path
        self._lock = threading.Lock()
        self._exact: dict[str, set[int]] = {}
        self._wildcard: list[tuple[str, set[int]]] = []
        self._routes: list[dict] = []

    def load(self) -> list[str]:
        """Parse both files. Returns a list of problems; never raises."""
        problems: list[str] = []
        exact: dict[str, set[int]] = {}
        wildcard: list[tuple[str, set[int]]] = []
        routes: list[dict] = []

        for lineno, line in _config_lines(self.allowlist_path, problems):
            parts = line.split()
            host = parts[0].lower().rstrip(".")
            try:
                ports = {int(p) for p in parts[1].split(",")} if len(parts) > 1 else {443}
            except ValueError:
                problems.append(f"{self.allowlist_path}:{lineno}: bad port list {parts[1]!r}")
                continue
            if host.startswith("*."):
                wildcard.append((host[1:], ports))  # keep the leading dot
            else:
                exact.setdefault(host, set()).update(ports)

        for lineno, line in _config_lines(self.routes_path, problems):
            parts = line.split(None, 3)
            if len(parts) < 4:
                problems.append(
                    f"{self.routes_path}:{lineno}: expected "
                    "'<prefix> <upstream> <header> <value-template>'")
                continue
            prefix, upstream, header, template = parts
            split = urlsplit(upstream)
            if split.scheme != "https" or not split.hostname:
                problems.append(f"{self.routes_path}:{lineno}: upstream must be an https URL")
                continue
            value, missing = _expand(template)
            if missing:
                problems.append(
                    f"{self.routes_path}:{lineno}: route {prefix} disabled, "
                    f"environment variable {missing} is not set")
                continue
            routes.append({
                "prefix": "/" + prefix.strip("/"),
                "host": split.hostname,
                "port": split.port or 443,
                "base_path": split.path.rstrip("/"),
                "header": header,
                "value": value,
            })

        routes.sort(key=lambda r: len(r["prefix"]), reverse=True)
        with self._lock:
            self._exact, self._wildcard, self._routes = exact, wildcard, routes
        return problems

    def permits(self, host: str, port: int) -> bool:
        host = host.lower().rstrip(".")
        with self._lock:
            ports = self._exact.get(host)
            if ports is not None and port in ports:
                return True
            for suffix, wports in self._wildcard:
                if host.endswith(suffix) and port in wports:
                    return True
        return False

    def route_for(self, path: str) -> tuple[dict | None, str]:
        with self._lock:
            routes = list(self._routes)
        for route in routes:
            prefix = route["prefix"]
            if path == prefix or path.startswith(prefix + "/") or path.startswith(prefix + "?"):
                return route, path[len(prefix):] or "/"
        return None, path

    def summary(self) -> str:
        with self._lock:
            return (f"{len(self._exact)} exact hosts, {len(self._wildcard)} wildcard hosts, "
                    f"{len(self._routes)} gateway routes")


def _config_lines(path: str, problems: list[str]):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for lineno, raw in enumerate(handle, 1):
                line = raw.split("#", 1)[0].strip()
                if line:
                    yield lineno, line
    except FileNotFoundError:
        problems.append(f"{path}: not found, treating as empty")
    except OSError as exc:
        problems.append(f"{path}: {exc}")


def _expand(template: str) -> tuple[str, str | None]:
    """Substitute ${VAR} from the environment. Returns (value, missing_var)."""
    out, rest = [], template
    while "${" in rest:
        head, _, tail = rest.partition("${")
        name, _, rest = tail.partition("}")
        value = os.environ.get(name)
        if value is None:
            return "", name
        out.append(head)
        out.append(value)
    out.append(rest)
    return "".join(out), None


# --------------------------------------------------------------------------
# destination vetting
# --------------------------------------------------------------------------

def resolve_global(host: str, port: int) -> tuple[list, str | None]:
    """Resolve host, requiring every answer to be a globally routable address."""
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM,
                                   proto=socket.IPPROTO_TCP)
    except socket.gaierror as exc:
        return [], f"dns-failure:{exc.strerror or exc}"
    if not infos:
        return [], "dns-empty"
    for family, _, _, _, sockaddr in infos:
        try:
            address = ipaddress.ip_address(sockaddr[0])
        except ValueError:
            return [], f"unparseable-address:{sockaddr[0]}"
        if not address.is_global:
            return [], f"non-global-address:{address}"
    return infos, None


def connect_to(infos: list, timeout: float) -> socket.socket:
    last: Exception | None = None
    for family, socktype, proto, _, sockaddr in infos:
        try:
            sock = socket.socket(family, socktype, proto)
            sock.settimeout(timeout)
            sock.connect(sockaddr)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            return sock
        except OSError as exc:
            last = exc
    raise last if last else OSError("no address available")


# --------------------------------------------------------------------------
# shared handler behaviour
# --------------------------------------------------------------------------

class _Base(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "omavm-proxy"
    sys_version = ""

    @property
    def config(self) -> Config:
        return self.server.config  # type: ignore[attr-defined]

    def log_message(self, fmt: str, *args) -> None:  # quieten the default logger
        LOG.debug("%s %s", self.client_address[0], fmt % args)

    def audit(self, verdict: str, **fields) -> None:
        detail = " ".join(f"{k}={v}" for k, v in fields.items() if v is not None)
        LOG.info("%s client=%s %s", verdict, self.client_address[0], detail)

    def refuse(self, status: int, verdict: str, **fields) -> None:
        self.audit(verdict, **fields)
        body = (f"{verdict}\n"
                "Blocked by the omavm sandbox proxy.\n"
                "See OPERATIONS.md, 'An agent is blocked by the proxy'.\n"
                ).encode()
        try:
            self.send_response(status)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
        except OSError:
            pass
        self.close_connection = True

    def read_request_body(self) -> bytes | None:
        length = self.headers.get("Content-Length")
        if length is not None:
            try:
                return self.rfile.read(int(length))
            except (ValueError, OSError):
                return None
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            chunks = []
            while True:
                line = self.rfile.readline(65536).strip()
                if not line:
                    break
                try:
                    size = int(line.split(b";")[0], 16)
                except ValueError:
                    return None
                if size == 0:
                    self.rfile.readline(65536)
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.readline(65536)
            return b"".join(chunks)
        return None

    def relay_response(self, upstream: http.client.HTTPResponse) -> None:
        """Stream a response back without buffering, so SSE stays interactive."""
        length = upstream.getheader("Content-Length")
        self.send_response(upstream.status, upstream.reason)
        for name, value in upstream.getheaders():
            if name.lower() in HOP_BY_HOP or name.lower() == "content-length":
                continue
            self.send_header(name, value)
        if length is not None:
            self.send_header("Content-Length", length)
        else:
            self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        try:
            if length is not None:
                remaining = int(length)
                while remaining > 0:
                    chunk = upstream.read1(min(BUFFER_SIZE, remaining))
                    if not chunk:
                        break
                    remaining -= len(chunk)
                    self.wfile.write(chunk)
                    self.wfile.flush()
            else:
                while True:
                    chunk = upstream.read1(BUFFER_SIZE)
                    if not chunk:
                        break
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                    self.wfile.flush()
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
        except (OSError, http.client.HTTPException):
            self.close_connection = True


# --------------------------------------------------------------------------
# forward proxy
# --------------------------------------------------------------------------

class ForwardProxyHandler(_Base):
    def do_CONNECT(self) -> None:
        host, _, port_text = self.path.rpartition(":")
        if not host:
            self.refuse(400, "DENY", reason="malformed-connect", target=self.path)
            return
        try:
            port = int(port_text)
        except ValueError:
            self.refuse(400, "DENY", reason="malformed-port", target=self.path)
            return

        if not self.config.permits(host, port):
            self.refuse(403, "DENY", reason="not-in-allowlist", host=host, port=port)
            return

        infos, problem = resolve_global(host, port)
        if problem:
            self.refuse(403, "DENY", reason=problem, host=host, port=port)
            return

        with _CONN_SEMAPHORE:
            try:
                upstream = connect_to(infos, UPSTREAM_TIMEOUT)
            except OSError as exc:
                self.refuse(502, "DENY", reason=f"connect-failed:{exc}", host=host, port=port)
                return
            self.audit("ALLOW", method="CONNECT", host=host, port=port)
            try:
                self.wfile.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                self.wfile.flush()
                self._splice(upstream)
            finally:
                upstream.close()
        self.close_connection = True

    def _splice(self, upstream: socket.socket) -> None:
        client = self.connection
        client.setblocking(False)
        upstream.setblocking(False)
        with selectors.DefaultSelector() as sel:
            sel.register(client, selectors.EVENT_READ, upstream)
            sel.register(upstream, selectors.EVENT_READ, client)
            while True:
                events = sel.select(timeout=TUNNEL_IDLE_TIMEOUT)
                if not events:
                    return
                for key, _ in events:
                    try:
                        data = key.fileobj.recv(BUFFER_SIZE)  # type: ignore[union-attr]
                    except (BlockingIOError, InterruptedError):
                        continue
                    except OSError:
                        return
                    if not data:
                        return
                    try:
                        key.data.sendall(data)
                    except OSError:
                        return

    def _forward_plain(self) -> None:
        split = urlsplit(self.path)
        if split.scheme not in ("http", "https") or not split.hostname:
            self.refuse(400, "DENY", reason="not-a-proxy-request", target=self.path)
            return
        host, port = split.hostname, split.port or (443 if split.scheme == "https" else 80)
        if not self.config.permits(host, port):
            self.refuse(403, "DENY", reason="not-in-allowlist", host=host, port=port)
            return
        infos, problem = resolve_global(host, port)
        if problem:
            self.refuse(403, "DENY", reason=problem, host=host, port=port)
            return

        body = self.read_request_body()
        path = split.path or "/"
        if split.query:
            path = f"{path}?{split.query}"
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}
        headers["Host"] = split.netloc

        with _CONN_SEMAPHORE:
            try:
                sock = connect_to(infos, UPSTREAM_TIMEOUT)
            except OSError as exc:
                self.refuse(502, "DENY", reason=f"connect-failed:{exc}", host=host, port=port)
                return
            try:
                conn = _wrap_connection(sock, host, port, split.scheme == "https")
                self.audit("ALLOW", method=self.command, host=host, port=port, path=split.path)
                conn.request(self.command, path, body=body, headers=headers)
                self.relay_response(conn.getresponse())
            except (OSError, http.client.HTTPException) as exc:
                self.refuse(502, "ERROR", reason=f"upstream:{exc}", host=host, port=port)
            finally:
                sock.close()

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = _forward_plain


# --------------------------------------------------------------------------
# credential-injecting gateway
# --------------------------------------------------------------------------

class GatewayHandler(_Base):
    def _proxy(self) -> None:
        route, remainder = self.config.route_for(urlsplit(self.path).path)
        if route is None:
            self.refuse(404, "DENY", reason="no-matching-route", path=self.path)
            return

        query = urlsplit(self.path).query
        upstream_path = route["base_path"] + remainder
        if query:
            upstream_path = f"{upstream_path}?{query}"

        infos, problem = resolve_global(route["host"], route["port"])
        if problem:
            self.refuse(502, "DENY", reason=problem, host=route["host"])
            return

        body = self.read_request_body()
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in HOP_BY_HOP and k.lower() not in STRIPPED_FROM_CLIENT}
        headers["Host"] = route["host"]
        headers[route["header"]] = route["value"]

        with _CONN_SEMAPHORE:
            try:
                sock = connect_to(infos, UPSTREAM_TIMEOUT)
            except OSError as exc:
                self.refuse(502, "ERROR", reason=f"connect-failed:{exc}", host=route["host"])
                return
            try:
                conn = _wrap_connection(sock, route["host"], route["port"], True)
                self.audit("ALLOW", method=self.command, route=route["prefix"],
                           host=route["host"], path=upstream_path.split("?")[0])
                conn.request(self.command, upstream_path, body=body, headers=headers)
                self.relay_response(conn.getresponse())
            except (OSError, http.client.HTTPException) as exc:
                self.refuse(502, "ERROR", reason=f"upstream:{exc}", host=route["host"])
            finally:
                sock.close()

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = _proxy


def _wrap_connection(sock: socket.socket, host: str, port: int,
                     use_tls: bool) -> http.client.HTTPConnection:
    """Build an http.client connection over an already-vetted socket."""
    if use_tls:
        context = ssl.create_default_context()
        sock = context.wrap_socket(sock, server_hostname=host)
        conn: http.client.HTTPConnection = http.client.HTTPSConnection(
            host, port, timeout=UPSTREAM_TIMEOUT, context=context)
    else:
        conn = http.client.HTTPConnection(host, port, timeout=UPSTREAM_TIMEOUT)
    sock.settimeout(UPSTREAM_TIMEOUT)
    conn.sock = sock
    return conn


class ThreadedServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 32

    def __init__(self, address, handler, config: Config) -> None:
        self.config = config
        super().__init__(address, handler)

    def handle_error(self, request, client_address) -> None:
        exc = sys.exc_info()[1]
        if isinstance(exc, (BrokenPipeError, ConnectionResetError, TimeoutError)):
            return
        LOG.warning("ERROR client=%s unhandled=%r", client_address[0], exc)


# --------------------------------------------------------------------------
# entry point
# --------------------------------------------------------------------------

def configure_logging(log_file: str | None) -> None:
    fmt = logging.Formatter("%(asctime)s %(message)s", datefmt="%Y-%m-%dT%H:%M:%S%z")
    handlers: list[logging.Handler] = [logging.StreamHandler(sys.stdout)]
    if log_file:
        try:
            os.makedirs(os.path.dirname(log_file), exist_ok=True)
            handlers.append(logging.FileHandler(log_file))
        except OSError as exc:
            print(f"warning: cannot write {log_file}: {exc}", file=sys.stderr)
    for handler in handlers:
        handler.setFormatter(fmt)
        LOG.addHandler(handler)
    LOG.setLevel(logging.INFO)


def main() -> int:
    parser = argparse.ArgumentParser(description="omavm agent egress proxy")
    parser.add_argument("--bind", default="192.168.100.1")
    parser.add_argument("--proxy-port", type=int, default=8888)
    parser.add_argument("--gateway-port", type=int, default=8889)
    parser.add_argument("--allowlist", default="/etc/omavm/allowlist.conf")
    parser.add_argument("--routes", default="/etc/omavm/routes.conf")
    parser.add_argument("--log-file", default="/var/log/omavm/agent-proxy.log")
    parser.add_argument("--check", action="store_true",
                        help="validate configuration and exit")
    args = parser.parse_args()

    config = Config(args.allowlist, args.routes)
    problems = config.load()

    if args.check:
        for problem in problems:
            print(f"problem: {problem}")
        print(f"loaded: {config.summary()}")
        return 1 if problems else 0

    configure_logging(args.log_file)
    for problem in problems:
        LOG.warning("CONFIG %s", problem)
    LOG.info("START bind=%s proxy_port=%d gateway_port=%d %s",
             args.bind, args.proxy_port, args.gateway_port, config.summary())

    def reload_config(_signum, _frame) -> None:
        for problem in config.load():
            LOG.warning("CONFIG %s", problem)
        LOG.info("RELOAD %s", config.summary())

    signal.signal(signal.SIGHUP, reload_config)

    try:
        forward = ThreadedServer((args.bind, args.proxy_port), ForwardProxyHandler, config)
        gateway = ThreadedServer((args.bind, args.gateway_port), GatewayHandler, config)
    except OSError as exc:
        print(f"fatal: cannot bind on {args.bind}: {exc}", file=sys.stderr)
        print("The sandbox bridge must be up before the proxy starts. "
              "Run: sudo virsh net-start agent-sandbox-net", file=sys.stderr)
        return 1

    threading.Thread(target=gateway.serve_forever, daemon=True).start()
    try:
        forward.serve_forever()
    except KeyboardInterrupt:
        LOG.info("STOP")
    return 0


if __name__ == "__main__":
    sys.exit(main())
