# Ollama: Full Story & API Integration Guide

## 1. What Is Ollama?

Ollama is a tool for running large language models (LLMs) locally and in the
cloud. It was created in 2023 by Jeffrey Morgan and Michael Chiang. Think of it
like Docker, but for AI models — you pull a model, run it, and interact with it
via a REST API.

- **Website:** https://ollama.com/
- **GitHub:** https://github.com/ollama/ollama
- **Docs:** https://docs.ollama.com/

Ollama lets you run popular open-weight models like Llama 3, Mistral, Phi,
Gemma, DeepSeek, GLM, Qwen, and many others without needing to manually set up
inference engines like llama.cpp.

---

## 2. The Two Sides of Ollama

### A. Local (Free, Open Source)

- Download the Ollama CLI/daemon (MIT licensed)
- Run models on your own CPU/GPU
- No subscription, no cloud dependency
- Your data never leaves your machine
- Limited by your own hardware (RAM/VRAM)

### B. Ollama Cloud (Subscription)

- Run larger models on Ollama's datacenter hardware
- Accessed through the same app or directly via API
- Subscription tiers with usage limits (see pricing below)

You can use either or both. The local daemon and the cloud API expose the same
REST API surface, so your application code stays the same — you just change the
target URL and add authentication for cloud.

---

## 3. Pricing (as of 2026)

Source: https://ollama.com/pricing

| Plan | Price                   | Notes                                            |
| ---- | ----------------------- | ------------------------------------------------ |
| Free | $0                      | Local use + limited cloud access                 |
| Pro  | ~$20/month (or $200/yr) | Heavier cloud usage, ~50x free tier limits       |
| Max  | ~$100/month             | Heaviest workloads; **new subscriptions paused** |
| Team | ~$125/month (5 × $25)   | Shared billing for groups, minimum 5 seats       |

- Pro and Max subscribers can buy extra usage beyond plan limits.
- Max subscriptions are currently paused for new signups due to capacity demands
  — existing Max subscribers keep their plan, limits, and pricing.
- The free tier includes limited cloud model access with hourly/daily caps.

---

## 4. Licensing — Important Nuance

There is a split between two components:

| Component                        | License         | Source?                                |
| -------------------------------- | --------------- | -------------------------------------- |
| Ollama CLI + server daemon (API) | **MIT**         | Open source — github.com/ollama/ollama |
| Ollama desktop GUI app           | **Proprietary** | Closed source, not published anywhere  |

### What happened with the GUI

In mid-2025, Ollama released a new desktop GUI app. This caused community
pushback because:

- The GUI app bundled in the installer from ollama.com is **closed source**.
- It is not part of the MIT-licensed GitHub repository.
- No source code for the GUI has been published.

Relevant discussions:

- GitHub issue: https://github.com/ollama/ollama/issues/11634
- Reddit: https://www.reddit.com/r/LocalLLaMA/comments/1meeyee/
- Hacker News: https://news.ycombinator.com/item?id=44739632

### What this means for you

As a developer integrating the API, you only need the **MIT-licensed
CLI/daemon** (or no local install at all if using cloud directly). The
closed-source GUI app is optional and not needed for API integration.

You can get the open-source CLI from:

- GitHub releases: https://github.com/ollama/ollama/releases
- Package managers: `brew install ollama` (macOS), or direct download

---

## 5. Do You Need to Install Ollama Locally?

**No — if you only want cloud API access.** You can skip the local install
entirely and call Ollama's cloud API directly.

### Option A: Direct Cloud API (no local install)

- **Endpoint:** `https://ollama.com/api`
- **OpenAI-compatible endpoint:** `https://ollama.com/v1`
- **Auth:** `Authorization: Bearer <OLLAMA_API_KEY>`
- **Get an API key at:** https://ollama.com/settings/keys

```bash
curl -H "Authorization: Bearer $OLLAMA_API_KEY" \
  https://ollama.com/api/chat \
  -d '{
    "model": "gpt-oss:120b-cloud",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": false
  }'
```

### Option B: Local daemon (free, self-hosted)

- **Endpoint:** `http://localhost:11434`
- **Auth:** None required
- Models run on your own hardware

```bash
ollama serve   # start the local API server
ollama pull llama3.1   # download a model
curl http://localhost:11434/api/chat \
  -d '{"model":"llama3.1","messages":[{"role":"user","content":"Hi"}]}'
```

### Option C: Local daemon proxying to cloud

If you install the local app and sign in, the daemon can transparently proxy
cloud model requests to Ollama's servers. You'd use `localhost:11434` as the
endpoint and request cloud-tagged models (e.g. `gpt-oss:120b-cloud`). This is
the default workflow the pricing page pushes ("Download"), but is not required.

---

## 6. Full API Specification

All endpoints below were verified by live testing against Ollama's cloud API
using `https://ollama.com/api` (native) and `https://ollama.com/v1`
(OpenAI-compatible). Base URLs:

| API style     | Base URL                 | Auth                          |
| ------------- | ------------------------ | ----------------------------- |
| Native Ollama | `https://ollama.com/api` | `Authorization: Bearer <KEY>` |
| OpenAI-compat | `https://ollama.com/v1`  | `Authorization: Bearer <KEY>` |
| Local daemon  | `http://localhost:11434` | None required                 |

> **Correction from earlier sections:** The OpenAI-compatible base URL is
> `https://ollama.com/v1` (NOT `https://ollama.com/api/v1`).

> **Auth enforcement is per-endpoint on the cloud (verified Sep 2026):**
> generation endpoints (`/v1/chat/completions`, `/v1/completions`, `/api/chat`,
> `/api/generate`) return **401** without a key. Catalog and metadata endpoints
> (`/v1/models`, `/v1/models/{model}`, `/api/tags`, `/api/show`) are **public**
> — they answer 200 without any key. `/api/show` returns 404 for an unknown
> model.

### 6.1. POST /api/chat

Chat completion with message history. This is the primary endpoint for
conversational AI.

**Request parameters:**

