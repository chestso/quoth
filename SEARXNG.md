# Setting up SearXNG for crush.el

crush.el includes a `web_search` tool that queries a local [SearXNG](https://searxng.org) instance over HTTP. The tool is enabled by default and expects the server at `http://127.0.0.1:8888`.

If you already have SearXNG running on that address with the JSON format enabled, no further setup is needed — the model can call `web_search` automatically during a tool round.

If not, this guide walks through installing SearXNG as a local, non-root user with no Docker required.

---

## 1. Install (git + venv) — all platforms

Everything lives under `~/.local/share/searxng`.

```bash
mkdir -p ~/.local/share/searxng/src ~/.local/share/searxng/settings
cd ~/.local/share/searxng/src
git clone --depth 1 https://github.com/searxng/searxng.git

# Create a virtualenv (uv or python -m venv both work)
uv venv ~/.local/share/searxng/venv          # or: python3 -m venv ~/.local/share/searxng/venv

# Install explicit runtime deps first, then the project itself editable.
# The project's build imports searx, so unit deps must already be present.
uv pip install --python ~/.local/share/searxng/venv/bin/python \
    -r ~/.local/share/searxng/src/searxng/requirements.txt

# setuptools is needed for the editable build without build isolation
uv pip install --python ~/.local/share/searxng/venv/bin/python setuptools

# Editable install (official method: --no-build-isolation for the project)
uv pip install --python ~/.local/share/searxng/venv/bin/python \
    --no-build-isolation -e ~/.local/share/searxng/src/searxng
```

If you use plain `pip` instead of `uv`, the equivalent is:

```bash
~/.local/share/searxng/venv/bin/python -m pip install \
    -r ~/.local/share/searxng/src/searxng/requirements.txt
~/.local/share/searxng/venv/bin/python -m pip install setuptools
~/.local/share/searxng/venv/bin/python -m pip install \
    --use-pep517 --no-build-isolation -e ~/.local/share/searxng/src/searxng
```

> **Install reality check:** the real SearXNG is **not** published on PyPI. The `searxng` package on PyPI is an unrelated third-party MCP server. The only supported install paths are: git clone + editable venv install, Docker, or an OS package / install script.

### Prepare the settings file

Copy the shipped defaults and enable the JSON format (required for crush), a loopback bind, and a real secret key.

```bash
cp ~/.local/share/searxng/src/searxng/searx/settings.yml \
   ~/.local/share/searxng/settings/settings.yml
```

Edit `~/.local/share/searxng/settings/settings.yml`:

```yaml
general:
  instance_name: "agent-search"
search:
  formats: # default is [html] only — add json for crush
    - html
    - json
server:
  port: 8888
  bind_address: "127.0.0.1" # loopback only
  limiter: true
  public_instance: false
  secret_key: "<random hex 32>" # MUST change from "ultrasecretkey" — the server refuses to start otherwise
```

Generate a secret key: `python3 -c "import secrets; print(secrets.token_hex(32))"`

On first run the process groups runtime data under `~/.local/share/searxng`. The git-version warning in the logs ("fatal: not a git repository") is cosmetic (harmless) when cloned with `--depth 1`.

---

## 2. Quick test (manual)

```bash
export SEARXNG_SETTINGS_PATH=$HOME/.local/share/searxng/settings
~/.local/share/searxng/venv/bin/python -m searx.webapp
```

Verify in another terminal:

```bash
curl 'http://127.0.0.1:8888/search?q=searxng&format=json'
```

Expect `HTTP 200` and a JSON document with a `"results"` array.

Once the server is running, open `M-x crush` in Emacs and ask the model to search for something. The `web_search` tool fires automatically during a tool round — no extra config needed.

---

## 3. Linux: run as a systemd user service

Survives reboots without root. Enable _linger_ so the service keeps running when you log out.

Create `~/.config/systemd/user/searxng.service`:

```ini
[Unit]
Description=SearXNG metasearch (agentic JSON)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=SEARXNG_SETTINGS_PATH=%h/.local/share/searxng/settings
ExecStart=%h/.local/share/searxng/venv/bin/python -m searx.webapp
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now searxng
systemctl --user status searxng

# keep it running after logout (optional)
loginctl enable-linger "$USER"
```

Logs: `journalctl --user -u searxng -f`

If you prefer a **system** service instead (needs root), place the unit in `/etc/systemd/system/searxng.service`, point paths at a dedicated user/serve dir, and reuse the same `[Service]` block with `User=` set.

---

## 4. macOS: run via launchd

Launchd is the macOS daemon manager. The `%h` in launchd expands to your home directory, which keeps everything user-local.

Create `~/Library/LaunchAgents/local.searxng.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.searxng</string>

  <key>ProgramArguments</key>
  <array>
    <string>/Users/USERNAME/.local/share/searxng/venv/bin/python</string>
    <string>-m</string>
    <string>searx.webapp</string>
  </array>

  <key>EnvironmentVariables</key>
  <dict>
    <key>SEARXNG_SETTINGS_PATH</key>
    <string>/Users/USERNAME/.local/share/searxng/settings</string>
  </dict>

  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
```

> Replace `USERNAME` with your macOS username (paths like `%%h%%/...` are not usable in the plist XML).

```bash
launchctl load ~/Library/LaunchAgents/local.searxng.plist
launchctl start local.searxng
launchctl list | grep searxng   # should show a PID (no "0" status)

# reload after editing the plist
launchctl unload ~/Library/LaunchAgents/local.searxng.plist
launchctl load ~/Library/LaunchAgents/local.searxng.plist
```

Logs: check `~/Library/Logs` or the system log (`log stream --predicate 'process == "python"'`).

---

## 5. Windows: two options

### A. Docker Desktop (simplest)

If you have Docker Desktop, containerize:

```bash
docker run -d --name searxng \
  -p 127.0.0.1:8888:8080/tcp \
  -e SEARXNG_BASE_URL=http://127.0.0.1:8888/ \
  searxng/searxng
```

Enable the JSON format and set a secret key by mounting config (see the [searxng-docker](https://github.com/searxng/searxng-docker) repo for the settings overrides).

### B. Git install under WSL (matches the Linux flow)

Install inside WSL using the common git + venv steps (Section 1) and the systemd user unit (Section 3). Access the JSON endpoint at `http://127.0.0.1:8888` from Windows once WSL port forwarding is working.

> If you want a native Command Prompt service, register the same `python -m searx.webapp` command with NSSM as a Windows service, and set `SEARXNG_SETTINGS_PATH` in the service's environment.

---

## 6. crush.el configuration

The `web_search` tool is announced to the model alongside `exec_command` and `write_stdin` when `crush-searxng-enabled` is non-nil (default `t`). The server URL defaults to `http://127.0.0.1:8888`.

To change the server URL:

```elisp
(setq crush-searxng-base-url "http://127.0.0.1:9999")
```

To disable the tool entirely:

```elisp
(setq crush-searxng-enabled nil)
```

Other options in the `crush-searxng` customize group: `crush-searxng-timeout` (HTTP timeout, default 10s), `crush-searxng-max-results` (default 8).

Keyless engines (Wikipedia, DuckDuckGo) work out of the box. Google, Bing, Brave, and others generally need API keys configured under `engines:` in the SearXNG settings.

---

## 7. Common problems

| Symptom                                                    | Cause / fix                                                                                                                                                                                                    |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Exits immediately: `server.secret_key is not changed`      | You left the default `ultrasecretkey`. Set a random `secret_key` (Section 1).                                                                                                                                  |
| `format=json` returns 403                                  | `json` is not in `search.formats`. Add it.                                                                                                                                                                     |
| Log spam `fatal: not a git repository`                     | Cosmetic; caused by `--depth 1` clone. Safe to ignore.                                                                                                                                                         |
| Some engines error with 403/captcha `(suspended_time=...)` | Normal per-engine rate limiting. Other engines still return results; add API keys for reliable coverage.                                                                                                       |
| `X-Forwarded-For already set` / proxy warnings             | Expected on a plain loopback instance; relevant only when behind a reverse proxy.                                                                                                                              |
| crush reports "SearXNG is unreachable"                     | Server is not running or not on the configured URL. Check `crush-searxng-base-url` and that the server is listening. The tool caches the unreachable state for the session; restart the crush buffer to retry. |

---

**Reference:** https://docs.searxng.org/ and https://docs.searxng.org/dev/search_api.html
