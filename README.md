# Grid Engine HPC cluster on AWS via Terraform Cloud

Creates a small Grid Engine cluster running
[Open Cluster Scheduler](https://github.com/hpc-gridware/clusterscheduler)
(OCS). OCS is the free, open-source continuation of Sun/Univa Grid Engine and
uses the same `qsub` / `qstat` / `qhost` / `qconf` commands. The cluster has:

| Host     | Private IP  | Role                                                        |
|----------|-------------|-------------------------------------------------------------|
| `master` | `10.0.1.10` | qmaster, login/submit host, NFS server (`/opt/ocs`, `/home`, `/opt/apps`) |
| `node01` | `10.0.1.11` | execution host                                              |
| `node02` | `10.0.1.12` | execution host                                              |
| `jupyter` | `10.0.1.20` + Elastic IP | JupyterHub (user servers run as jobs on the workers), submit host |

All nodes are in a dedicated VPC and have no AWS key pair. The only inbound
access from the internet goes to the `jupyter` node: HTTPS (443) for
JupyterHub, and ports 2201–2205 for VS Code Remote sessions. You can restrict
both with `jupyterhub_allowed_cidrs`. For shell access, use AWS Systems Manager Session
Manager. Inside the cluster, all traffic between nodes is allowed. The
`ec2-user` account has passwordless SSH between nodes, and its home
directory is shared over NFS.

## Setup

1. In Terraform Cloud, create the workspace `uge_hpc` in the `HPC`
   organization. It is referenced in the `cloud` block in [main.tf](main.tf).
2. On that workspace, set `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` as
   environment variables and mark them sensitive.
3. Run `terraform login` and `terraform init` locally, then `terraform apply`
   (or queue a run from the workspace).

Optional variables ([variables.tf](variables.tf)):

- `worker_count` (default `2`)
- `master_instance_type` (default `t3.small`)
- `worker_instance_type` (default `t3.medium`)
- `jupyter_instance_type` (default `t3.medium`)
- `jupyterhub_allowed_cidrs` (default `["0.0.0.0/0"]`, open to the internet)
- `vscode_remote_max_sessions` (default `5`)
- `vscode_ssh_public_key` (default `""`): your laptop's SSH public key for VS Code Remote
- `ocs_version` (default `9.1.6`)
- `aws_region` (default `us-east-1`)

## Connecting and testing

Install the AWS CLI Session Manager plugin, then use the `master` command from
the `ssm_connect_commands` output:

```sh
aws ssm start-session --target <master_instance_id> --region us-east-1
sudo su - ec2-user
```

The cluster takes about 5–10 minutes after `apply` to finish installing. Then
run:

```sh
qhost                                         # node01 and node02 are listed with load and memory
qstat -f                                      # all.q@node01 and all.q@node02, no 'au'/'E' states
echo 'hostname; sleep 30' | qsub -cwd -N t1   # submit a couple of test jobs
echo 'hostname; sleep 30' | qsub -cwd -N t1
qstat                                         # jobs running on the nodes
cat t1.o*                                     # after they finish: node01 / node02
ssh node01 hostname                           # passwordless SSH between nodes
```

## JupyterHub and VS Code

```sh
terraform output jupyterhub_url           # https://<elastic-ip>
terraform output -raw jupyterhub_password # user: ec2-user
```

1. Open the URL. The certificate is self-signed, so accept the browser
   warning once. The connection is still encrypted.
2. Log in as `ec2-user` with the generated password.
3. On the **Server Options** page, choose:
   - **JupyterLab**: notebooks and terminals.
   - **VS Code**: VS Code in the browser, with no JupyterLab. Your local VS
     Code can also connect to the same session (see below).

   **Both run as Grid Engine jobs on a worker node.** The `jupyter` node only
   runs the Hub and its proxy. The job is named `jhub-<server name>`
   (`jhub-default` for the default server), and `qstat` on any node shows it.
4. Notebooks and terminals share the cluster home directory and can submit
   jobs: `qsub`, `qstat`, `qhost`.

To run several servers at once (for example JupyterLab and two VS Code
sessions), open the Hub Control Panel (`https://<elastic-ip>/hub/home`, or
**File → Hub Control Panel** in JupyterLab) and add named servers. Each one
shows the Server Options page. **Stopping a server there deletes its job**
(`qdel`).

### How the jobs run

- **Queue:** jobs go to `interactive.q`, which has 5 slots per worker in
  addition to `all.q`. Interactive sessions are mostly idle, so they don't
  take batch slots. A FORCED complex (`-l interactive=true`, which only the
  Hub requests) keeps ordinary batch jobs out of `interactive.q`.
- **Software:** the Python environment (JupyterHub, JupyterLab,
  jupyter-server-proxy) is in `/opt/apps/jupyter` and code-server is in
  `/opt/apps/code-server`. Both are on the NFS share, so every worker uses
  the same installation.
- **Job script:** `/opt/apps/jupyterhub/job.sh` (source:
  [files/jupyterhub/job.sh](files/jupyterhub/job.sh)).
  - JupyterLab jobs run `jupyterhub-singleuser`.
  - VS Code jobs run code-server behind `jupyter-standaloneproxy`, which
    handles the JupyterHub login without starting a Jupyter server.
- **Waiting in the queue:** if a job doesn't start within 3 minutes (the
  cluster is full), the Hub deletes it and shows an error.