| Parameter    | Type          | Required | Description                                    |
| ------------ | ------------- | -------- | ---------------------------------------------- |
| `model`      | string        | Yes      | Model name (e.g. `gpt-oss:120b`, `gemma4:31b`) |
| `messages`   | array         | Yes      | Array of message objects (see below)           |
| `stream`     | boolean       | No       | Stream tokens as SSE (default: `true`)         |
| `format`     | string/object | No       | Structured output: `"json"` or JSON schema     |
| `tools`      | array         | No       | Function/tool definitions for tool calling     |
| `think`      | boolean       | No       | Enable/disable thinking/reasoning output       |
| `options`    | object        | No       | Model parameters (see 6.9)                     |
| `keep_alive` | string        | No       | How long to keep model loaded (e.g. `"5m"`)    |

**Message object:**

| Field        | Type   | Required | Description                                   |
| ------------ | ------ | -------- | --------------------------------------------- |
| `role`       | string | Yes      | `system`, `user`, `assistant`, or `tool`      |
| `content`    | string | Yes      | The message text                              |
| `images`     | array  | No       | Base64-encoded images (for multimodal models) |
| `tool_calls` | array  | No       | Tool calls made by assistant (in tool flow)   |

**Example — basic chat:**

```bash
curl -H "Authorization: Bearer $OLLAMA_API_KEY" \
  https://ollama.com/api/chat \
  -d '{
    "model": "gpt-oss:120b",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Why is the sky blue?"}
    ],
    "stream": false
  }'
```

**Response:**

```json
{
  "model": "gpt-oss:120b",
  "created_at": "2026-08-31T06:39:54.572332878Z",
  "message": {
    "role": "assistant",
    "content": "The sky appears blue because of Rayleigh scattering...",
    "thinking": "The user asks about the sky color. I should explain Rayleigh scattering..."
  },
  "done": true,
  "done_reason": "stop",
  "total_duration": 767639443,
  "prompt_eval_count": 73,
  "eval_count": 39
}
```

**Response fields:**

| Field                | Type    | Description                                    |
| -------------------- | ------- | ---------------------------------------------- |
| `model`              | string  | Model name used                                |
| `created_at`         | string  | ISO 8601 timestamp                             |
| `message.role`       | string  | Always `assistant`                             |
| `message.content`    | string  | The generated response text                    |
| `message.thinking`   | string  | Chain-of-thought reasoning (if model supports) |
| `message.tool_calls` | array   | Tool/function calls (if tools were provided)   |
| `done`               | boolean | Whether generation is complete                 |
| `done_reason`        | string  | `stop`, `length`, or `tools`                   |
| `total_duration`     | number  | Total time in nanoseconds                      |
| `prompt_eval_count`  | number  | Number of tokens in the prompt                 |
| `eval_count`         | number  | Number of tokens generated                     |

---

### 6.2. POST /api/generate

Text generation from a single prompt (no message history).

**Request parameters:**

| Parameter    | Type          | Required | Description                                   |
| ------------ | ------------- | -------- | --------------------------------------------- |
| `model`      | string        | Yes      | Model name                                    |
| `prompt`     | string        | Yes      | The prompt text                               |
| `stream`     | boolean       | No       | Stream tokens (default: `true`)               |
| `format`     | string/object | No       | `"json"` or JSON schema for structured output |
| `options`    | object        | No       | Model parameters (see 6.9)                    |
| `keep_alive` | string        | No       | Model load duration (e.g. `"5m"`)             |
| `suffix`     | string        | No       | Text to append after generation               |
| `context`    | array         | No       | Context from prior request (for continuation) |
| `raw`        | boolean       | No       | Bypass prompt template (advanced)             |

**Example:**

```bash
curl -H "Authorization: Bearer $OLLAMA_API_KEY" \
  https://ollama.com/api/generate \
  -d '{
    "model": "gpt-oss:120b",
    "prompt": "Why is the sky blue?",
    "stream": false
  }'
```

**Response:**

```json
{
  "model": "gpt-oss:120b",
  "created_at": "2026-08-31T06:40:02.188330667Z",
  "response": "The sky appears blue because of Rayleigh scattering...",
  "thinking": "The user asks about the sky color...",
  "done": true,
  "done_reason": "stop",
  "total_duration": 1145096935,
  "prompt_eval_count": 73,
  "eval_count": 65
}
```

Note: `/api/generate` returns `response` (not `message.content` like
`/api/chat`).

---

### 6.3. GET /api/tags

List all available models.

**Example:**

```bash
curl -H "Authorization: Bearer $OLLAMA_API_KEY" \
  https://ollama.com/api/tags
```

**Response:**

```json
{
  "models": [
    {
      "name": "gpt-oss:120b",
      "model": "gpt-oss:120b",
      "modified_at": "2025-08-05T00:00:00Z",
      "size": 65290180781,
      "digest": "da11955bb451",
      "details": {
        "parent_model": "",
        "format": "",
        "family": "gptoss",
        "families": null,
        "parameter_size": "116829156672",
        "quantization_level": "MXFP4"
      }
    }
  ]
}
```

**Model object fields:**

| Field                        | Type   | Description                           |
| ---------------------------- | ------ | ------------------------------------- |
| `name`                       | string | Model name with tag                   |
| `model`                      | string | Same as name                          |
| `modified_at`                | string | Last modified date (ISO 8601)         |
| `size`                       | number | Model size in bytes                   |
| `digest`                     | string | SHA256 digest of model                |
| `details.family`             | string | Model family (e.g. `gptoss`, `gemma`) |
| `details.parameter_size`     | string | Total parameters                      |
| `details.quantization_level` | string | Quantization (e.g. `MXFP4`, `Q4_K_M`) |

> **Live testing note (Sep 2026):** on the cloud, `/api/tags` works with or
> without an API key, but the `details` sub-object is an **empty stub**
> (`family`/`parameter_size`/`quantization_level` are empty strings, and `size`
> is 0 for many models). Real per-model metadata lives in `/api/show` (section
> 6.4). 19 models listed as of Sep 2026.

---

### 6.4. POST /api/show

Get detailed information about a specific model, including capabilities and
architecture info.

**Request:**

