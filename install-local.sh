#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Installing zed-listener (local Mac)..."

mkdir -p "$HOME/.local/bin"

cp "$SCRIPT_DIR/zed-listener" "$HOME/.local/bin/zed-listener"
chmod +x "$HOME/.local/bin/zed-listener"

# Install launchd service.
# The plist template uses __HOME__ as a placeholder: launchd does not expand
# environment variables, so the absolute path must be baked in at install time.
sed "s#__HOME__#$HOME#g" \
    "$SCRIPT_DIR/com.zed.remote-listener.plist" \
    > "$HOME/Library/LaunchAgents/com.zed.remote-listener.plist"

# Load/reload the service.
#
# `launchctl bootout` returns before launchd has actually unloaded the job. If we
# bootstrap immediately, it collides with the still-draining job and fails with
# "Bootstrap failed: 5", leaving the service unloaded and port 7682 dead. So wait
# for the job to really disappear first.
LABEL="com.zed.remote-listener"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    for _ in $(seq 1 50); do
        launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
        sleep 0.1
    done
fi

launchctl bootstrap "$DOMAIN" "$PLIST"

echo "==> zed-listener is running."
echo ""
echo "Next steps:"
echo "  1. Add 'RemoteForward 7682 127.0.0.1:7682' to your SSH host in ~/.ssh/config"
echo "  2. Install zed-remote on your server (copy zed-remote to ~/.local/bin/zed)"
echo "  3. Set ZED_SSH_HOST on the server to your SSH config alias"

# Verify the listener is actually bound. KeepAlive silently crash-loops a
# misconfigured service, which breaks `zed` on the remote with no error.
sleep 1
if lsof -nP -iTCP:7682 -sTCP:LISTEN >/dev/null 2>&1; then
    echo ""
    echo "==> Verified: listening on 127.0.0.1:7682"
else
    echo "" >&2
    echo "==> ERROR: nothing is listening on 127.0.0.1:7682" >&2
    echo "    The launchd job is probably crash-looping. Check:" >&2
    echo "      launchctl list | grep com.zed.remote-listener" >&2
    echo "      cat /tmp/zed-listener.err" >&2
    exit 1
fi
