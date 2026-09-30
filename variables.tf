variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name prefix applied to all resources"
  type        = string
  default     = "uge-hpc"
}

variable "vpc_cidr" {
  description = "CIDR block for the dedicated VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet the cluster runs in"
  type        = string
  default     = "10.0.1.0/24"
}

variable "master_instance_type" {
  description = "EC2 instance type for the master/login node (qmaster + NFS server + submit host)"
  type        = string
  default     = "t3.small"
}

variable "worker_instance_type" {
  description = "EC2 instance type for the execution (worker) nodes"
  type        = string
  default     = "t3.medium"
}

variable "worker_count" {
  description = "Number of execution nodes (named node01, node02, ...)"
  type        = number
  default     = 2

  validation {
    condition     = var.worker_count >= 1 && var.worker_count <= 50
    error_message = "worker_count must be between 1 and 50."
  }
}

variable "jupyter_instance_type" {
  description = "EC2 instance type for the JupyterHub node"
  type        = string
  default     = "t3.medium"
}

variable "jupyterhub_allowed_cidrs" {
  description = "CIDR blocks allowed to reach JupyterHub over HTTPS (443). Narrow this to your own IP (e.g. [\"203.0.113.4/32\"]) if possible."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "vscode_remote_max_sessions" {
  description = "Maximum concurrent VS Code Remote sessions (Grid Engine jobs). Session N is reached on public port 2200+N."
  type        = number
  default     = 5

  validation {
    condition     = var.vscode_remote_max_sessions >= 1 && var.vscode_remote_max_sessions <= 99
    error_message = "vscode_remote_max_sessions must be between 1 and 99."
  }
}

variable "vscode_ssh_public_key" {
  description = "Optional SSH public key of your local machine (e.g. contents of ~/.ssh/id_ed25519.pub) allowed to connect to VS Code Remote sessions. If empty, use the cluster_ssh_private_key output."
  type        = string
  default     = ""
}

variable "ocs_version" {
  description = "Open Cluster Scheduler release to install (prebuilt packages from open.clusterscheduler.io, 9.1.6 or newer)"
  type        = string
  default     = "9.1.6"
}
