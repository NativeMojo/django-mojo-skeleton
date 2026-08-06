output "vpc_id" { value = aws_vpc.this.id }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "availability_zones" { value = local.azs }

output "node_sg_id" { value = aws_security_group.node.id }
output "rds_sg_id" { value = aws_security_group.rds.id }
output "cache_sg_id" { value = aws_security_group.cache.id }