| Parameter | Type   | Required | Description |
| --------- | ------ | -------- | ----------- |
| `model`   | string | Yes      | Model name  |

**Example:**

```bash
curl -H "Authorization: Bearer $OLLAMA_API_KEY" \
  https://ollama.com/api/show \
  -d '{"model": "gpt-oss:120b"}'
```

**Response:**

```json
{
  "capabilities": ["completion", "tools", "thinking"],
  "details": {
    "parent_model": "gpt-oss:120b",
    "format": "",
    "family": "gptoss",
    "families": null,
    "parameter_size": "116829156672",
    "quantization_level": "MXFP4"
  },
  "model_info": {
    "general.architecture": "gptoss",
    "general.parameter_count": 116829156672,
    "gptoss.context_length": 131072,
    "gptoss.embedding_length": 2880
  },
  "modified_at": "2025-08-05T00:00:00Z"
}
```

**Key fields:**

| Field                        | Type   | Description                                 |
| ---------------------------- | ------ | ------------------------------------------- |
| `capabilities`               | array  | `completion`, `tools`, `thinking`, `vision` |
| `details.family`             | string | Model architecture family                   |
| `details.parameter_size`     | string | Total parameter count                       |
| `details.quantization_level` | string | Quantization format                         |
| `model_info`                 | object | Architecture-specific metadata              |

> **`model_info` context length:** the key is architecture-prefixed, e.g.
> `gptoss.context_length`, `gemma4.context_length`, `glm_dsa_moe.context_length`
> — match on the `.context_length` suffix, not a fixed key name (verified on
> five families, Sep 2026).

> **Tested models confirmed capabilities:**
>
> - `gpt-oss:120b`: `["completion", "tools", "thinking"]` — family `gptoss`,
>   context length 131072, MXFP4 quantization
> - `gpt-oss:20b`: `["completion", "tools", "thinking"]` — family `gptoss`,
>   context length 131072, MXFP4 quantization
> - `gemma4:31b`: `["completion", "thinking", "tools", "vision"]` — multimodal
>   (vision-capable, confirmed via image test)
> - `glm-5.3`, `deepseek-v4-pro:0813`, `nemotron-3-nano:30b`:
>   `["completion", "tools", "thinking"]` (Sep 2026)
> - Gated models return full `capabilities`/`model_info` too (`kimi-k3`:
>   `["vision", "thinking", "completion", "tools"]`, context 1048576) — see the
>   402 note in section 6.16.

---

### 6.5. GET /api/version

Returns the API/server version.

**Example:**

```bash
curl -H "Authorization: Bearer $OLLAMA_API_KEY" \
  https://ollama.com/api/version
```

**Response:**

```json
{ "version": "0.0.0" }
```

> Note: Cloud returns `0.0.0.0` as version (placeholder). Local daemon returns
> the actual installed version (e.g. `0.5.0`).

---

### 6.6. POST /api/chat with Tools (Function Calling)

Ollama supports tool/function calling. Define tools in the request, and the
model can respond with tool calls instead of (or alongside) text.

**Tool object structure:**

```json
{
  "type": "function",
  "function": {
    "name": "get_weather",
    "description": "Get the current weather for a given city",
    "parameters": {
      "type": "object",
      "properties": {
        "city": { "type": "string", "description": "The city name" },
        "unit": { "type": "string", "enum": ["celsius", "fahrenheit"] }
      },
      "required": ["city"]
    }
  }
}
```

**Full example:**

```bash
curl -H "Authorization: Bearer $OLLAMA_API_KEY" \
  https://ollama.com/api/chat \
  -d '{
    "model": "gpt-oss:120b",
    "messages": [
      {"role": "user", "content": "What is the weather in London?"}
    ],
    "stream": false,
    "tools": [
      {
        "type": "function",
        "function": {
          "name": "get_weather",
          "description": "Get the current weather for a given city",
          "parameters": {
            "type": "object",
            "properties": {
              "city": {"type": "string", "description": "The city name"},
              "unit": {"type": "string", "enum": ["celsius", "fahrenheit"]}
            },
            "required": ["city"]
          }
        }
      }
    ]
  }'
```

**Response with tool call:**

```json
{
  "model": "gpt-oss:120b",
  "created_at": "2026-08-31T06:40:53.729886883Z",
  "message": {
    "role": "assistant",
    "content": "",
    "thinking": "We need to fetch weather using function. Use get_weather with city London.",
    "tool_calls": [
      {
        "id": "call_qo0lmpmk",
        "function": {
          "index": 0,
          "name": "get_weather",
          "arguments": {
            "city": "London",
            "unit": "metric"
          }
        }
      }
    ]
  },
  "done": true,
  "done_reason": "tool_calls",
  "total_duration": 1305678813,
  "prompt_eval_count": 146,
  "eval_count": 54
}
```

> **`options.num_predict` vs `max_tokens` (Sep 2026 live test):** on the native
> `/api` endpoints the token cap is `options.num_predict` — a top-level
> `max_tokens` is silently ignored (`eval_count` far past 5). Use `max_tokens`
> only on the OpenAI-compatible `/v1` endpoints, where it is honored.

> **Tool-call wire shape differs per surface (Sep 2026 live tests):**
> `function.arguments` is a **JSON-encoded string** on the OpenAI-compatible
> `/v1` endpoint (the OpenAI convention) but a **nested JSON object** on the
> native `/api/chat` endpoint. Native `done_reason` for a tool response is
> `tool_calls`; the tool call arrives with a `thinking` field and empty
> `content`. `stream_options.include_usage` is likewise a `/v1`-only feature —
> the native endpoint accepts the key but ignores it (usage arrives via
> `prompt_eval_count`/`eval_count` on every chunk instead).

**Tool call flow:**

1. Send user message + tool definitions
2. Model responds with `tool_calls` in `message`
3. You execute the function locally
4. Send the result back as a message with `role: "tool"`:

```json
{
  "model": "gpt-oss:120b",
  "messages": [
    {"role": "user", "content": "What is the weather in London?"},
    {"role": "assistant", "tool_calls": [{"id": "call_qo0lmpmk", ...}]},
    {"role": "tool", "content": "{\"temperature\": 15, \"unit\": \"celsius\"}"}
  ],
  "stream": false
}
```

