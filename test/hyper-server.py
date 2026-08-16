#!/usr/bin/env python3
"""Dummy Hyper gateway server for crush tests.

Capture every request and stream configurable responses, so tests
exercise the real transport (sockets, filters) without touching the
actual Hyper gateway.

Usage:
  hyper-server.py <capture-file> [mode]

Modes (mirrors of the original elisp server):
  ok-stream   stream content deltas then [DONE]
  slow        same, with a 50ms gap between frames
  error-http  respond 401 with a JSON error body
  error-event stream an SSE error event then [DONE]
  malformed   stream truncated SSE then close
  not-found   respond 404 with an HTML error page
  reasoning   stream reasoning_content deltas, then content, then [DONE]

The server binds 127.0.0.1 on an ephemeral port, writes the base URL as
the first line of CAPTURE-FILE, then serves requests.  Only
POST /chat/completions is served (mirrors the real gateway); other
paths get a 404 JSON error.  Each request is appended to CAPTURE-FILE
as:

  REQUEST <method> <path>
  <header>: <value>
  ...
  BODY <body>

The server runs until killed; it handles one request per connection.
"""

import json
import os
import signal
import socket
import sys
import time


def sse(payload):
    return f"data: {payload}\n\n"


def content_frame(delta):
    return sse(json.dumps({"choices": [{"delta": {"content": delta}}]}))


def reasoning_frame(delta):
    return sse(json.dumps({"choices": [{"delta": {"reasoning_content": delta}}]}))