- **Logs:** each job's output is in `~/.jupyterhub-jobs/jhub-<server name>.log`.

JupyterHub runs as the `jupyterhub` systemd service. Its config is
`/etc/jupyterhub/jupyterhub_config.py` (source: [files/jupyterhub_config.py](files/jupyterhub_config.py)),
and you can read its logs with `journalctl -u jupyterhub` on the `jupyter`
node. The spawner itself is `GridEngineSpawner`, defined in that file.

## VS Code: connecting your local VS Code (Remote-SSH)

Every **VS Code** session also runs a private SSH endpoint inside its job.
Your local VS Code connects to it with the Remote-SSH extension, so the VS
Code server, terminals, builds and debuggers all run on the compute node,
inside the job.

```
local VS Code ──ssh──▶ <elastic-ip>:2200+N ──(gateway on jupyter)──▶ nodeXX:22000+N (sshd in the job)
```

- **Up to 5 VS Code sessions** run at the same time. A Grid Engine
  consumable, `vscode=5`, enforces this, and every VS Code job requests
  `vscode=1`. If all 5 are in use, the spawn fails with a message saying so.
- **Session N gets its own public port, 2200+N** (2201–2205). The browser
  VS Code opens a file with the port, the node, the job ID, and an
  `~/.ssh/config` block to copy (`~/vscode-remote/session-<job id>.md`).

One-time local setup:

1. Install the **Remote - SSH** extension in VS Code.
2. Pick an SSH key. Either:
   - set `vscode_ssh_public_key` to your laptop's public key before
     `apply`, or
   - save the cluster key:
     `terraform output -raw cluster_ssh_private_key > ~/.ssh/uge_hpc && chmod 600 ~/.ssh/uge_hpc`
3. Add the `Host hpc-vscode-N` block from the session file to
   `~/.ssh/config` (change `IdentityFile` if you use your own key). Then run
   **Remote-SSH: Connect to Host…** and pick it.

The first connection installs the VS Code Server into `~/.vscode-server`.
Home is shared over NFS, so every node reuses it afterwards. In a VS Code
terminal, `hostname` shows the worker and `echo $JOB_ID` shows the job.

The Remote-SSH scripts are in `/opt/apps/vscode-remote` (NFS-shared; source:
[files/vscode-remote/](files/vscode-remote/)).

## Troubleshooting

- Boot/install log on every node: `/var/log/cloud-init-output.log`
- qmaster log: `/opt/ocs/default/spool/qmaster/messages`
- execd log on a worker: `/var/spool/ocs/<hostname>/messages`

Workers wait (they retry every 15 s) until the master exports its NFS shares
and qmaster answers, so they can be created in any order.

## Cost

The cluster costs about $0.15/hour with the default instance types, including
the JupyterHub node and its Elastic IP. Run
`terraform destroy` when you're done.

## Files

- `main.tf`: Terraform Cloud backend and AWS provider
- `vpc.tf`: dedicated VPC, public subnet, internet gateway, routing
- `iam.tf`: IAM role and instance profile with `AmazonSSMManagedInstanceCore`
- `ec2.tf`: security group, cluster SSH key, and the master and worker instances
- `templates/master_user_data.sh.tftpl`: installs OCS qmaster and the NFS server
- `templates/worker_user_data.sh.tftpl`: mounts the NFS shares and installs the OCS execd
- `jupyterhub.tf`: JupyterHub instance, HTTPS security group, Elastic IP, self-signed certificate, login password
- `templates/jupyterhub_user_data.sh.tftpl`: mounts the NFS shares, installs JupyterHub, JupyterLab and code-server into `/opt/apps`, and sets up the Remote-SSH gateway
- `files/jupyterhub_config.py`: JupyterHub config, including the spawn menu and `GridEngineSpawner`
- `files/jupyterhub/job.sh`: the Grid Engine job that runs a user's JupyterLab or VS Code server
- `files/vscode-remote/session.sh`: Remote-SSH endpoint started inside VS Code jobs (claims a slot, runs a user-mode sshd)
- `files/vscode-remote/connect.sh`: gateway helper that forwards port 2200+N to the session's worker
- `variables.tf` / `outputs.tf`: inputs and outputs
