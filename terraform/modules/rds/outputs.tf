# MunchGo Microservices - RDS Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "endpoint" {
  description = "RDS endpoint (hostname)"
  value       = aws_db_instance.munchgo.address
}

output "port" {
  description = "RDS port"
  value       = aws_db_instance.munchgo.port
}

output "master_secret_arn" {
  description = "Secrets Manager ARN for master credentials"
  value       = aws_secretsmanager_secret.rds_master.arn
}

output "service_secret_arns" {
  description = "Map of database name to Secrets Manager ARN"
  value       = { for k, v in aws_secretsmanager_secret.munchgo_db : k => v.arn }
}

output "master_secret_name" {
  description = "Secrets Manager name for master credentials"
  value       = aws_secretsmanager_secret.rds_master.name
}

output "service_secret_names" {
  description = "Map of database name to Secrets Manager secret name"
  value       = { for k, v in aws_secretsmanager_secret.munchgo_db : k => v.name }
}

output "security_group_id" {
  description = "RDS security group ID"
  value       = aws_security_group.rds.id
}

output "db_instance_id" {
  description = "RDS instance identifier"
  value       = aws_db_instance.munchgo.id
}