def main():
    capture = sys.argv[1]
    mode = sys.argv[2] if len(sys.argv) > 2 else "ok-stream"

    # Ignore SIGPIPE so a client disconnect doesn't kill us.
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(5)
    port = server.getsockname()[1]

    with open(capture, "w") as f:
        f.write(f"http://127.0.0.1:{port}\n")
        f.flush()

    deltas = ["mock", " response", "!"]

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
            # Find main request body after blank line
            head = text.split("\r\n\r\n")[0]
            lines = head.split("\r\n")
            if len(lines) == 1:
                lines = head.split("\n")
            request_line = lines[0]
            parts = request_line.split(" ")
            method = parts[0] if parts else "?"
            path = parts[1] if len(parts) > 1 else "?"
            headers = {}
            for line in lines[1:]:
                if ":" in line:
                    k, v = line.split(":", 1)
                    headers[k.strip().lower()] = v.strip()
            body = ""
            if "\r\n\r\n" in text:
                body = text.split("\r\n\r\n", 1)[1]
            elif "\n\n" in text:
                body = text.split("\n\n", 1)[1]
            clen = int(headers.get("content-length", "0"))
            while len(body.encode()) < clen:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                body += chunk.decode("utf-8", "replace")
            body = body[:clen] if clen else body

            with open(capture, "a") as f:
                f.write(f"REQUEST {method} {path}\n")
                for k, v in headers.items():
                    f.write(f"{k}: {v}\n")
                f.write(f"BODY {body}\n")
                f.flush()

            if path != "/chat/completions":
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

            sse_ok = (
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: text/event-stream\r\n"
                "Connection: keep-alive\r\n\r\n"
            )

            if mode == "error-http":
                response = (
                    "HTTP/1.1 401 Unauthorized\r\n"
                    "Content-Type: application/json\r\n"
                    "Connection: close\r\n\r\n"
                    '{"error":"invalid_token"}'
                )
                conn.sendall(response.encode())
            elif mode == "error-event":
                conn.sendall(
                    (
                        sse_ok
                        + sse(json.dumps({"error": "stream_failed"}))
                        + sse("[DONE]")
                    ).encode()
                )
            elif mode == "malformed":
                conn.sendall((sse_ok + 'data: {"choices":[{"delta":{"con').encode())
            elif mode == "not-found":
                conn.sendall(
                    (
                        "HTTP/1.1 404 Not Found\r\n"
                        "Content-Type: text/html\r\n"
                        "Connection: close\r\n\r\n"
                        "<!doctype html><title>Not Found</title>"
                    ).encode()
                )
            elif mode == "reasoning":
                conn.sendall(sse_ok.encode())
                conn.sendall(reasoning_frame("mock think ").encode())
                conn.sendall(reasoning_frame("harder").encode())
                conn.sendall(content_frame("answer").encode())
                conn.sendall(sse("[DONE]").encode())
            elif mode == "history":
                # History round-trip: the first request is a plain
                # [system, user]; later requests carry prior turns (>= 3
                # messages) and get an "ack <prior>" reply.
                conn.sendall(sse_ok.encode())
                try:
                    req = json.loads(body)
                    msgs = req.get("messages", [])
                    if len(msgs) >= 3:
                        prior = msgs[-2]
                        conn.sendall(
                            content_frame(
                                "ack " + str(prior.get("content", ""))[:20]
                            ).encode()
                        )
                    else:
                        conn.sendall(content_frame("first").encode())
                except ValueError:
                    conn.sendall(content_frame("first").encode())
                conn.sendall(sse("[DONE]").encode())
            elif mode == "reasoning-history":
                # Turn 1: a thinking request (reasoning + answer).  Later
                # requests (with prior turns) get an "ack" reply.
                conn.sendall(sse_ok.encode())
                try:
                    req = json.loads(body)
                    msgs = req.get("messages", [])
                    if len(msgs) >= 3:
                        prior = msgs[-2]
                        conn.sendall(
                            content_frame(
                                "ack " + str(prior.get("content", ""))[:20]
                            ).encode()
                        )
                    else:
                        conn.sendall(reasoning_frame("think step ").encode())
                        conn.sendall(reasoning_frame("hidden").encode())
                        conn.sendall(content_frame("answer out").encode())
                except ValueError:
                    conn.sendall(content_frame("first").encode())
                conn.sendall(sse("[DONE]").encode())
            elif mode == "reasoning-tool":
                # Reasoning followed by tool_calls with no content delta,
                # then [DONE].  Exercises the reasoning-only overlay
                # finalization path (no content delta to freeze it).
                conn.sendall(sse_ok.encode())
                conn.sendall(reasoning_frame("think step ").encode())
                conn.sendall(reasoning_frame("hidden").encode())
                tc_frame = json.dumps(
                    {
                        "choices": [
                            {
                                "delta": {
                                    "tool_calls": [
                                        {
                                            "index": 0,
                                            "id": "call_rt",
                                            "function": {
                                                "name": "exec_command",
                                                "arguments": json.dumps(
                                                    {"cmd": "echo hi"}
                                                ),
                                            },
                                        }
                                    ]
                                },
                                "finish_reason": "tool_calls",
                            }
                        ]
                    }
                )
                conn.sendall(sse(tc_frame).encode())
                conn.sendall(sse("[DONE]").encode())
            elif mode == "tool-call":
                # Tool-call round-trip: first request emits tool_calls
                # with finish_reason; subsequent requests carry role:tool
                # messages and get a content answer.
                conn.sendall(sse_ok.encode())
                try:
                    req = json.loads(body)
                    msgs = req.get("messages", [])
                    has_tool = any(
                        m.get("role") == "tool" for m in msgs if isinstance(m, dict)
                    )
                    if has_tool:
                        conn.sendall(content_frame("tool-result-ack").encode())
                        conn.sendall(sse("[DONE]").encode())
                    else:
                        tc_frame = json.dumps(
                            {
                                "choices": [
                                    {
                                        "delta": {
                                            "tool_calls": [
                                                {
                                                    "index": 0,
                                                    "id": "call_abc",
                                                    "function": {
                                                        "name": "exec_command",
                                                        "arguments": json.dumps(
                                                            {"cmd": "echo hi"}
                                                        ),
                                                    },
                                                }
                                            ]
                                        },
                                        "finish_reason": "tool_calls",
                                    }
                                ]
                            }
                        )
                        conn.sendall(sse(tc_frame).encode())
                        conn.sendall(sse("[DONE]").encode())
                except ValueError:
                    conn.sendall(content_frame("first").encode())
                    conn.sendall(sse("[DONE]").encode())
            elif mode == "tool-call-loop":
                # Always emit tool_calls, never a content answer.
                # Exercises the loop cap: the client should stop after
                # `crush-tool-loop-max' rounds and finalize.
                conn.sendall(sse_ok.encode())
                tc_frame = json.dumps(
                    {
                        "choices": [
                            {
                                "delta": {
                                    "tool_calls": [
                                        {
                                            "index": 0,
                                            "id": "call_loop",
                                            "function": {
                                                "name": "exec_command",
                                                "arguments": json.dumps(
                                                    {"cmd": "echo loop"}
                                                ),
                                            },
                                        }
                                    ]
                                },
                                "finish_reason": "tool_calls",
                            }
                        ]
                    }
                )
                conn.sendall(sse(tc_frame).encode())
                conn.sendall(sse("[DONE]").encode())
            else:  # ok-stream, slow
                conn.sendall(sse_ok.encode())
                for d in deltas:
                    conn.sendall(content_frame(d).encode())
                    if mode == "slow":
                        time.sleep(0.05)
                conn.sendall(sse("[DONE]").encode())
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass


if __name__ == "__main__":
    main()
