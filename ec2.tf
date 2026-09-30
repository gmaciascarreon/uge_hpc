data "aws_ssm_parameter" "amazon_linux_2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  # Fixed private IPs so every node can be given the full /etc/hosts up front
  # (Grid Engine requires consistent hostname resolution) without creating a
  # dependency cycle between the master and worker user_data.
  master_ip = cidrhost(var.public_subnet_cidr, 10)

  workers = {
    for i in range(var.worker_count) :
    format("node%02d", i + 1) => cidrhost(var.public_subnet_cidr, 11 + i)
  }

  jupyter_ip = cidrhost(var.public_subnet_cidr, 20)

  hosts_entries = join("\n", concat(
    ["${local.master_ip} master"],
    [for name, ip in local.workers : "${ip} ${name}"],
    ["${local.jupyter_ip} jupyter"]
  ))
}

resource "aws_security_group" "instance" {
  name        = "${var.project_name}-sg"
  description = "No inbound access from the internet; all traffic allowed between cluster nodes, human access via SSM Session Manager"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "Allow all traffic between cluster nodes (NFS, qmaster 6444, execd 6445, SSH)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    description = "Allow all outbound traffic (required for the SSM agent and package downloads)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg"
  }
}

# Key pair ec2-user uses for passwordless SSH between cluster nodes
# (stored once in the NFS-shared /home/ec2-user/.ssh).
resource "tls_private_key" "cluster" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_instance" "master" {
  ami                    = data.aws_ssm_parameter.amazon_linux_2023.value
  instance_type          = var.master_instance_type
  subnet_id              = aws_subnet.public.id
  private_ip             = local.master_ip
  vpc_security_group_ids = [aws_security_group.instance.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm_instance_profile.name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
  }

  # gzip keeps the script (which embeds the shared scripts) under the 16 KB
  # user_data limit; cloud-init decompresses it.
  user_data_base64 = base64gzip(templatefile("${path.module}/templates/master_user_data.sh.tftpl", {
    hosts_entries = local.hosts_entries
    subnet_cidr   = var.public_subnet_cidr
    ocs_version   = var.ocs_version
    worker_names  = join(" ", keys(local.workers))
    private_key   = tls_private_key.cluster.private_key_openssh
    public_key    = tls_private_key.cluster.public_key_openssh
    vscode_key    = var.vscode_ssh_public_key
    max_sessions  = var.vscode_remote_max_sessions
    session_sh    = file("${path.module}/files/vscode-remote/session.sh")
    connect_sh    = file("${path.module}/files/vscode-remote/connect.sh")
    job_sh        = file("${path.module}/files/jupyterhub/job.sh")
  }))

  tags = {
    Name = "master"
  }
}

resource "aws_instance" "workers" {
  for_each = local.workers

  ami                    = data.aws_ssm_parameter.amazon_linux_2023.value
  instance_type          = var.worker_instance_type
  subnet_id              = aws_subnet.public.id
  private_ip             = each.value
  vpc_security_group_ids = [aws_security_group.instance.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm_instance_profile.name

  metadata_options {
    http_tokens = "required"
  }

  user_data = templatefile("${path.module}/templates/worker_user_data.sh.tftpl", {
    hostname      = each.key
    hosts_entries = local.hosts_entries
  })

  tags = {
    Name = each.key
  }
}