5. Model generates a final natural-language response incorporating the tool
   result.

---

### 6.7. Structured Output (JSON Schema)

Both `/api/chat` and `/api/generate` support a `format` parameter for
constraining output to a JSON schema.

**Using `format: "json"` (simple):**

```json
{
  "model": "gpt-oss:120b",
  "messages": [{ "role": "user", "content": "Tell me about Paris." }],
  "format": "json",
  "stream": false
}
```

**Using `format` with a full JSON schema (constrained):**

```bash
curl -H "Authorization: Bearer $OLLAMA_API_KEY" \
  https://ollama.com/api/chat \
  -d '{
    "model": "gpt-oss:120b",
    "messages": [
      {"role": "user", "content": "Tell me about Paris. Return name, country, and population."}
    ],
    "stream": false,
    "format": {
      "type": "object",
      "properties": {
        "name": {"type": "string"},
        "country": {"type": "string"},
        "population": {"type": "integer"}
      },
      "required": ["name", "country", "population"]
    }
  }'
```

> **Note:** In live testing, the model did not strictly enforce the JSON schema
> — it returned Markdown-formatted text instead. This may vary by model. For
> guaranteed structured output, combine `format` with explicit prompt
> instructions (e.g. "Respond with ONLY valid JSON, no Markdown").

---

### 6.8. Multimodal (Vision / Images)

Models with vision capabilities (e.g. `gemma4:31b`) accept base64-encoded images
in the `images` field of a message.

**Example:**

```bash
# A 1x1 red pixel PNG, base64-encoded
IMG_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

curl -H "Authorization: Bearer $OLLAMA_API_KEY" \
  https://ollama.com/api/chat \
  -d "{
    \"model\": \"gemma4:31b\",
    \"messages\": [{
      \"role\": \"user\",
      \"content\": \"What color is this image?\",
      \"images\": [\"$IMG_B64\"]
    }],
    \"stream\": false
  }"
```

**Response:**

```json
{
  "model": "gemma4:31b",
  "created_at": "2026-08-31T06:43:33.500604111Z",
  "message": {
    "role": "assistant",
    "content": "This image is red."
  },
  "done": true,
  "done_reason": "stop",
  "total_duration": 6672545066,
  "prompt_eval_count": 277,
  "eval_count": 6
}
```

The `images` field is an array of base64 strings (no data URI prefix). Multiple
images can be passed in a single message.

**OpenAI-compatible endpoint (verified live, Sep 2026):** the same models accept
standard OpenAI content-parts on `/v1/chat/completions` — `image_url` parts
whose `url` is a **`data:` URI** (`data:image/png;base64,...`). Verified
end-to-end on `gemma4:31b` (a 1x1 red pixel answered "Red"), streaming and
non-streaming, with `stream_options.include_usage` intact:

```json
{
  "model": "gemma4:31b",
  "messages": [
    {
      "role": "user",
      "content": [
        {
          "type": "text",
          "text": "What color is this image? Answer with just the color word."
        },
        {
          "type": "image_url",
          "image_url": { "url": "data:image/png;base64,iVBORw0KGgo..." }
        }
      ]
    }
  ]
}
```

> **Vision constraints on `/v1` (Sep 2026 live tests):**
>
> - Bare base64 without the `data:` prefix → `invalid_request_error` "invalid
>   image input" (the `data:` URI form is required — the opposite of the native
>   `images` field, which wants bare base64).
> - Remote `https://` image URLs → `invalid_request_error` "image URLs are not
>   currently supported, please use base64 encoded data instead".
> - Image parts sent to a non-vision model (e.g. `gpt-oss:20b`) →
>   `invalid_request_error` "this model does not support image input" — a clean
>   rejection, not a silent strip.

---

### 6.9. Options (Model Parameters)

The `options` object controls generation behavior. It can be passed to both
`/api/chat` and `/api/generate`.

```json
{
  "model": "gpt-oss:120b",
  "messages": [{ "role": "user", "content": "Say hello" }],
  "stream": false,
  "options": {
    "temperature": 0.0,
    "top_p": 0.9,
    "top_k": 40,
    "seed": 42,
    "num_ctx": 4096,
    "min_p": 0.0
  },
  "keep_alive": "5m"
}
```

**Full options reference:**

| Parameter          | Type    | Default | Description                                    |
| ------------------ | ------- | ------- | ---------------------------------------------- |
| `temperature`      | float   | 0.8     | Creativity/randomness (0 = deterministic)      |
| `top_p`            | float   | 0.9     | Nucleus sampling: probability mass to consider |
| `top_k`            | int     | 40      | Top-K sampling: consider top K tokens          |
| `min_p`            | float   | 0.0     | Minimum probability relative to top token      |
| `seed`             | int     | -1      | Random seed for reproducibility                |
| `num_ctx`          | int     | 2048    | Context window size in tokens                  |
| `num_predict`      | int     | -1      | Max tokens to generate (-1 = unlimited)        |
| `num_keep`         | int     | 0       | Tokens to keep from prompt                     |
| `num_thread`       | int     | auto    | Number of CPU threads (local only)             |
| `num_gpu           | int     | -1      | GPU layers to offload (local only)             |
| `repeat_penalty`   | float   | 1.1     | Penalty for repeated tokens                    |
| `repeat_last_n`    | int     | 64      | Window size for repeat penalty                 |
| `penalize_newline` | boolean | true    | Penalize newline tokens                        |
| `stop`             | array   | []      | Stop sequences (array of strings)              |
| `tfs_z`            | float   | 1.0     | Tail-free sampling parameter                   |
| `typical_p`        | float   | 1.0     | Typical sampling parameter                     |
| `mirostat`         | int     | 0       | Mirostat version (0, 1, or 2)                  |
| `mirostat_tau`     | float   | 5.0     | Mirostat target entropy                        |
| `mirostat_eta`     | float   | 0.1     | Mirostat learning rate                         |

> `keep_alive` (not in `options`) controls how long a model stays loaded in
> memory after the request. Format: `"5m"` (5 minutes), `"30s"`, or `"0"` to
> unload immediately. Default is `"5m"`.

---

### 6.10. Embeddings

**Native endpoint:** `POST /api/embed`

```bash
curl -H "Authorization: Bearer $OLLAMA_API_KEY" \
  https://ollama.com/api/embed \
  -d '{
    "model": "nomic-embed-text",
    "input": "Why is the sky blue?"
  }'
