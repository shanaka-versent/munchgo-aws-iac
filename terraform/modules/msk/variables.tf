# MunchGo Microservices - MSK Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where MSK cluster will be deployed"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for MSK brokers (one per AZ)"
  type        = list(string)
}

variable "eks_node_security_group_id" {
  description = "Security group ID of EKS nodes (for ingress rules)"
  type        = string
}

variable "kafka_version" {
  description = "Apache Kafka version for MSK"
  type        = string
  default     = "3.6.0"
}

variable "instance_type" {
  description = "MSK broker instance type"
  type        = string
  default     = "kafka.m5.large"
}

variable "broker_count" {
  description = "Number of Kafka broker nodes (must match or be multiple of AZ count)"
  type        = number
  default     = 2
}

variable "ebs_volume_size" {
  description = "EBS volume size per broker (GB)"
  type        = number
  default     = 100
}

variable "enable_cloudwatch_logs" {
  description = "Enable CloudWatch logging for MSK brokers"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags for resources"
  type        = map(string)
  default     = {}
}
