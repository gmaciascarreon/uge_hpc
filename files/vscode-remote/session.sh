#!/bin/bash
# Remote-SSH endpoint of a VS Code session. Started by job.sh inside the
# session's Grid Engine job on a worker node: claims one of the session
# slots, then runs a user-mode sshd on port 22000+N. The gateway on the
# jupyter node forwards public port 2200+N to it, and the local VS Code
# (Remote-SSH) connects through that port. If VSCODE_INFO_FILE is set, the
# connection details are written there (code-server opens that file).
set -euo pipefail

# Jobs don't get a login PATH; load the Grid Engine environment (qstat).
set +u # settings.sh reads variables that may be unset (MANPATH, ...)
. "${SGE_ROOT:-/opt/ocs}/${SGE_CELL:-default}/common/settings.sh"
set -u

APP_DIR=${VSCODE_REMOTE_DIR:-/opt/apps/vscode-remote}
SLOTS_DIR=$APP_DIR/slots
MAX_SESSIONS=$(cat "$APP_DIR/max_sessions")
STATE_DIR=$HOME/vscode-remote
: "${JOB_ID:?must run as a Grid Engine job}"

job_alive() {
  qstat -j "$1" >/dev/null 2>&1
}

take_slot() {
  mkdir "$SLOTS_DIR/$1.lock" 2>/dev/null || return 1
  echo "$JOB_ID" > "$SLOTS_DIR/$1.lock/job"
}

# Prints the claimed slot number. A lock left behind by a job that is no
# longer running (qdel kills with SIGKILL, so cleanup may not run) is reclaimed.
claim_slot() {
  local n owner
  for n in $(seq 1 "$MAX_SESSIONS"); do
    if take_slot "$n"; then
      echo "$n"
      return 0
    fi
    owner=$(cat "$SLOTS_DIR/$n.lock/job" 2>/dev/null || true)
    if [ -n "$owner" ] && [ "$owner" != "$JOB_ID" ] && ! job_alive "$owner"; then
      rm -rf "$SLOTS_DIR/$n.lock" "$SLOTS_DIR/$n"
      if take_slot "$n"; then
        echo "$n"
        return 0
      fi
    fi
  done
  return 1
}

SLOT=$(claim_slot) || {
  echo "No free VS Code Remote slot (all $MAX_SESSIONS in use)" >&2
  exit 1
}
PORT=$((22000 + SLOT))

cleanup() {
  if [ "$(cat "$SLOTS_DIR/$SLOT.lock/job" 2>/dev/null)" = "$JOB_ID" ]; then
    rm -rf "$SLOTS_DIR/$SLOT" "$SLOTS_DIR/$SLOT.lock"
  fi
  rm -rf "$RUN_DIR"
}
RUN_DIR=${TMPDIR:-/tmp}/vscode-remote-$JOB_ID
mkdir -p "$RUN_DIR" "$STATE_DIR"
trap cleanup EXIT
trap 'exit 143' TERM INT

# One host key in the shared home: the same key for every session and node,
# so the local known_hosts entry stays valid across sessions.
HOST_KEY=$STATE_DIR/ssh_host_ed25519_key
[ -f "$HOST_KEY" ] || ssh-keygen -q -t ed25519 -N '' -C vscode-remote -f "$HOST_KEY"

cat > "$RUN_DIR/sshd_config" <<EOF
Port $PORT
ListenAddress 0.0.0.0
HostKey $HOST_KEY
PidFile $RUN_DIR/sshd.pid
AuthorizedKeysFile $HOME/.ssh/authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
AllowTcpForwarding yes
AllowStreamLocalForwarding yes
X11Forwarding no
PrintMotd no
SetEnv JOB_ID=$JOB_ID VSCODE_REMOTE_SLOT=$SLOT
Subsystem sftp /usr/libexec/openssh/sftp-server
EOF

# Publish "<host> <port> <job id>" for the gateway and JupyterHub.
echo "$(hostname) $PORT $JOB_ID" > "$SLOTS_DIR/.$SLOT.tmp.$JOB_ID"
mv "$SLOTS_DIR/.$SLOT.tmp.$JOB_ID" "$SLOTS_DIR/$SLOT"

PUBLIC_PORT=$((2200 + SLOT))
SESSION_USER=$(id -un)
echo "VS Code Remote session: slot $SLOT, $(hostname):$PORT, public port $PUBLIC_PORT"

if [ -n "${VSCODE_INFO_FILE:-}" ]; then
  cat > "$VSCODE_INFO_FILE" <<EOF
# VS Code session $SLOT

This VS Code runs as Grid Engine job **$JOB_ID** on **$(hostname)**.

## Connect from your local VS Code (Remote-SSH)

| | |
|---|---|
| Address | \`${VSCODE_PUBLIC_IP:-<jupyterhub public ip>}:$PUBLIC_PORT\` |
| User | \`$SESSION_USER\` |

1. Install the **Remote - SSH** extension in your local VS Code.
2. Add this to your local \`~/.ssh/config\`:

   \`\`\`
   Host hpc-vscode-$SLOT
     HostName ${VSCODE_PUBLIC_IP:-<jupyterhub public ip>}
     Port $PUBLIC_PORT
     User $SESSION_USER
     IdentityFile ~/.ssh/uge_hpc
   \`\`\`

3. Run **Remote-SSH: Connect to Host...** and pick \`hpc-vscode-$SLOT\`.

Test from a local terminal: \`ssh hpc-vscode-$SLOT hostname\` prints \`$(hostname)\`.

The session ends when you stop this server in the Hub Control Panel
(\`https://${VSCODE_PUBLIC_IP:-<jupyterhub public ip>}/hub/home\`), which deletes the job.
EOF
fi

/usr/sbin/sshd -D -e -f "$RUN_DIR/sshd_config"