```

**Expected response:**

```json
{
  "model": "nomic-embed-text",
  "embeddings": [[0.123, -0.456, 0.789, ...]],
  "total_duration": 123456789,
  "load_duration": 9876543,
  "prompt_eval_count": 6
}
```

**Legacy endpoint:** `POST /api/embeddings` (single embedding, deprecated)

> **Live testing note:** The `/api/embed` and `/api/embeddings` endpoints
> returned `"unauthorized"` on the cloud API during testing (Aug 2026). The
> `/v1/embeddings` OpenAI-compatible endpoint also returned empty results. This
> suggests embeddings may not be available on the cloud free tier, or require an
> embedding-specific model. Embeddings work on the local daemon with models like
> `nomic-embed-text` or `bge-m3`. Check current cloud support by testing with
> your API key.

---

### 6.11. POST /api/ps

List currently loaded (running) models.

```bash
curl -H "Authorization: Bearer $OLLAMA_API_KEY" \
  https://ollama.com/api/ps
```

> **Live testing note:** Returned `"unauthorized"` on the cloud API. This
> endpoint works on the local daemon, where it shows models currently loaded in
> memory with their size, processor, and expiration time.

---

### 6.12. POST /api/pull (Local Only)

Download a model to the local machine. This is only relevant for the local
daemon, not the cloud API.

```bash
# Via CLI
ollama pull llama3.1

# Via API (local daemon only)
curl http://localhost:11434/api/pull \
  -d '{"name": "llama3.1", "stream": false}'
```

---

### 6.13. POST /api/delete (Local Only)

Delete a local model.

```bash
# Via CLI
ollama rm llama3.1

# Via API (local daemon only)
curl -X DELETE http://localhost:11434/api/delete \
  -d '{"name": "llama3.1"}'
```

---

### 6.14. POST /api/copy (Local Only)

Copy a local model to a new name.

```bash
curl http://localhost:11434/api/copy \
  -d '{"source": "llama3.1", "destination": "my-llama"}'
```

---

### 6.15. POST /api/create (Local Only)

Create a custom model from a Modelfile (for fine-tuning behavior, system
prompts, etc.).

```bash
# Create a Modelfile
cat > Modelfile << 'EOF'
FROM llama3.1
SYSTEM "You are a helpful assistant that speaks like a pirate."
PARAMETER temperature 0.7
EOF

# Via CLI
ollama create my-pirate -f Modelfile

# Via API (local daemon only)
curl http://localhost:11434/api/create \
  -d '{"name": "my-pirate", "modelfile": "FROM llama3.1\nSYSTEM \"You are a pirate.\""}'
```

---

### 6.16. OpenAI-Compatible API

Ollama exposes OpenAI-compatible endpoints at **`https://ollama.com/v1`**
(cloud) or **`http://localhost:11434/v1`** (local).

> **Important:** The base URL is `https://ollama.com/v1`, NOT
> `https://ollama.com/api/v1`.

#### POST /v1/chat/completions

```bash
curl -H "Authorization: Bearer $OLLAMA_API_KEY" \
  -H "Content-Type: application/json" \
  https://ollama.com/v1/chat/completions \
  -d '{
    "model": "gpt-oss:120b",
    "messages": [{"role": "user", "content": "Say hello in one word."}],
    "stream": false,
    "temperature": 0
  }'
```

**Response (OpenAI format):**

```json
{
  "id": "chatcmpl-730",
  "object": "chat.completion",
  "created": 1788158498,
  "model": "gpt-oss:120b",
  "system_fingerprint": "fp_ollama",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Hello",
        "reasoning": "The user asks: \"Say hello in one word.\"..."
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 73,
    "completion_tokens": 78,
    "total_tokens": 151
  }
}
```

> Note: Ollama maps the `thinking` field to `reasoning` in the OpenAI-compatible
> response. This is a non-standard extension to the OpenAI format.

#### GET /v1/models

```bash
curl -H "Authorization: Bearer $OLLAMA_API_KEY" \
  https://ollama.com/v1/models
```

**Response (OpenAI format):**

```json
{
  "object": "list",
  "data": [
    {
      "id": "gpt-oss:120b",
      "object": "model",
      "created": 1722816000,
      "owned_by": "ollama"
    }
  ]
}
```

> **Live testing note (Sep 2026):** the cloud catalog is **bare** — each entry
> carries only `id`, `object`, `created`, `owned_by` (the doc's original
> `"owned_by": "library"` is what local daemons report; the cloud says
> `"ollama"`). No pricing, context window, or capability metadata. Capability
> and context-length info is only available via the native `/api/show` endpoint
> (section 6.4). This endpoint also works **without authentication** (HTTP 200
> with no API key); only chat/generate requests enforce auth. As of Sep 2026 the
> cloud lists 19 models, several of which are gated behind a subscription (see
> the 402 note in section 6.1).

#### GET /v1/models/{model}

A single model's entry, same shape as the list:

```bash
curl -H "Authorization: Bearer $OLLAMA_API_KEY" \
  https://ollama.com/v1/models/gpt-oss:20b
```

```json
{
  "id": "gpt-oss:20b",
  "object": "model",
  "created": 1754352000,
  "owned_by": "ollama"
}
```

#### POST /v1/completions

```bash
curl -H "Authorization: Bearer $OLLAMA_API_KEY" \
  -H "Content-Type: application/json" \
  https://ollama.com/v1/completions \
  -d '{
    "model": "gpt-oss:120b",
    "prompt": "The sky is blue because",
    "stream": false
  }'
```

**Response:**

