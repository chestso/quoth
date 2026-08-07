# Crush CLI Specification

This document describes how the Crush CLI operates in its two modes: standalone (`crush run`) and client/server.

## 1. Standalone Mode: `crush run`

### Overview

`crush run` executes Crush as a single process that reads prompts and produces responses via stdin/stdout. It is designed for programmatic invocation (e.g., from editors, scripts, or non-interactive environments).

### CLI Flags

```
crush run [flags] [prompt]
```

**Run-specific flags:**

- `-q, --quiet` — Hide spinner
- `-v, --verbose` — Show logs
- `-m, --model <model>` — Model to use (accepts `'model'` or `'provider/model'`)
- `--small-model <model>` — Small model override
- `-s, --session <id>` — Continue a previous session by ID (UUID or hash prefix)
- `-C, --continue` — Continue the most recent session

**Global flags (inherited):**

- `-c, --cwd <dir>` — Current working directory
- `-D, --data-dir <dir>` — Custom crush data directory
- `-d, --debug` — Debug mode
- `-H, --host <host>` — Connect to a specific crush server host
- `-y, --yolo` — Auto-accept all permissions (redundant in `run` mode)

### Permission Behavior

**All permissions are auto-approved.** The permission dialog that appears in interactive terminal mode is bypassed entirely. This is functionally equivalent to `--yolo` mode:

- `edit`, `write`, `bash`, and other tools execute immediately without user confirmation
- No interactive prompts block the process
- Source: `internal/cmd/run.go` line 337 calls `app.Permissions.AutoApproveSession(sess.ID)`

### Input/Output

**Input:**

- Prompts passed as CLI arguments: `crush run "fix the bug"`
- Prompts via stdin: `echo "fix the bug" | crush run`
- Combined: stdin prepended to CLI args with `\n\n` separator
- Stdin is read in full before processing

**Output:**

- **stdout**: Plain text streaming (no ANSI codes, no markdown rendering)
- **stderr**: Spinner (when TTY) and logs
- **No structured protocol** — raw text only
- Only `assistant` role `TextContent` parts are output; tool calls/results are not shown

**Streaming behavior:**

- Cursor-based reconciliation: tracks bytes already read per message ID
- Appends only new content on each message update
- Uses `RunComplete` event as authoritative end-of-run signal

### Session Management

**Storage:** SQLite database at `<data-dir>/crush.db`

Default data directory: `.crush` (relative to working directory), or `~/.local/share/crush/` for global.

**Database tables:**

- `sessions` — id, parent_session_id, title, message_count, prompt_tokens, completion_tokens, cost, todos, created_at, updated_at
- `messages` — id, session_id, role, parts (JSON), model, provider, created_at, updated_at, finished_at
- `files` — id, session_id, path, content, version
- `read_files` — session_id, path, read_at

**Session continuity:**

- `--continue` or `-C` — continue most recent session
- `--session <id>` — continue by session ID (full UUID or hash prefix)
- Session IDs can be: full UUID, full XXH3 hash, or hash prefix (ambiguous prefixes error)

### Environment Variables

- `CRUSH_GLOBAL_CONFIG` — Global config directory
- `CRUSH_GLOBAL_DATA` — Global data directory
- `CRUSH_CACHE_DIR` — Cache directory
- `CRUSH_SKILLS_DIR` — Skills directory
- `CRUSH_CLIENT_SERVER` — Enable client-server mode
- `CRUSH_SERVER_READY_TIMEOUT` — Server ready timeout (Go duration)
- `CRUSH_SERVER_IDLE_TIMEOUT` — Server idle timeout (seconds)
- `CRUSH_DISABLE_METRICS` — Disable metrics
- `CRUSH_DISABLE_PROVIDER_AUTO_UPDATE` — Disable provider auto-update
- `CRUSH_DISABLE_DEFAULT_PROVIDERS` — Ignore default/embedded providers
- `CRUSH_SKIP_DATADIR_LOCK` — Skip data directory locking

### Exit Codes

- `0` — Success
- `1` — General error
- `130` — SIGINT (interrupted)

### Limitations

- **No attachments** — `crush run` does not support `--file`, `--image`, or `--attach` flags
- **No permission prompts** — tools execute immediately
- **No structured output** — plain text only, no JSON option
- **No tool visibility** — tool calls and results are not shown in output
- **No multi-client synchronization**
- Suitable for single-user, single-process workflows

### Presenting Output

Since `crush run` outputs plain text with no formatting:

**Option 1: Pass through as-is**

- Stream stdout directly to the UI
- No parsing or transformation needed
- Simplest approach, but no rich formatting

**Option 2: Use client/server mode for structured data**

