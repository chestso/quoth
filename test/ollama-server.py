#!/usr/bin/env python3
"""Dummy Ollama Cloud server for quoth tests.

Capture every request and stream configurable responses, so tests
exercise the real transport (sockets, filters) without touching the
actual cloud.

Usage:
  ollama-server.py <capture-file> [mode]

Modes:
  ok-stream    stream `reasoning' deltas, content deltas, a final
               usage chunk (empty `choices'), then [DONE]
  tool-call    first request emits tool_calls; follow-ups carrying a
               role:tool message get a content answer
  tool-call-loop   always emit tool_calls (exercises the loop cap)
  error-402    respond 402 with the gated-model error body

Served endpoints:
  GET  /api/tags   model membership (a couple of models)
  POST /api/show   per-model capabilities + model_info (the
                   architecture-prefixed context_length key)
  POST /chat/completions   the OpenAI-compatible SSE surface

The server binds 127.0.0.1 on an ephemeral port, writes the base URL
as the first line of CAPTURE-FILE, then serves requests.  Each request
is appended to CAPTURE-FILE as:

  REQUEST <method> <path>
  <header>: <value>
  ...
  BODY <body>

The base URL points at the OpenAI `/v1' root, so the chat surface
serves `/v1/chat/completions' (the client appends `/chat/completions'
to the base URL); the native catalog root derives from it by stripping
the `/v1' suffix.  The server runs until killed; it handles one
request per connection.
"""

import json
import signal
import socket
import sys


def sse(payload):
    return f"data: {payload}\n\n"


def content_frame(delta):
    return sse(json.dumps({"choices": [{"delta": {"content": delta}}]}))


def reasoning_frame(delta):
    return sse(json.dumps({"choices": [{"delta": {"reasoning": delta}}]}))


# Catalog membership: what GET /api/tags reports.  The models list is
# mirrored in SHOW_DATA so every tags entry has a matching /api/show.
TAGS_MODELS = ["gpt-oss:20b", "gemma4:31b"]

SHOW_DATA = {
    "gpt-oss:20b": {
        "capabilities": ["completion", "tools", "thinking"],
        "model_info": {
            "general.architecture": "gptoss",
            "gptoss.context_length": 131072,
        },
    },
    "gemma4:31b": {
        "capabilities": ["completion", "thinking", "tools", "vision"],
        "model_info": {
            "general.architecture": "gemma4",
            "gemma4.embedding_length": 5376,
            "gemma4.context_length": 262144,
        },
    },
}


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
        f.write(f"http://127.0.0.1:{port}/v1\n")
        f.flush()

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

            if path == "/api/tags":
                conn.sendall(
                    (
                        "HTTP/1.1 200 OK\r\n"
                        "Content-Type: application/json\r\n"
                        "Connection: close\r\n\r\n"
                        + json.dumps(
                            {
                                "models": [
                                    {
                                        "name": name,
                                        "model": name,
                                        "modified_at": "2025-08-05T00:00:00Z",
                                        "size": 0,
                                        "digest": "deadbeef",
                                        "details": {
                                            "parent_model": "",
                                            "format": "",
                                            "family": "",
                                            "families": None,
                                            "parameter_size": "",
                                            "quantization_level": "",
                                        },
                                    }
                                    for name in TAGS_MODELS
                                ]
                            }
                        )
                        + "\r\n"
                    ).encode()
                )
                conn.close()
                continue

            if path == "/api/show":
                model = ""
                try:
                    model = json.loads(body).get("model", "")
                except ValueError:
                    pass
                show = SHOW_DATA.get(model)
                if show is None:
                    conn.sendall(
                        (
                            "HTTP/1.1 404 Not Found\r\n"
                            "Content-Type: application/json\r\n"
                            "Connection: close\r\n\r\n"
                            '{"error":"model not found"}'
                        ).encode()
                    )
                else:
                    conn.sendall(
                        (
                            "HTTP/1.1 200 OK\r\n"
                            "Content-Type: application/json\r\n"
                            "Connection: close\r\n\r\n" + json.dumps(show) + "\r\n"
                        ).encode()
                    )
                conn.close()
                continue

            if path not in ("/v1/chat/completions", "/chat/completions"):
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

            if mode == "error-402":
                # The gated-model shape: the model is listed in the
                # catalog but rejected at request time with a readable
                # body (subscription / extra usage).
                conn.sendall(
                    (
                        "HTTP/1.1 402 Payment Required\r\n"
                        "Content-Type: application/json\r\n"
                        "Connection: close\r\n\r\n"
                        + json.dumps(
                            {
                                "error": {
                                    "message": (
                                        "this model requires a subscription"
                                        " or extra usage, upgrade for access"
                                        " at https://ollama.com/upgrade"
                                        " (ref: mock-402)"
                                    ),
                                    "type": "api_error",
                                    "param": None,
                                    "code": None,
                                }
                            }
                        )
                        + "\r\n"
                    ).encode()
                )
            elif mode == "tool-call":
                # Tool-call round-trip: the first request emits
                # tool_calls with finish_reason; subsequent requests
                # carrying role:tool messages get a content answer.
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
                # `quoth-tool-loop-max' rounds and finalize.
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
            else:  # ok-stream
                # The ollama shape: `reasoning' field deltas (ollama's
                # spelling of the OpenAI reasoning_content alias),
                # content deltas, a usage-final chunk with an empty
                # `choices' array (gated on stream_options.include_usage),
                # then [DONE].
                conn.sendall(sse_ok.encode())
                conn.sendall(reasoning_frame("mock think ").encode())
                conn.sendall(reasoning_frame("harder").encode())
                conn.sendall(content_frame("mock").encode())
                conn.sendall(content_frame(" response!").encode())
                final = json.dumps(
                    {
                        "id": "chatcmpl-mock",
                        "object": "chat.completion.chunk",
                        "model": "gpt-oss:20b",
                        "choices": [],
                        "usage": {
                            "prompt_tokens": 68,
                            "completion_tokens": 5,
                            "total_tokens": 73,
                        },
                    }
                )
                conn.sendall(sse(final).encode())
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