```json
{
  "id": "cmpl-343",
  "object": "text_completion",
  "created": 1788158573,
  "model": "gpt-oss:120b",
  "system_fingerprint": "fp_ollama",
  "choices": [
    {
      "text": "...",
      "index": 0,
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 5,
    "completion_tokens": 483,
    "total_tokens": 488
  }
}
```

#### POST /v1/embeddings

```bash
curl -H "Authorization: Bearer $OLLAMA_API_KEY" \
  -H "Content-Type: application/json" \
  https://ollama.com/v1/embeddings \
  -d '{"model": "gpt-oss:120b", "input": "Why is the sky blue?"}'
```

> **Note:** Returned empty results in live cloud testing. Use an
> embedding-specific model (e.g. `nomic-embed-text`) on the local daemon for
> reliable embeddings.

#### OpenAI-compatible streaming

Streaming uses standard SSE `data:` lines:

```
data: {"id":"chatcmpl-48","object":"chat.completion.chunk","created":1788158507,"model":"gpt-oss:120b","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"role":"assistant","content":"","reasoning":"User"},"finish_reason":null}]}

data: {"id":"chatcmpl-48","object":"chat.completion.chunk","created":1788158507,"model":"gpt-oss:120b","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"content":"","reasoning":" asks"},"finish_reason":null}]}

data: {"id":"chatcmpl-48","object":"chat.completion.chunk","created":1788158507,"model":"gpt-oss:120b","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"content":"1"},"finish_reason":null}]}

data: [DONE]
```

> Note: Both `content` (the answer) and `reasoning` (the thinking) are streamed
> as separate delta fields.

#### Streaming usage (`stream_options`)

Passing `"stream_options": {"include_usage": true}` makes the server emit a
final usage chunk before `data: [DONE]` — an OpenAI-compatible convention:

```
data: {"id":"chatcmpl-34","object":"chat.completion.chunk","created":1788158507,"model":"gpt-oss:20b","system_fingerprint":"fp_ollama","choices":[],"usage":{"prompt_tokens":68,"completion_tokens":5,"total_tokens":73}}

data: [DONE]
```

> **Live testing note (Sep 2026):** confirmed working on the cloud. The usage
> chunk carries an **empty `choices` array** (`"choices":[]`), not `null` —
> parsers that assume a first choice must tolerate that. Without
> `stream_options`, no usage is delivered in streaming mode at all.

#### Parameter handling (cloud, Sep 2026 live tests)

> **Unknown parameters are silently ignored** (HTTP 200, request succeeds) —
> e.g. sending a bogus top-level key does not error.
>
> **`thinking`/`think` and `reasoning_effort` do not suppress reasoning on the
> cloud OpenAI-compatible endpoint.** Live tests on `gpt-oss:20b` and
> `gpt-oss:120b` (Sep 2026): sending `"thinking": false`,
> `"reasoning_effort": "low"`, or the native `"think": false` still produced a
> `reasoning`/`thinking` field in the response. The fields are accepted, not
> rejected — but treat "disable reasoning" as unverified on cloud. Local-daemon
> behavior may differ.

#### Subscription gating (HTTP 402)

> Models above the free tier are **listed in the catalog but rejected at request
> time** with HTTP 402 and a readable body (Sep 2026 live test, `kimi-k3` on a
> free key):
>
> ```json
> {
>   "error": {
>     "message": "this model requires a subscription or extra usage, upgrade for access at https://ollama.com/upgrade or add extra usage at https://ollama.com/settings (ref: ...)",
>     "type": "api_error",
>     "param": null,
>     "code": null
>   }
> }
> ```
>
> `/api/show` and `/api/tags` still return full metadata for gated models, so a
> client can surface capabilities for models the current key cannot run.

---

## 7. Streaming

Streaming is covered in detail in the full API spec above:

- **Native streaming:** Section 6.1 — set `"stream": true` on `/api/chat` or
  `/api/generate`
- **OpenAI-compatible streaming:** Section 6.16 — SSE `data:` lines on
  `/v1/chat/completions`

Both produce newline-delimited JSON chunks with incremental token content.

---

## 8. Integration Examples

### Python (requests)

```python
import os
import requests

# --- Cloud (direct API, no local install) ---
OLLAMA_API_KEY = os.environ["OLLAMA_API_KEY"]
BASE_URL = "https://ollama.com/api"

# --- OR local daemon (free) ---
# OLLAMA_API_KEY = None
# BASE_URL = "http://localhost:11434"

headers = {}
if OLLAMA_API_KEY:
    headers["Authorization"] = f"Bearer {OLLAMA_API_KEY}"

response = requests.post(
    f"{BASE_URL}/api/chat",
    headers=headers,
    json={
        "model": "llama3.1",          # or "gpt-oss:120b-cloud" for cloud models
        "messages": [
            {"role": "user", "content": "Why is the sky blue?"}
        ],
        "stream": False
    }
)

data = response.json()
print(data["message"]["content"])
```

### Python (streaming)

```python
import os
import requests
import json

BASE_URL = "https://ollama.com/api"   # or http://localhost:11434
headers = {"Authorization": f"Bearer {os.environ['OLLAMA_API_KEY']}"}

with requests.post(
    f"{BASE_URL}/api/chat",
    headers=headers,
    stream=True,
    json={
        "model": "llama3.1",
        "messages": [{"role": "user", "content": "Tell me a story"}],
        "stream": True
    }
) as response:
    for line in response.iter_lines():
        if line:
            chunk = json.loads(line)
            print(chunk["message"]["content"], end="", flush=True)
```

### Python (OpenAI SDK — drop-in compatible)

```python
from openai import OpenAI

# Point the OpenAI client at Ollama
client = OpenAI(
    base_url="https://ollama.com/v1",           # cloud
    # base_url="http://localhost:11434/v1",      # local
    api_key=os.environ["OLLAMA_API_KEY"],           # or "ollama" for local
)

response = client.chat.completions.create(
    model="llama3.1",
    messages=[{"role": "user", "content": "Why is the sky blue?"}],
)

print(response.choices[0].message.content)
```

### Node.js / JavaScript

