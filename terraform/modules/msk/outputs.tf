# MunchGo Microservices - MSK Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "cluster_arn" {
  description = "MSK cluster ARN"
  value       = aws_msk_cluster.munchgo.arn
}

output "bootstrap_brokers" {
  description = "Plaintext bootstrap broker connection string"
  value       = aws_msk_cluster.munchgo.bootstrap_brokers
}

output "bootstrap_brokers_tls" {
  description = "TLS bootstrap broker connection string"
  value       = aws_msk_cluster.munchgo.bootstrap_brokers_tls
}

output "zookeeper_connect_string" {
  description = "ZooKeeper connection string"
  value       = aws_msk_cluster.munchgo.zookeeper_connect_string
}

output "security_group_id" {
  description = "MSK security group ID"
  value       = aws_security_group.msk.id
}
