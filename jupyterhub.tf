# JupyterHub node: public HTTPS entry point to the cluster. It mounts the shared
# /home and /opt/ocs from the master and is a Grid Engine submit host, so
# notebooks, terminals and VS Code (code-server) can qsub to the workers.

resource "aws_security_group" "jupyterhub" {
  name        = "${var.project_name}-jupyterhub-sg"
  description = "HTTPS access to JupyterHub from the internet"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "JupyterHub over HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.jupyterhub_allowed_cidrs
  }

  ingress {
    description = "VS Code Remote sessions (SSH), one port per session: 2200+N"
    from_port   = 2201
    to_port     = 2200 + var.vscode_remote_max_sessions
    protocol    = "tcp"
    cidr_blocks = var.jupyterhub_allowed_cidrs
  }

  tags = {
    Name = "${var.project_name}-jupyterhub-sg"
  }
}

# Static public IP so the URL and the TLS certificate stay valid across
# instance stop/start.
resource "aws_eip" "jupyterhub" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.this]

  tags = {
    Name = "${var.project_name}-jupyterhub-eip"
  }
}

# Self-signed certificate for the public IP (browsers show a warning once;
# the traffic, including the login password, is still encrypted).
resource "tls_private_key" "jupyterhub" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "jupyterhub" {
  private_key_pem       = tls_private_key.jupyterhub.private_key_pem
  validity_period_hours = 8760
  ip_addresses          = [aws_eip.jupyterhub.public_ip]
  dns_names             = [aws_eip.jupyterhub.public_dns]

  subject {
    common_name  = aws_eip.jupyterhub.public_ip
    organization = var.project_name
  }

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

# JupyterHub logs in with PAM as ec2-user (the same account, UID and shared
# home directory used on the cluster).
resource "random_password" "jupyterhub" {
  length  = 20
  special = false
}

resource "aws_instance" "jupyterhub" {
  ami                    = data.aws_ssm_parameter.amazon_linux_2023.value
  instance_type          = var.jupyter_instance_type
  subnet_id              = aws_subnet.public.id
  private_ip             = local.jupyter_ip
  vpc_security_group_ids = [aws_security_group.instance.id, aws_security_group.jupyterhub.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm_instance_profile.name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
  }

  user_data = templatefile("${path.module}/templates/jupyterhub_user_data.sh.tftpl", {
    hosts_entries     = local.hosts_entries
    password          = random_password.jupyterhub.result
    tls_cert          = tls_self_signed_cert.jupyterhub.cert_pem
    tls_key           = tls_private_key.jupyterhub.private_key_pem
    public_ip         = aws_eip.jupyterhub.public_ip
    max_sessions      = var.vscode_remote_max_sessions
    jupyterhub_config = file("${path.module}/files/jupyterhub_config.py")
  })

  tags = {
    Name = "jupyter"
  }
}

resource "aws_eip_association" "jupyterhub" {
  instance_id   = aws_instance.jupyterhub.id
  allocation_id = aws_eip.jupyterhub.id
}