```javascript
// --- Using fetch (native) ---
const BASE_URL = "https://ollama.com/api"; // or http://localhost:11434
const API_KEY = process.env.OLLAMA_API_KEY;

const response = await fetch(`${BASE_URL}/api/chat`, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    ...(API_KEY && { Authorization: `Bearer ${API_KEY}` }),
  },
  body: JSON.stringify({
    model: "llama3.1",
    messages: [{ role: "user", content: "Why is the sky blue?" }],
    stream: false,
  }),
});

const data = await response.json();
console.log(data.message.content);
```

### Node.js (OpenAI SDK)

```javascript
import OpenAI from "openai";

const client = new OpenAI({
  baseURL: "https://ollama.com/v1", // or http://localhost:11434/v1
  apiKey: process.env.OLLAMA_API_KEY, // or "ollama" for local
});

const response = await client.chat.completions.create({
  model: "llama3.1",
  messages: [{ role: "user", content: "Why is the sky blue?" }],
});

console.log(response.choices[0].message.content);
```

### cURL

```bash
# Cloud (direct API)
curl -H "Authorization: Bearer $OLLAMA_API_KEY" \
  https://ollama.com/api/chat \
  -d '{"model":"llama3.1","messages":[{"role":"user","content":"Hi"}],"stream":false}'

# Local daemon (free, no auth)
curl http://localhost:11434/api/chat \
  -d '{"model":"llama3.1","messages":[{"role":"user","content":"Hi"}],"stream":false}'
```

---

## 9. Available Models

Browse all models at https://ollama.com/library

Popular choices:

| Model              | Size    | Good for          |
| ------------------ | ------- | ----------------- |
| llama3.1           | 8B      | General chat      |
| llama3.1:70b       | 70B     | High-quality chat |
| mistral            | 7B      | General chat      |
| phi3               | 3.8B    | Lightweight, fast |
| gemma2             | 9B/27B  | General chat      |
| deepseek-r1        | 7B-671B | Reasoning         |
| qwen2.5-coder      | 7B-32B  | Coding            |
| nomic-embed-text   | 137M    | Embeddings        |
| gpt-oss:120b-cloud | 120B    | Cloud-only, large |

On the local daemon, cloud-hosted models carry a `-cloud` suffix (e.g.
`gpt-oss:120b-cloud`) and proxy through Ollama Cloud. On the **direct cloud
API** the suffix is not used — the plain name (`gpt-oss:120b`) works, and the
suffixed name is also accepted (both verified live, Sep 2026).

> **Live testing note (Sep 2026):** the cloud catalog returned by `/v1/models`
> and `/api/tags` (19 models) contains no `-cloud` names; it lists models like
> `gpt-oss:20b`, `gemma4:31b`, `glm-5.3`, `deepseek-v4-pro:0813`, `kimi-k3`,
> `mistral-large-3:675b`, `qwen3.5:397b` — i.e. the hosted fleet, not the
> local-pullable library. Some require a subscription (HTTP 402; see section
> 6.16).

To pull a model locally:

```bash
ollama pull llama3.1
ollama pull deepseek-r1:8b
```

---

## 10. Quick Start: Cloud API Only (No Local Install)

```bash
# 1. Sign up at https://ollama.com
# 2. Create an API key at https://ollama.com/settings/keys
# 3. Set it as an environment variable
export OLLAMA_API_KEY="your-api-key-here"

# 4. Test it
curl -H "Authorization: Bearer $OLLAMA_API_KEY" \
  https://ollama.com/api/chat \
  -d '{
    "model": "llama3.1",
    "messages": [{"role": "user", "content": "Say hello!"}],
    "stream": false
  }'

# 5. List available models
curl -H "Authorization: Bearer $OLLAMA_API_KEY" \
  https://ollama.com/api/tags
```

---

## 11. Quick Start: Local Daemon (Free)

```bash
# 1. Install Ollama CLI (MIT licensed, open source)
#    macOS:   brew install ollama
#    Linux:   curl -fsSL https://ollama.com/install.sh | sh
#    Windows: Download from https://github.com/ollama/ollama/releases

# 2. Start the server
ollama serve

# 3. Pull a model
ollama pull llama3.1

# 4. Test the API (no auth needed for local)
curl http://localhost:11434/api/chat \
  -d '{
    "model": "llama3.1",
    "messages": [{"role": "user", "content": "Say hello!"}],
    "stream": false
  }'

# 5. List models
curl http://localhost:11434/api/tags
```

---

## 12. Key Takeaways

1. **You do NOT need to install Ollama locally** to use their cloud API. Sign
   up, get an API key, and call `https://ollama.com/api` directly.

2. **The core CLI/daemon is MIT licensed** (open source, permissive, commercial
   use OK). The desktop GUI app is proprietary/closed source — but you don't
   need it for API integration.

3. **The API is identical** whether local or cloud — same endpoints, same
   request/response format. Only the base URL and auth header differ.

4. **OpenAI-compatible endpoints** are available (`/v1/chat/completions`) so any
   existing OpenAI client library works with minimal changes.

5. **Pricing:** Free tier for light cloud + unlimited local use. Pro
   ($20/mo)
   for heavier cloud workloads. Max ($100/mo, currently paused for
   new signups).

6. **For your app:** Use the direct cloud API with a Bearer token if you want a
   hosted provider. Use the local daemon if you want free, private, on-device
   inference. Switch between them by changing the base URL and auth header.

---

## 13. Why Did They Make the Desktop App Proprietary?

When Ollama launched in 2023, everything was MIT-licensed open source. In
mid-2025, they introduced a new desktop GUI app — and kept it closed source. The
community noticed and pushed back. Here's why they likely did it:

### A. Monetization strategy

Ollama is a company, not just a project. They need to make money. The sequence
suggests a deliberate strategy:

1. Build an open-source tool that gains massive adoption (the CLI/daemon)
2. Once you have users, introduce cloud services (the monetization vector)
3. Make the GUI app the primary gateway to those cloud services
4. Keep the GUI closed source so competitors can't easily replicate the polished
   onboarding, cloud billing, and account management experience

