output "dns_name" { value = aws_lb.this.dns_name }
output "arn" { value = aws_lb.this.arn }
output "arn_suffix" { value = aws_lb.this.arn_suffix }

output "public_ips" {
  description = "Point tenant A records at these. They do not change."
  value       = aws_eip.nlb[*].public_ip
}

output "api_target_group_arn_suffix" { value = aws_lb_target_group.api.arn_suffix }
output "certbot_target_group_arn_suffix" { value = aws_lb_target_group.certbot.arn_suffix }
