# Grid Engine HPC cluster on AWS via Terraform Cloud

Creates a small Grid Engine cluster running
[Open Cluster Scheduler](https://github.com/hpc-gridware/clusterscheduler)
(OCS). OCS is the free, open-source continuation of Sun/Univa Grid Engine and
uses the same `qsub` / `qstat` / `qhost` / `qconf` commands. The cluster has:

| Host     | Private IP  | Role                                                        |
|----------|-------------|-------------------------------------------------------------|
| `master` | `10.0.1.10` | qmaster, login/submit host, NFS server (`/opt/ocs`, `/home`) |
| `node01` | `10.0.1.11` | execution host                                              |
| `node02` | `10.0.1.12` | execution host                                              |
| `jupyter` | `10.0.1.20` + Elastic IP | JupyterHub (JupyterLab + VS Code in the browser), submit host |

All nodes are in a dedicated VPC and have no AWS key pair. The only inbound
access from the internet is HTTPS (443) to JupyterHub. You can restrict it with
`jupyterhub_allowed_cidrs`. For shell access, use AWS Systems Manager Session
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
2. Log in as `ec2-user` with the generated password. JupyterLab opens.
3. In the Launcher, click **VS Code** to open code-server in the browser.
4. Notebooks, JupyterLab terminals and VS Code terminals share the cluster
   home directory and can submit jobs: `qsub`, `qstat`, `qhost`.

JupyterHub runs as the `jupyterhub` systemd service. Its config is
`/etc/jupyterhub/jupyterhub_config.py`, and you can read its logs with
`journalctl -u jupyterhub` on the `jupyter` node.

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
- `templates/jupyterhub_user_data.sh.tftpl`: mounts the NFS shares and installs JupyterHub, JupyterLab and code-server
- `variables.tf` / `outputs.tf`: inputs and outputs
