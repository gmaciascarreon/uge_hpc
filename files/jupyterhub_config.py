# JupyterHub configuration for the uge_hpc cluster.
#
# The Hub runs on the jupyter node; every user server runs as a Grid Engine
# job on a worker (GridEngineSpawner below). The spawn form offers:
#   - JupyterLab: the job runs jupyterhub-singleuser.
#   - VS Code:    the job runs code-server behind jupyter-standaloneproxy (no
#                 Jupyter server), plus a per-session sshd that the local
#                 VS Code reaches with Remote-SSH on public port 2200+N.
# The job script is /opt/apps/jupyterhub/job.sh (files/jupyterhub/job.sh).
import asyncio
import os
import pwd
import re
import shlex

from jupyterhub.spawner import Spawner
from traitlets import Unicode

PUBLIC_IP = os.environ["JUPYTERHUB_PUBLIC_IP"]
MAX_SESSIONS = int(os.environ.get("VSCODE_MAX_SESSIONS", "5"))
JOB_SCRIPT = "/opt/apps/jupyterhub/job.sh"
QUEUE = "interactive.q"
QUEUE_WAIT_SECONDS = 180
# Hub-side values the job must not inherit.
ENV_SKIP = {"PATH", "HOME", "SHELL", "USER", "LOGNAME", "PWD", "LD_LIBRARY_PATH"}


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


class GridEngineSpawner(Spawner):
    """Start each single-user server as a Grid Engine job."""

    job_id = Unicode("")

    def options_from_form(self, formdata):
        ui = formdata.get("ui", ["lab"])[0]
        return {"ui": ui if ui in ("lab", "vscode") else "lab"}

    # --- state kept across Hub restarts ---
    def load_state(self, state):
        super().load_state(state)
        self.job_id = state.get("job_id", "")

    def get_state(self):
        state = super().get_state()
        if self.job_id:
            state["job_id"] = self.job_id
        return state

    def clear_state(self):
        super().clear_state()
        self.job_id = ""

    # --- helpers ---
    @property
    def ui(self):
        return (self.user_options or {}).get("ui", "lab")

    @property
    def job_name(self):
        server = re.sub(r"[^A-Za-z0-9_-]", "-", self.name or "default")
        return f"jhub-{server}"

    def jobs_dir(self):
        pw = pwd.getpwnam(self.user.name)
        path = os.path.join(pw.pw_dir, ".jupyterhub-jobs")
        os.makedirs(path, mode=0o700, exist_ok=True)
        os.chown(path, pw.pw_uid, pw.pw_gid)
        return path, pw

    def write_env_file(self, path, pw):
        env = {k: v for k, v in self.get_env().items() if k not in ENV_SKIP}
        # Contains the Hub API token: owner-only, and the job deletes it.
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            for key, value in env.items():
                f.write(f"export {key}={shlex.quote(value)}\n")
        os.chown(path, pw.pw_uid, pw.pw_gid)

    async def job_exists(self):
        if not self.job_id:
            return False
        rc, _, _ = await run_as(self.user.name, f"qstat -j {self.job_id}")
        return rc == 0

    async def qdel(self):
        if self.job_id:
            await run_as(self.user.name, f"qdel {self.job_id}")

    # --- Spawner API ---
    async def start(self):
        self.default_url = "/" if self.ui == "vscode" else "/lab"
        jobs_dir, pw = self.jobs_dir()
        base = os.path.join(jobs_dir, self.job_name)
        env_file, addr_file, log_file = f"{base}.env", f"{base}.addr", f"{base}.log"
        for stale in (addr_file, log_file):
            if os.path.exists(stale):
                os.remove(stale)
        self.write_env_file(env_file, pw)
        # Remove a leftover job from an earlier start of this server.
        await run_as(self.user.name, f"qdel {self.job_name}")

        resources = "-l interactive=true" + (",vscode=1" if self.ui == "vscode" else "")
        rc, out, err = await run_as(
            self.user.name,
            f"qsub -terse -q {QUEUE} {resources} -N {self.job_name} -j y "
            f"-o {shlex.quote(log_file)} {JOB_SCRIPT} {self.ui} "
            f"{shlex.quote(env_file)} {shlex.quote(addr_file)}",
        )
        if rc != 0 or not out:
            raise RuntimeError(f"qsub failed: {err or out}")
        self.job_id = out.splitlines()[-1].split(".")[0]
        self.log.info("Submitted %s as Grid Engine job %s", self.job_name, self.job_id)

        # Wait for the job to publish "<host> <port>" of its server.
        loop = asyncio.get_running_loop()
        deadline = loop.time() + QUEUE_WAIT_SECONDS
        while loop.time() < deadline:
            try:
                with open(addr_file) as f:
                    host, port = f.read().split()[:2]
                self.log.info("Job %s serving on %s:%s", self.job_id, host, port)
                return host, int(port)
            except (OSError, ValueError):
                pass
            if not await self.job_exists():
                log = ""
                if os.path.exists(log_file):
                    with open(log_file) as f:
                        log = f.read()[-1500:]
                self.job_id = ""
                raise RuntimeError(f"Grid Engine job ended before the server started.\n{log}")
            await asyncio.sleep(3)

        await self.qdel()
        self.job_id = ""
        limit = f"all {MAX_SESSIONS} VS Code sessions are in use, or " if self.ui == "vscode" else ""
        raise RuntimeError(
            f"The job did not start within {QUEUE_WAIT_SECONDS}s: {limit}the cluster is busy. "
            "Stop another server and try again."
        )

    async def poll(self):
        if not self.job_id:
            return 0
        return None if await self.job_exists() else 1

    async def stop(self, now=False):
        await self.qdel()


c.JupyterHub.spawner_class = GridEngineSpawner

c.JupyterHub.bind_url = "https://:443"
c.JupyterHub.ssl_cert = "/etc/jupyterhub/ssl/cert.pem"
c.JupyterHub.ssl_key = "/etc/jupyterhub/ssl/key.pem"
# Single-user servers on the workers call back to the Hub API.
c.JupyterHub.hub_bind_url = "http://0.0.0.0:8081"
c.JupyterHub.hub_connect_url = "http://jupyter:8081"
c.JupyterHub.allow_named_servers = True

c.Authenticator.allowed_users = {"ec2-user"}
c.Authenticator.admin_users = {"ec2-user"}

c.Spawner.options_form = f"""
<div class="form-group">
  <label><input type="radio" name="ui" value="lab" checked>
    <b>JupyterLab</b> &mdash; notebooks and terminals, as a job on a worker node</label>
</div>
<div class="form-group">
  <label><input type="radio" name="ui" value="vscode">
    <b>VS Code</b> &mdash; VS Code in the browser as a job on a worker node; your local
    VS Code can also connect to it with Remote-SSH (max {MAX_SESSIONS} sessions, one port each)</label>
</div>
"""
c.Spawner.start_timeout = QUEUE_WAIT_SECONDS + 60
c.Spawner.http_timeout = 180
c.Spawner.environment = {
    "SGE_ROOT": "/opt/ocs",
    "SGE_CELL": "default",
    "SGE_CLUSTER_NAME": "p6444",
    "VSCODE_PUBLIC_IP": PUBLIC_IP,
}
