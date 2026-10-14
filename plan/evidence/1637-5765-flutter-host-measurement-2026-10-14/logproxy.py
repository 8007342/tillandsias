"""Minimal logging HTTP/CONNECT proxy for measuring which hosts a build reaches.

usage: python3 -I logproxy.py <port> <logfile> <phasefile>
Each finished connection appends: <phase>\t<method>\t<host:port>\t<bytes_down>\t<bytes_up>
"""
import socket, sys, threading, select

PORT, LOG, PHASE = int(sys.argv[1]), sys.argv[2], sys.argv[3]
lock = threading.Lock()


def phase():
    try:
        with open(PHASE) as f:
            return f.read().strip() or "-"
    except OSError:
        return "-"


def log(method, target, down, up):
    with lock, open(LOG, "a") as f:
        f.write(f"{phase()}\t{method}\t{target}\t{down}\t{up}\n")


def pump(a, b):
    down = up = 0
    socks = [a, b]
    while True:
        r, _, x = select.select(socks, [], socks, 300)
        if x or not r:
            break
        for s in r:
            data = s.recv(65536)
            if not data:
                return down, up
            if s is b:
                a.sendall(data); down += len(data)
            else:
                b.sendall(data); up += len(data)
    return down, up


def handle(c):
    method, target = "?", "?"
    try:
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = c.recv(4096)
            if not chunk:
                return
            buf += chunk
        head, rest = buf.split(b"\r\n\r\n", 1)
        lines = head.decode("latin-1").split("\r\n")
        method, target, ver = lines[0].split(" ", 2)
        if method == "CONNECT":
            host, port = target.rsplit(":", 1)
            u = socket.create_connection((host, int(port)), timeout=30)
            c.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            if rest:
                u.sendall(rest)
            try:
                d, up = pump(c, u)
            except OSError as e:
                log("CONNECT-RESET", target, 0, 0)
                return
            log("CONNECT", target, d, up)
        else:
            # absolute-form http://host[:port]/path
            hp = target.split("://", 1)[1].split("/", 1)
            hostport, path = hp[0], "/" + (hp[1] if len(hp) > 1 else "")
            host, port = (hostport.rsplit(":", 1) + ["80"])[:2] if ":" in hostport else (hostport, "80")
            u = socket.create_connection((host, int(port)), timeout=30)
            hdrs = [l for l in lines[1:] if not l.lower().startswith(("proxy-connection", "connection"))]
            req = f"{method} {path} {ver}\r\n" + "\r\n".join(hdrs) + "\r\nConnection: close\r\n\r\n"
            u.sendall(req.encode("latin-1") + rest)
            d, up = pump(c, u)
            log(method, f"{host}:{port}{path[:80]}", d, up)
    except Exception as e:  # recorded, never fatal
        log("ERROR " + repr(e)[:100], target, 0, 0)
    finally:
        c.close()


srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", PORT))
srv.listen(64)
print(f"listening {PORT}", flush=True)
while True:
    conn, _ = srv.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
