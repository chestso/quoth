#!/usr/bin/env python3
"""Dummy SearXNG server for crush tests.

Captures every GET request and serves a canned JSON search payload so the
`web_search' tool exercises the real HTTP transport without touching a
live SearXNG instance.

Usage:
  searxng-server.py <capture-file>

The server binds 127.0.0.1 on an ephemeral port, writes its base URL as
the first line of CAPTURE-FILE, then serves requests.  Only GET /search
is served; other paths get a 404.  Each request is appended as:

  REQUEST <method> <path>
  <header>: <value>
  ...
  BODY <body>

The server runs until killed; it handles one request per connection.
"""

import json
import signal
import socket
import sys


def main():
    capture = sys.argv[1]

    signal.signal(signal.SIGPIPE, signal.SIG_IGN)

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(5)
    port = server.getsockname()[1]

    with open(capture, "w") as f:
        f.write(f"http://127.0.0.1:{port}\n")
        f.flush()

    payload = json.dumps(
        {
            "results": [
                {
                    "title": "Wire Result",
                    "url": "https://example.org/wire",
                    "content": "A canned wire result.",
                    "engine": "duckduckgo",
                    "score": 0.95,
                }
            ]
        }
    )

    while True:
        conn, _ = server.accept()
        try:
            data = b""
            conn.settimeout(5)
            while b"\r\n\r\n" not in data and b"\n\n" not in data:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
            text = data.decode("utf-8", "replace")
            head = text.split("\r\n\r\n")[0]
            lines = head.split("\r\n")
            request_line = lines[0]
            parts = request_line.split(" ")
            method = parts[0] if parts else "?"
            path = parts[1] if len(parts) > 1 else "?"
            headers = {}
            for line in lines[1:]:
                if ":" in line:
                    k, v = line.split(":", 1)
                    headers[k.strip().lower()] = v.strip()

            with open(capture, "a") as f:
                f.write(f"REQUEST {method} {path}\n")
                for k, v in headers.items():
                    f.write(f"{k}: {v}\n")
                f.write("BODY \n")
                f.flush()

            if not path.startswith("/search"):
                conn.sendall(
                    (
                        "HTTP/1.1 404 Not Found\r\n"
                        "Content-Type: application/json\r\n"
                        "Connection: close\r\n\r\n"
                        '{"error":"not_found"}'
                    ).encode()
                )
                conn.close()
                continue

            response = (
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: application/json\r\n"
                "Connection: close\r\n"
                f"Content-Length: {len(payload)}\r\n\r\n" + payload
            )
            conn.sendall(response.encode())
        finally:
            conn.close()


if __name__ == "__main__":
    main()
