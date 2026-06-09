#!/bin/bash

# tinker
# HOW TO USE : tinker [path]
# path省略時はカレントディレクトリを渡す

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_BIN="$SCRIPT_DIR/build/tinker-server"
BRIDGE_BIN="$SCRIPT_DIR/build/tinker-bridge"
SOCKET_PATH="/tmp/tinker-bridge.sock"
SERVER_PORT=7070
NOTIFY_PORT=7071

# ----- パスの解決 -----
TARGET="${1:-.}"
TARGET="$(realpath "$TARGET")"

if [ ! -d "$TARGET" ]; then
    echo "tinker: '$TARGET' is not a directory" >&2
    exit 1
fi

# ----- tinker-server 起動確認 -----
if [ ! -S "$SOCKET_PATH" ]; then
    echo "tinker: starting tinker-server..."
    nohup "$SERVER_BIN" > /tmp/tinker-server.log 2>&1 &
    # ソケットが作成されるまで待つ
    for i in $(seq 1 20); do
        sleep 0.2
        [ -S "$SOCKET_PATH" ] && break
        if [ "$i" -eq 20 ]; then
            echo "tinker: failed to start tinker-server" >&2
            exit 1
        fi
    done
    echo "tinker: tinker-server started"
fi

# ----- tinker-bridge 起動確認 -----
if ! ss -tlnp 2>/dev/null | grep -q ":$SERVER_PORT "; then
    echo "tinker: starting tinker-bridge..."
    nohup "$BRIDGE_BIN" > /tmp/tinker-bridge.log 2>&1 &
    sleep 0.5
    echo "tinker: tinker-bridge started."
fi

# ----- emacs へ通知 -----
PAYLOAD="{\"op\":\"open-project\",\"path\":\"$TARGET\"}"
if echo "$PAYLOAD" | timeout 3 nc -q1 127.0.0.1 "$NOTIFY_PORT" > /dev/null 2>&1;
then
    echo "tinker: opened '$TARGET' in emacs."
else
    echo "tinker: could not reach emacs (is tinker-global-mode enabled?)" >&2
    echo "tinker: start manually with M-x tinker-start-notify-server" >&2
    exit 1
fi