The GUI is effectively the **productized layer** on top of the open-source core.
By keeping it proprietary, Ollama controls the user experience, cloud
authentication, subscription management, and billing — the parts that generate
revenue.

### B. Controlling the cloud funnel

The GUI app is tightly integrated with ollama.com accounts, cloud model access,
and subscription tiers. If the GUI were open source, competitors could fork it,
strip out the cloud billing, and redirect users to their own services —
undercutting Ollama's business model.

### C. Common industry pattern

This is a well-known strategy: **open-source the core, proprietary the
product.** Examples:

| Project | Open core     | Proprietary layer           |
| ------- | ------------- | --------------------------- |
| Docker  | Docker Engine | Docker Desktop (later)      |
| MongoDB | Core DB       | Cloud / Enterprise features |
| GitLab  | CE            | Premium / Ultimate tiers    |
| Ollama  | CLI + daemon  | Desktop GUI + Cloud         |

### D. Community reaction

The decision was controversial:

- **Supporters** argue: the CLI/daemon is still MIT, the GUI is a convenience
  layer, and companies need to monetize to survive. Nobody is forced to use the
  GUI.
- **Critics** argue: it's a bait-and-switch. Ollama built adoption on an
  open-source ethos, then introduced closed-source components and cloud lock-in.
  Some have called for migration to fully open alternatives like `llama.cpp`
  directly, or tools like Jan.

Relevant discussions:

- Reddit: https://www.reddit.com/r/LocalLLaMA/comments/1meeyee/
- Hacker News: https://news.ycombinator.com/item?id=44739632
- Sleeping Robots critique: https://sleepingrobots.com/dreams/stop-using-ollama/

### E. What this means for developers

The good news: **you don't need the proprietary GUI.** The MIT-licensed CLI and
daemon are all you need to:

- Run models locally (free)
- Expose the REST API
- Proxy to Ollama Cloud if you sign in via CLI

The proprietary GUI is an end-user convenience tool, not a developer
requirement.

---

## 14. Why Does Ollama Need My Phone Number?

Ollama requires phone number verification when creating an ollama.com account
(for cloud access). This is an **anti-abuse measure**, not a developer
requirement.

### A. Preventing free-tier abuse

Ollama Cloud has a free tier with limited compute. Without phone verification,
anyone could create unlimited accounts to bypass usage limits and hoard free
cloud GPU time. Phone verification raises the cost of creating fake accounts.

A security researcher documented this exact vulnerability (GitHub issue
[#15840](https://github.com/ollama/ollama/issues/15840)): Ollama's phone
verification was sporadic and could be bypassed, allowing unlimited account
registration and cloud resource abuse.

### B. Standard cloud provider practice

Phone verification is common among cloud providers with free tiers:

| Service      | Phone verification? |
| ------------ | ------------------- |
| OpenAI       | Yes                 |
| Google Cloud | Yes                 |
| AWS          | Yes                 |
| Azure        | Yes                 |
| Ollama Cloud | Yes                 |

It's not unique to Ollama — it's the industry norm for services offering free
compute.

### C. Current limitation: inconsistent international number support

As of 2026, Ollama's phone verification is **inconsistent across countries**. It
is not accurate to say "US numbers only" — some international numbers work (e.g.
Thai numbers have been confirmed to work), while many others do not. The
behavior appears to depend on the underlying SMS provider (WorkOS's Radar SMS)
rather than a deliberate country allowlist on Ollama's part.

GitHub issue [#16060](https://github.com/ollama/ollama/issues/16060) tracks this
problem. As of August 2026 it is still open, with users from Germany, UK, Spain,
Israel, Australia, Iran, France, Vietnam, Zimbabwe, Pakistan, and others all
reporting blocked signups — yet some non-US numbers (e.g. Thai) do go through.
The inconsistency makes it hard to predict whether any given country will work.

- This is a known limitation that Ollama has not yet resolved.
- Workarounds (like SMS verification services) exist but are fragile and against
  the spirit of the verification.

### D. Do you need a phone number?

| Use case                            | Phone number required?  |
| ----------------------------------- | ----------------------- |
| Local daemon only (free)            | No                      |
| Direct cloud API (free tier)        | Yes (to create account) |
| Direct cloud API (paid tier)        | Yes (to create account) |
| Local daemon + CLI sign-in to cloud | Yes (to create account) |

You only need a phone number if you want to use **Ollama Cloud**. If you're
running models locally with the MIT-licensed CLI, no account or phone number is
needed at all.

---

## 15. Summary: Should You Use Ollama as a Provider?

### Use Ollama if:

- You want a free, local, private LLM provider (CLI/daemon, MIT licensed)
- You want a cloud provider with generous free tier and OpenAI-compatible API
- You want to switch between local and cloud with minimal code changes
- You're OK with phone verification for cloud access (inconsistent international
  support — some countries work, many don't, as of 2026)

### Consider alternatives if:

- You need a fully open-source stack (GUI included) — look at Jan, Open WebUI
- You're in a country whose phone numbers are rejected by Ollama's SMS
  verification — check GitHub issue #16060 for reports from your country, or
  test it yourself; coverage is inconsistent, not US-only
- You're uncomfortable with the closed-source GUI direction — use the CLI only,
  or use `llama.cpp` directly
- You need guaranteed SLA / enterprise support — look at OpenAI, Anthropic, or
  cloud providers like Together AI, Groq, Fireworks

### Bottom line for app developers

Ollama's **API is excellent and easy to integrate**. The MIT-licensed CLI/daemon
is fully open source and works great as a local provider. The cloud API is a
viable hosted option with a free tier. The proprietary GUI and phone
verification are end-user/consumer concerns that don't affect API integration.

For your app:

1. **Start local** — install the MIT CLI, run `ollama serve`, call
   `localhost:11434`. Free, private, no account needed.
2. **Add cloud when needed** — sign up at ollama.com, get an API key, point your
   app at `https://ollama.com/api`. Same API, just different base URL and a
   Bearer token.
3. **Skip the GUI** — you don't need it. The CLI and API are all you need.
