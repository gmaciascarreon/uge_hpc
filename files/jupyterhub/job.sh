#!/bin/bash
#$ -S /bin/bash
# JupyterHub user server, run as a Grid Engine job on a worker node by the
# GridEngineSpawner (files/jupyterhub_config.py).
#
#   job.sh <lab|vscode> <env file> <address file>
#
# Loads the Hub environment (API token, URLs) from <env file>, picks a free
# port, publishes "<host> <port>" in <address file> for the Hub, then serves:
#   lab    - jupyterhub-singleuser (JupyterLab)
#   vscode - code-server behind jupyter-standaloneproxy (Hub login, no
#            Jupyter), plus the Remote-SSH endpoint from
#            /opt/apps/vscode-remote/session.sh for the local VS Code.
set -euo pipefail

MODE=$1
ENV_FILE=$2
ADDR_FILE=$3

set +u # settings.sh reads variables that may be unset (MANPATH, ...)
. "${SGE_ROOT:-/opt/ocs}/${SGE_CELL:-default}/common/settings.sh"
. "$ENV_FILE"
set -u
rm -f "$ENV_FILE" # holds the Hub API token; it is in our environment now

export PATH=/opt/apps/jupyter/bin:/opt/apps/code-server/bin:$PATH
cd "$HOME"

PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("", 0)); print(s.getsockname()[1])')
echo "$(hostname) $PORT" > "$ADDR_FILE.tmp"
mv "$ADDR_FILE.tmp" "$ADDR_FILE"

case $MODE in
  lab)
    exec jupyterhub-singleuser --ip=0.0.0.0 --port="$PORT"
    ;;
  vscode)
    INFO_FILE=$HOME/vscode-remote/session-$JOB_ID.md
    mkdir -p "$HOME/vscode-remote"
    VSCODE_INFO_FILE=$INFO_FILE /opt/apps/vscode-remote/session.sh &
    SESSION_PID=$!
    trap 'kill $SESSION_PID 2>/dev/null || true; rm -f "$INFO_FILE"' EXIT

    # Wait for the Remote-SSH endpoint to claim its slot and write the
    # connection details, which code-server opens on start.
    for _ in $(seq 60); do
      [ -f "$INFO_FILE" ] && break
      kill -0 "$SESSION_PID" 2>/dev/null || { echo "Remote-SSH session failed to start" >&2; exit 1; }
      sleep 1
    done

    jupyter-standaloneproxy --address=0.0.0.0 --port="$PORT" --timeout=120 -- \
      code-server --auth none --bind-addr "127.0.0.1:{port}" \
      --disable-telemetry --disable-update-check "$INFO_FILE"
    ;;
  *)
    echo "unknown mode: $MODE" >&2
    exit 2
    ;;
esac
