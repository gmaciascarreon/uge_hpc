# JupyterHub configuration for the uge_hpc cluster.
#
# The spawn form offers two choices:
#   - JupyterLab: a normal single-user server on this node.
#   - VS Code Remote: submits a Grid Engine job (session.sh) that runs a
#     user-mode sshd on a worker. The local VS Code connects to it with
#     Remote-SSH through public port 2200+N; the single-user server started
#     here only shows the connection details.
import asyncio
import html
import os
import pwd
import re
import subprocess

PUBLIC_IP = os.environ["JUPYTERHUB_PUBLIC_IP"]
MAX_SESSIONS = int(os.environ.get("VSCODE_MAX_SESSIONS", "5"))
APP_DIR = "/opt/apps/vscode-remote"
SLOTS_DIR = f"{APP_DIR}/slots"
START_WAIT_SECONDS = 120

c.JupyterHub.bind_url = "https://:443"
c.JupyterHub.ssl_cert = "/etc/jupyterhub/ssl/cert.pem"
c.JupyterHub.ssl_key = "/etc/jupyterhub/ssl/key.pem"
c.JupyterHub.allow_named_servers = True

c.Authenticator.allowed_users = {"ec2-user"}
c.Authenticator.admin_users = {"ec2-user"}

c.Spawner.default_url = "/lab"
c.Spawner.cmd = ["/opt/jupyterhub/bin/jupyterhub-singleuser"]
c.Spawner.start_timeout = START_WAIT_SECONDS + 60
c.Spawner.environment = {
    "SGE_ROOT": "/opt/ocs",
    "SGE_CELL": "default",
    "SGE_CLUSTER_NAME": "p6444",
}

c.Spawner.options_form = f"""
<div class="form-group">
  <label><input type="radio" name="ui" value="lab" checked>
    <b>JupyterLab</b> &mdash; notebooks, terminals and the browser VS Code on the jupyter node</label>
</div>
<div class="form-group">
  <label><input type="radio" name="ui" value="vscode-remote">
    <b>VS Code Remote</b> &mdash; a Grid Engine job on a worker node that your local
    VS Code connects to with Remote-SSH (max {MAX_SESSIONS} sessions, one port each)</label>
</div>
"""


def options_from_form(formdata):
    ui = formdata.get("ui", ["lab"])[0]
    return {"ui": ui if ui in ("lab", "vscode-remote") else "lab"}


c.Spawner.options_from_form = options_from_form


def job_name(spawner):
    server = re.sub(r"[^A-Za-z0-9_-]", "-", spawner.name or "default")
    return f"vsc-{server}"


def as_user_cmd(user, command):
    # Login shell so /etc/profile.d/ocs.sh sets up the Grid Engine environment.
    return ["runuser", "-u", user, "--", "bash", "-lc", command]


async def run_as(user, command):
    proc = await asyncio.create_subprocess_exec(
        *as_user_cmd(user, command),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    out, err = await proc.communicate()
    return proc.returncode, out.decode().strip(), err.decode().strip()


def find_slot(job_id):
    """Return (slot, host, port) of the session published by job_id, if any."""
    for n in range(1, MAX_SESSIONS + 1):
        try:
            with open(f"{SLOTS_DIR}/{n}") as f:
                host, port, owner = f.read().split()[:3]
        except (OSError, ValueError):
            continue
        if owner == job_id:
            return n, host, int(port)
    return None


def write_session_page(user, name, job_id, slot, host):
    public_port = 2200 + slot
    alias = f"hpc-vscode-{slot}"
    ssh_config = (
        f"Host {alias}\n"
        f"  HostName {PUBLIC_IP}\n"
        f"  Port {public_port}\n"
        f"  User {user}\n"
        f"  IdentityFile ~/.ssh/uge_hpc\n"
    )
    page = f"""<!doctype html>
<html><head><meta charset="utf-8"><title>VS Code Remote session {slot}</title>
<style>body{{font-family:sans-serif;max-width:46rem;margin:2rem auto;padding:0 1rem;line-height:1.5}}
pre{{background:#f4f4f4;padding:1rem;overflow-x:auto}}td{{padding:.2rem 1rem .2rem 0}}</style></head>
<body>
<h1>VS Code Remote session {slot}</h1>
<table>
<tr><td>Connect to</td><td><b>{html.escape(PUBLIC_IP)}:{public_port}</b></td></tr>
<tr><td>User</td><td>{html.escape(user)}</td></tr>
<tr><td>Runs on</td><td>{html.escape(host)} (Grid Engine job {html.escape(job_id)})</td></tr>
</table>
<h2>Connect from your local VS Code</h2>
<ol>
<li>Install the <b>Remote - SSH</b> extension.</li>
<li>Add this to your local <code>~/.ssh/config</code>:
<pre>{html.escape(ssh_config)}</pre></li>
<li>Run <b>Remote-SSH: Connect to Host&hellip;</b> and pick <code>{alias}</code>.</li>
</ol>
<p>Test from a terminal: <code>ssh {alias} hostname</code> should print <code>{html.escape(host)}</code>.</p>
<p>The session lasts until you stop this server from the Hub Control Panel
(<b>File &rarr; Hub Control Panel</b>), which deletes the job.</p>
</body></html>
"""
    pw = pwd.getpwnam(user)
    directory = os.path.join(pw.pw_dir, "vscode-remote")
    os.makedirs(directory, exist_ok=True)
    os.chown(directory, pw.pw_uid, pw.pw_gid)
    path = os.path.join(directory, f"{name}.html")
    with open(path, "w") as f:
        f.write(page)
    os.chown(path, pw.pw_uid, pw.pw_gid)
    return f"/files/vscode-remote/{name}.html"


async def pre_spawn_hook(spawner):
    if spawner.user_options.get("ui") != "vscode-remote":
        spawner.default_url = "/lab"
        return

    user = spawner.user.name
    name = job_name(spawner)
    # Remove a leftover job from an earlier start of this server.
    await run_as(user, f"qdel {name}")

    rc, out, err = await run_as(
        user,
        f"mkdir -p ~/vscode-remote && qsub -terse -N {name} -l vscode=1 -j y "
        f"-o ~/vscode-remote/{name}.log {APP_DIR}/session.sh",
    )
    if rc != 0 or not out:
        raise RuntimeError(f"Could not submit the VS Code Remote job: {err or out}")
    job_id = out.splitlines()[-1].split(".")[0]

    loop = asyncio.get_running_loop()
    deadline = loop.time() + START_WAIT_SECONDS
    while (session := find_slot(job_id)) is None and loop.time() < deadline:
        await asyncio.sleep(3)
    if session is None:
        await run_as(user, f"qdel {job_id}")
        raise RuntimeError(
            f"All {MAX_SESSIONS} VS Code Remote sessions are in use, or the job did not "
            f"start within {START_WAIT_SECONDS}s. Stop a session and try again."
        )

    slot, host, _ = session
    spawner.default_url = write_session_page(user, name, job_id, slot, host)


def post_stop_hook(spawner):
    # Stopping the server ends its cluster job (a no-op for JupyterLab servers).
    subprocess.run(
        as_user_cmd(spawner.user.name, f"qdel {job_name(spawner)}"),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


c.Spawner.pre_spawn_hook = pre_spawn_hook
c.Spawner.post_stop_hook = post_stop_hook