- Subscribe to SSE `message` events
- Receive structured `parts` array: `TextContent`, `ToolCall`, `ToolResult`, `ReasoningContent`
- Render each part type appropriately in the UI
- Enables syntax highlighting, code block detection, tool call visibility

**Option 3: Parse markdown heuristics**

- Detect code blocks via regex (triple backticks)
- Apply syntax highlighting based on language tag
- Handle headers, lists, bold/italic via markdown parser
- Fragile — relies on model output conventions

**Recommendation:** For rich presentation (code highlighting, tool visibility, structured layout), use client/server mode. `crush run` is best for simple text streaming where presentation doesn't matter.

### Querying Sessions from CLI

```bash
# List sessions
crush session list --json

# Show session details
crush session show <id> --json
crush session last --json

# Delete session
crush session delete <id> --json

# Rename session
crush session rename <id> <title> --json
```

JSON output structure:

```json
{
  "id": "abc1234", // 7-char hash
  "uuid": "...", // Full UUID
  "title": "...",
  "created": "2026-01-15T10:30:00Z",
  "modified": "2026-01-15T11:45:00Z"
}
```

---

## 2. Client/Server Mode

### Overview

Client/server mode runs Crush as a persistent server process. Multiple clients can connect, create workspaces, send prompts, receive streamed responses, and respond to permission requests via an HTTP API with SSE events.

### Starting the Server

**Manual:**

```bash
crush server
```

**Automatic:**
Set `CRUSH_CLIENT_SERVER=1` — the client auto-spawns a detached server if the socket doesn't exist.

**Flags:**

- `-H, --host` — override bind address (default: Unix socket)
- `-D, --data-dir` — custom data directory

**Auto-shutdown:** Server exits after 60 seconds of no active workspaces.

### Transport

**Default (Linux/macOS):**

```
unix://$XDG_RUNTIME_DIR/crush-<uid>.sock
```

Fallback: `unix:///tmp/crush-<uid>.sock`

**Default (Windows):**

```
npipe:////./pipe/crush-<uid>.sock
```

**TCP (optional):**

```bash
crush server --host tcp://localhost:8080
```

Protocol: HTTP/1.1 + unencrypted HTTP/2 over the socket.

### Protocol

**Base:** HTTP with JSON payloads. Standard web stack (not a custom wire protocol).

**Schema:** Crush-specific (not OpenAI, Anthropic, or MCP standard). Custom message format, tool schema, permission schema, and REST endpoints.

#### Key Endpoints

| Endpoint                                | Method | Description                |
| --------------------------------------- | ------ | -------------------------- |
| `/v1/workspaces`                        | POST   | Create workspace           |
| `/v1/workspaces/{id}`                   | GET    | Get workspace              |
| `/v1/workspaces/{id}/events`            | GET    | SSE event stream           |
| `/v1/workspaces/{id}/agent`             | POST   | Send prompt (202 Accepted) |
| `/v1/workspaces/{id}/sessions`          | POST   | Create session             |
| `/v1/workspaces/{id}/sessions/{sid}`    | GET    | Get session                |
| `/v1/workspaces/{id}/permissions/grant` | POST   | Grant/deny permission      |
| `/v1/workspaces/{id}/permissions/skip`  | POST   | Skip all permissions       |
| `/v1/health`                            | GET    | Health check               |

#### SSE Event Stream

**Subscribe:**

```
GET /v1/workspaces/{id}/events?client_id=UUID
Accept: text/event-stream
```

**Event Format:**

```
data: {"type":"<event_type>","payload":{...}}

```

**Event Types:**

| Type                      | Description                                   |
| ------------------------- | --------------------------------------------- |
| `message`                 | New/updated message (streamed response parts) |
| `permission_request`      | Permission request from agent                 |
| `permission_notification` | Permission granted/denied                     |
| `run_complete`            | Agent turn finished (terminal signal)         |
| `session`                 | Session created/updated/deleted               |
| `agent_event`             | Agent response/error                          |
| `lsp_event`               | LSP diagnostics/events                        |
| `mcp_event`               | MCP server events                             |
| `config_changed`          | Workspace config changed                      |
| `question_batch_request`  | Batch question from agent                     |

### Workflow

1. **Create Workspace:**

   ```http
   POST /v1/workspaces
   Content-Type: application/json

   {
     "path": "/path/to/project",
     "yolo": false,
     "client_id": "<UUID>"
   }
   ```

   Returns: `{"id": "<workspace-id>", ...}`

2. **Subscribe to Events:**

   ```http
   GET /v1/workspaces/{id}/events?client_id=<UUID>
   Accept: text/event-stream
   ```

3. **Send Prompt:**

   ```http
   POST /v1/workspaces/{id}/agent
   Content-Type: application/json

   {
     "session_id": "<session-uuid>",
     "prompt": "Your prompt text"
   }
   ```

   Returns: `202 Accepted` (async execution)

