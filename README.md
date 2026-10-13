# Zed Remote Open (`zed .` over SSH)

Opens a Zed remote project from a remote SSH session, similar to `code .` with VS Code.

Built on top of [Zed's native remote development](https://zed.dev/docs/remote-development), which already supports `zed ssh://host/path` from the local CLI. This just bridges the gap so you can run `zed .` from the remote side too.

## How it works

```
You (SSH'd into my-server)
  │
  │  zed .
  │
  ▼
~/.local/bin/zed (on my-server)
  │  Sends "my-server:/current/dir-or-file" to localhost:7682
  │
  ▼
SSH Reverse Tunnel (RemoteForward 7682)
  │  Forwards remote:7682 → local Mac:7682
  │
  ▼
~/.local/bin/zed-listener (on Mac, launchd service)
  │  Receives request, runs: zed ssh://my-server/current/dir-or-file
  │
  ▼
Zed opens with a remote SSH project at that directory
```

## Usage

From an SSH session on your remote server:

```bash
zed .           # open current directory in Zed
zed /some/path  # open specific path in Zed
zed file.py     # open that file directly in Zed
zed             # same as zed .
```

## All files

### Local Mac

#### 1. `~/.local/bin/zed-listener`

Python TCP server. Listens on port 7682 for `host:path` messages (absolute file or directory) and opens Zed remote projects.

```python
#!/usr/bin/env python3
"""Listener that opens Zed remote projects from SSH sessions.

Runs on the local Mac. Remote machines send requests via SSH reverse
port forwarding to open a Zed remote project at a specific directory.

Protocol: single line "host:path\n" over TCP, where path is an absolute file or directory.
"""

# The launchd job runs under /usr/bin/python3, which is Python 3.9 on macOS.
# PEP 604 unions (str | None) are 3.10+ syntax, so keep annotations lazy.
from __future__ import annotations

import os
import shutil
import signal
import socket
import subprocess
import sys

PORT = 7682

# launchd starts us with a minimal PATH, so `shutil.which` on its own is not
# reliable: it misses Homebrew installs, and Apple Silicon puts them under
# /opt/homebrew/bin rather than /usr/local/bin. Probe PATH first, then fall back
# to the known install locations. Override with the ZED_CLI env var.
ZED_CLI_FALLBACKS: tuple[str, ...] = (
    "/opt/homebrew/bin/zed",
    "/usr/local/bin/zed",
    "/Applications/Zed.app/Contents/MacOS/cli",
)


def resolve_zed_cli() -> str | None:
    """Return the path to the Zed CLI, or None if it cannot be found."""
    override: str | None = os.environ.get("ZED_CLI")
    if override:
        return override

    on_path: str | None = shutil.which("zed")
    if on_path:
        return on_path

    for candidate in ZED_CLI_FALLBACKS:
        if os.access(candidate, os.X_OK):
            return candidate

    return None


ZED_CLI: str | None = resolve_zed_cli()


def log(message: str) -> None:
    """Write a diagnostic line to stderr, which the launchd job captures."""
    print(f"zed-listener: {message}", file=sys.stderr, flush=True)


def handle_request(data: str) -> None:
    """Parse one request and open it as a Zed remote project."""
    data = data.strip()
    if ":" not in data:
        log(f"ignoring malformed request (no ':'): {data!r}")
        return

    host, directory = data.split(":", 1)
    if not host or not directory:
        log(f"ignoring malformed request (empty host or path): {data!r}")
        return

    if ZED_CLI is None:
        log("cannot find the Zed CLI; install Zed or set ZED_CLI in the plist")
        return

    url = f"ssh://{host}{directory}"
    try:
        subprocess.Popen([ZED_CLI, url])
        log(f"opened {url}")
    except OSError as exc:
        log(f"failed to launch {ZED_CLI} for {url}: {exc}")


def main() -> None:
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", PORT))
    sock.listen(5)

    log(f"listening on 127.0.0.1:{PORT}")
    log(f"zed cli: {ZED_CLI or 'NOT FOUND'}")
    if ZED_CLI is None:
        log("requests will be rejected until the Zed CLI is available")

    while True:
        conn, _ = sock.accept()
        try:
            data = conn.recv(4096).decode("utf-8", errors="replace")
            handle_request(data)
        # Deliberately broad: this is a network server, so one bad connection
        # must never take the listener down. Failures are logged, not swallowed.
        except Exception as exc:  # noqa: BLE001
            log(f"error while handling request: {exc!r}")
        finally:
            conn.close()


if __name__ == "__main__":
    main()
```

#### 2. `~/Library/LaunchAgents/com.zed.remote-listener.plist`

Launchd service that auto-starts `zed-listener` on login and keeps it running.

`__HOME__` is a placeholder that `install-local.sh` replaces with your actual home
directory. launchd does not expand environment variables, so the absolute path
must be baked into the plist at install time.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.zed.remote-listener</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>__HOME__/.local/bin/zed-listener</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/zed-listener.err</string>
</dict>
</plist>
```

## Install (local Mac)

```bash
./install-local.sh
```

This copies `zed-listener` to `~/.local/bin/`, renders the plist with your home
directory, installs it to `~/Library/LaunchAgents/`, loads the launchd job, and
verifies that something is actually listening on port 7682.

#### 3. `~/.ssh/config` (relevant addition)

The `RemoteForward` line creates a reverse tunnel: anything connecting to port 7682 on the remote server gets forwarded back to port 7682 on your Mac.

```
Host my-server
    HostName <ip-or-hostname>
    User <username>
    RemoteForward 7682 127.0.0.1:7682
```

### Remote server

#### 4. `~/.local/bin/zed`

The command you actually type. Resolves the target (file or directory) to an absolute path and sends it through the reverse tunnel via netcat.

```bash
#!/bin/bash
# Open a Zed remote project on the local machine via reverse SSH tunnel.
# Usage: zed [path]  (file or directory; defaults to current directory)
#
# ZED_SSH_HOST must be set to the SSH config alias for this server.
# Set it in your shell config, e.g.: export ZED_SSH_HOST="my-server"

target="${1:-.}"
if [ -f "$target" ]; then
    dir=$(cd "$(dirname "$target")" 2>/dev/null && pwd) || { echo "zed: cannot access '$1'"; exit 1; }
    path="$dir/$(basename "$target")"
else
    path=$(cd "$target" 2>/dev/null && pwd) || { echo "zed: cannot access '$1'"; exit 1; }
fi

host="${ZED_SSH_HOST:-$(hostname)}"

echo "${host}:${path}" | nc -q0 127.0.0.1 7682 2>/dev/null
if [ $? -ne 0 ]; then
    echo "zed: could not connect to local listener on port 7682" >&2
    echo "  Make sure zed-listener is running and SSH has RemoteForward 7682" >&2
    exit 1
fi
echo "Opening Zed at $path"
```

## Adding another server

1. Add `RemoteForward 7682 127.0.0.1:7682` to that host in `~/.ssh/config`
2. Copy `zed-remote` to `~/.local/bin/zed` on the remote server
3. Set `export ZED_SSH_HOST="<ssh-alias>"` in the server's `.bashrc`

## Troubleshooting

**`zed .` prints "Opening Zed at ..." but nothing opens**

This is the silent failure mode: the remote `nc` connects to the reverse tunnel's
listening socket, so it exits 0, but the final hop to `127.0.0.1:7682` on your Mac
is refused and the request is dropped. It almost always means the launchd job is
crash-looping (typically a wrong path in the plist).

```bash
launchctl list | grep com.zed.remote-listener   # PID column should not be "-"
lsof -nP -iTCP:7682 -sTCP:LISTEN                # should show Python listening
cat /tmp/zed-listener.err                       # shows the real crash reason
```

**`zed: could not connect to local listener on port 7682`**
- Check the listener is running: `ps aux | grep zed-listener`
- Restart it: `launchctl kickstart -k gui/$(id -u)/com.zed.remote-listener`
- Check logs: `cat /tmp/zed-listener.err`
- Reinstall cleanly: `./install-local.sh`

**`Warning: remote port forwarding failed for listen port 7682`**
- Harmless. Means another SSH session already has the tunnel. The existing tunnel still works.

**Zed opens but doesn't connect**
- Test directly: `zed ssh://your-host/home/user`
- Make sure Zed's remote development is working (see [Zed docs](https://zed.dev/docs/remote-development))

## Why it works this way

Zed already supports `zed ssh://host/path` natively, so the listener just calls that directly. No helper scripts needed on the local side.

The listener resolves the Zed CLI at startup: it checks `PATH` first, then falls
back to the known install locations (`/opt/homebrew/bin/zed`, `/usr/local/bin/zed`,
`/Applications/Zed.app/Contents/MacOS/cli`). The fallback matters because launchd
runs with a minimal PATH — `shutil.which` alone would come up empty there, and
Apple Silicon Homebrew installs to `/opt/homebrew/bin`, not `/usr/local/bin`. Set
`ZED_CLI` to override.

The listener also logs every request to stderr, which the launchd job captures in
`/tmp/zed-listener.err`. It used to swallow failures silently, which is what made
the broken-plist bug so hard to track down.

Port 7682 (one above the Ghostty listener at 7681). Change it in the listener, SSH config, and remote script if needed.
