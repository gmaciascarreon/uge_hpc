output "master_instance_id" {
  description = "ID of the master/login instance"
  value       = aws_instance.master.id
}

output "master_private_ip" {
  description = "Private IP of the master/login instance"
  value       = aws_instance.master.private_ip
}

output "worker_instance_ids" {
  description = "IDs of the execution nodes, keyed by hostname"
  value       = { for name, inst in aws_instance.workers : name => inst.id }
}

output "worker_private_ips" {
  description = "Private IPs of the execution nodes, keyed by hostname"
  value       = { for name, inst in aws_instance.workers : name => inst.private_ip }
}

output "ssm_connect_commands" {
  description = "AWS CLI commands to open a Session Manager shell on each instance"
  value = merge(
    { master = "aws ssm start-session --target ${aws_instance.master.id} --region ${var.aws_region}" },
    { jupyter = "aws ssm start-session --target ${aws_instance.jupyterhub.id} --region ${var.aws_region}" },
    { for name, inst in aws_instance.workers : name => "aws ssm start-session --target ${inst.id} --region ${var.aws_region}" }
  )
}

output "jupyterhub_url" {
  description = "Public JupyterHub URL (self-signed certificate: accept the browser warning)"
  value       = "https://${aws_eip.jupyterhub.public_ip}"
}

output "jupyterhub_username" {
  description = "JupyterHub login user"
  value       = "ec2-user"
}

output "jupyterhub_password" {
  description = "JupyterHub login password (terraform output -raw jupyterhub_password)"
  value       = random_password.jupyterhub.result
  sensitive   = true
}

output "cluster_ssh_private_key" {
  description = "Private key ec2-user uses for SSH between cluster nodes (already installed in the shared home directory; kept here as a backup)"
  value       = tls_private_key.cluster.private_key_openssh
  sensitive   = true
}
