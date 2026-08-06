output "instance_ids" { value = aws_instance.node[*].id }
output "private_ips" { value = aws_instance.node[*].private_ip }
output "public_ips" { value = aws_eip.node[*].public_ip }
output "hostnames" { value = local.hostnames }

output "gatekeeper_instance_id" {
  description = "The node that receives port 80 and therefore runs certbot."
  value       = aws_instance.node[var.gatekeeper_index].id
}

output "gatekeeper_hostname" {
  description = "Must equal PRIMARY_BALANCER_HOST in var/django.conf."
  value       = local.hostnames[var.gatekeeper_index]
}
