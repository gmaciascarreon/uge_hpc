#!/bin/bash
# Gateway helper, run by socat for each connection to public port 2200+N on
# the jupyter node: forwards the connection to the worker running session N.
# With no active session the connection is simply closed.
SLOT_FILE=${VSCODE_REMOTE_DIR:-/opt/apps/vscode-remote}/slots/$1

[ -f "$SLOT_FILE" ] || exit 0
read -r host port _ < "$SLOT_FILE"
exec socat STDIO "TCP:$host:$port"