4. **Receive Response:**
   - Listen for `message` events with `type: "updated"`
   - Message parts include: `TextContent`, `ToolCall`, `ToolResult`, `ReasoningContent`

5. **Handle Permission Request:**
   - Receive `permission_request` event:
     ```json
     {
       "type": "permission_request",
       "payload": {
         "type": "created",
         "payload": {
           "id": "<permission-id>",
           "session_id": "<session-uuid>",
           "tool_call_id": "<tool-call-id>",
           "tool_name": "edit",
           "description": "Human-readable description"
         }
       }
     }
     ```
   - Respond via grant endpoint:

     ```http
     POST /v1/workspaces/{id}/permissions/grant
     Content-Type: application/json

     {
       "permission": {
         "id": "<permission-id>",
         "session_id": "<session-uuid>",
         "tool_call_id": "<tool-call-id>"
       },
       "action": "allow"
     }
     ```

   - Actions: `allow` (once), `allow_session` (session-wide), `deny`

6. **Detect Completion:**
   - Receive `run_complete` event:
     ```json
     {
       "type": "run_complete",
       "payload": {
         "session_id": "<session-uuid>",
         "message_id": "<message-id>",
         "error": null,
         "cancelled": false
       }
     }
     ```

### Message Schema

**Custom** (not OpenAI or Anthropic format):

```json
{
  "id": "<message-id>",
  "role": "user|assistant|tool",
  "session_id": "<session-uuid>",
  "parts": [
    {"type": "text", "text": "..."},
    {"type": "tool_call", "id": "...", "name": "edit", "input": {...}},
    {"type": "tool_result", "tool_call_id": "...", "content": "..."}
  ],
  "model": "claude-sonnet-4-20250514",
  "created_at": 1234567890
}
```

**Content part types** (from `internal/message/content.go`):

| Type               | Fields                                | Description                  |
| ------------------ | ------------------------------------- | ---------------------------- |
| `TextContent`      | `text`                                | Plain text content           |
| `ToolCall`         | `id`, `name`, `input`                 | Tool invocation request      |
| `ToolResult`       | `tool_call_id`, `content`, `is_error` | Tool execution result        |
| `ReasoningContent` | `text`                                | Model's reasoning/thinking   |
| `ImageURLContent`  | `url`, `mime_type`                    | Image attachment             |
| `BinaryContent`    | `data`, `mime_type`                   | Binary attachment            |
| `Finish`           | `reason`, `usage`                     | Completion marker            |
| `ShellCommand`     | `command`, `description`              | Shell command (for approval) |

### Tool Schema

**Custom** per tool, converted to provider-specific formats via `charm.land/fantasy` abstraction layer.

### MCP Integration

MCP (Model Context Protocol) is used for **external tool integration only**. Crush uses the official Go SDK (`github.com/modelcontextprotocol/go-sdk`) but does not expose MCP as its primary API.

---

## Comparison

| Feature             | `crush run`                     | Client/Server                 |
| ------------------- | ------------------------------- | ----------------------------- |
| Transport           | stdin/stdout pipes              | HTTP over Unix socket/TCP     |
| Permissions         | Auto-approved                   | Interactive via SSE           |
| Event stream        | No                              | Yes (SSE)                     |
| Multi-client        | No                              | Yes                           |
| Session persistence | Per-process                     | Server-managed                |
| Suitable for        | Scripts, single-process editors | Multi-client apps, TUIs, IDEs |

---

## References

- Crush source: https://github.com/charmbracelet/crush
- Permission auto-approve: [`internal/app/app.go:337`](https://github.com/charmbracelet/crush/blob/main/internal/app/app.go#L337)
- Server protocol: [`internal/server/proto.go`](https://github.com/charmbracelet/crush/blob/main/internal/server/proto.go), [`internal/server/server.go`](https://github.com/charmbracelet/crush/blob/main/internal/server/server.go)
- Client protocol: [`internal/client/proto.go`](https://github.com/charmbracelet/crush/blob/main/internal/client/proto.go), [`internal/client/client.go`](https://github.com/charmbracelet/crush/blob/main/internal/client/client.go)
- Event types: [`internal/pubsub/events.go`](https://github.com/charmbracelet/crush/blob/main/internal/pubsub/events.go)
- Message schema: [`internal/proto/message.go`](https://github.com/charmbracelet/crush/blob/main/internal/proto/message.go), [`internal/message/content.go`](https://github.com/charmbracelet/crush/blob/main/internal/message/content.go)
- Permission schema: [`internal/proto/permission.go`](https://github.com/charmbracelet/crush/blob/main/internal/proto/permission.go)
- HTTP API spec: [`internal/swagger/swagger.yaml`](https://github.com/charmbracelet/crush/blob/main/internal/swagger/swagger.yaml)
